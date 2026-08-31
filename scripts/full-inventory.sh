#!/usr/bin/env bash
#
# Two-pass .NET estate inventory against a configurable target version.
# Bash + Azure CLI.
#
#   Pass 1  Azure Resource Graph. One query, every readable subscription,
#           thousands of resources in seconds. Gives the skeleton.
#
#   Pass 2  ARM fan-out, in parallel, for the fields Resource Graph cannot see.
#           Application settings are not exposed in Resource Graph at any tier,
#           and FUNCTIONS_WORKER_RUNTIME plus FUNCTIONS_EXTENSION_VERSION are
#           what decide in-process vs isolated and host v3 vs v4.
#
# Output: a CSV you can sort and attach exceptions to.
#
# Usage:
#   ./full-inventory.sh                          # every readable subscription, target .NET 10.0
#   ./full-inventory.sh -t 8.0                   # target .NET 8.0 instead (e.g. .NET 6 -> 8)
#   ./full-inventory.sh -o estate.csv -p 16      # custom output and parallelism
#   ./full-inventory.sh -s <sub-id>              # one subscription
#   ./full-inventory.sh -n                       # pass 1 only (Reader is enough)
#
# Permissions:
#   Pass 1  Reader on the subscriptions in scope.
#   Pass 2  additionally Microsoft.Web/sites/config/list/action, because
#           listing application settings is a POST in ARM, not a read.
#           Included in Contributor and in Website Contributor.
#
# Requires: az cli, jq.
#
# Written with AI assistance, then reviewed and run against a live tenant
# before publishing. Read it before you run it. Both passes are read-only:
# nothing is written, no application setting is changed.

# This script needs bash 4+: associative arrays, mapfile, process
# substitution. Re-exec if launched as `sh script.sh` under dash/ash.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

OUTPUT="azure-dotnet-estate-$(date +%Y%m%d).csv"
PARALLEL=4
SUBSCRIPTION=""
SKIP_ARM=0
PAGE_SIZE=1000
API_VERSION="2024-04-01"
TARGET_VERSION="10.0"

# Azure platform ceilings that do not move with the -t threshold, 
# only with the platform itself. Edit here if Microsoft raises them.
SWA_MAX_APIRUNTIME="9.0"        # Highest dotnet-isolated Static Web Apps managed API supports
CONSUMPTION_MAX_SUPPORTED="9.0" # Highest isolated worker version on Linux Consumption

# Functions host retirement dates. Not thresholds and not language versions,
# so they never move with -t. v3 on Linux Consumption is the only one of the
# three where the app stops running rather than merely losing support.
V3_LINUX_CONSUMPTION_STOP="2026-09-30"
HOST_V1_SUPPORT_END="2026-09-14"
HOST_V2_V3_SUPPORT_END="2022-12-13"

usage() { sed -n '2,29p' "$0"; exit 1; }

while getopts ":o:p:s:t:nh" opt; do
  case "$opt" in
    o) OUTPUT="$OPTARG" ;;
    p) PARALLEL="$OPTARG" ;;
    s) SUBSCRIPTION="$OPTARG" ;;
    t) TARGET_VERSION="$OPTARG" ;;
    n) SKIP_ARM=1 ;;
    h|*) usage ;;
  esac
done

TARGET_MAJOR="${TARGET_VERSION%%.*}"
export TARGET_VERSION TARGET_MAJOR SWA_MAX_APIRUNTIME CONSUMPTION_MAX_SUPPORTED
export V3_LINUX_CONSUMPTION_STOP HOST_V1_SUPPORT_END HOST_V2_V3_SUPPORT_END

command -v az >/dev/null || { echo "az cli not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

az account show >/dev/null 2>&1 || { echo "Not signed in. Run 'az login' first." >&2; exit 1; }

if ! az extension show --name resource-graph >/dev/null 2>&1; then
  echo "Installing the resource-graph extension..." >&2
  az extension add --name resource-graph --only-show-errors
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ARM_ENDPOINT="$(az cloud show --query endpoints.resourceManager -o tsv | sed 's:/*$::')"

echo "Signed in as $(az account show --query user.name -o tsv)" >&2

# The CLI forwards only the first 1000 subscription IDs to Resource Graph.
# Past that the query silently covers a subset, so warn rather than report a
# confidently incomplete estate.
if [ -z "$SUBSCRIPTION" ]; then
  SUB_COUNT=$(az account list --query "length([?state=='Enabled'])" -o tsv)
  echo "$SUB_COUNT subscription(s) in scope" >&2
  if [ "$SUB_COUNT" -gt 1000 ]; then
    echo "WARNING: only the first 1000 subscriptions are forwarded to Resource Graph." >&2
    echo "         Run in batches with -s and merge the CSVs." >&2
  fi
fi

# ---------------------------------------------------------------------------
# Pass 1: Resource Graph
# ---------------------------------------------------------------------------
read -r -d '' GRAPH_QUERY <<'KQL' || true
resources
| where type in~ (
    'microsoft.web/sites',
    'microsoft.web/sites/slots',
    'microsoft.web/staticsites',
    'microsoft.app/containerapps',
    'microsoft.app/jobs',
    'microsoft.containerinstance/containergroups',
    'microsoft.containerservice/managedclusters',
    'microsoft.compute/virtualmachines',
    'microsoft.compute/virtualmachinescalesets')
| extend siteKind = tolower(tostring(kind))
| extend workloadType = case(
    type =~ 'microsoft.web/staticsites', 'StaticWebApp',
    type =~ 'microsoft.app/containerapps', 'ContainerApp',
    type =~ 'microsoft.app/jobs', 'ContainerAppJob',
    type =~ 'microsoft.containerinstance/containergroups', 'ContainerInstance',
    type =~ 'microsoft.containerservice/managedclusters', 'AksCluster',
    type =~ 'microsoft.compute/virtualmachines', 'VirtualMachine',
    type =~ 'microsoft.compute/virtualmachinescalesets', 'VmScaleSet',
    siteKind contains 'workflowapp', 'LogicAppStandard',
    siteKind contains 'functionapp', 'FunctionApp',
    'AppService')
| extend isSlot = type =~ 'microsoft.web/sites/slots'
| extend planId = tolower(tostring(properties.serverFarmId))
// Container images: Container Apps/Jobs carry them as an array under
// template.containers, Container Instances as an array under
// properties.containers. Both shapes are captured with the same regex,
// since the exact field can vary by API version.
| extend images = iff(type in~ (
    'microsoft.app/containerapps', 'microsoft.app/jobs', 'microsoft.containerinstance/containergroups'),
    strcat_array(extract_all(@'"image":"([^"]+)"',
        tostring(coalesce(properties.template.containers,
                          properties.configuration.template.containers,
                          properties.containers))), ';'), '')
// AKS: Kubernetes version and system node pool OS as a rough signal only.
// Says nothing about the images running inside the pods -- see the note in the script.
| extend aksVersion = iff(type =~ 'microsoft.containerservice/managedclusters',
    tostring(properties.kubernetesVersion), '')
// VMs/VMSS: OS family is the only reliably readable signal here. Neither
// "containerized" nor "has .NET installed directly" can be derived from
// ARM metadata -- see the note in the script.
| extend vmOsType = iff(type in~ ('microsoft.compute/virtualmachines', 'microsoft.compute/virtualmachinescalesets'),
    tostring(coalesce(properties.storageProfile.osDisk.osType,
                      properties.virtualMachineProfile.storageProfile.osDisk.osType)), '')
// Sites: Linux vs Windows decides two things that Consumption alone does not
// -- whether the v3 stop on 2026-09-30 applies, and whether the .NET ceiling
// on Consumption applies at all (it is a Linux Consumption ceiling; Windows
// Consumption is not affected). kind is the only OS signal Resource Graph
// exposes for sites, as 'functionapp,linux' or 'app,linux'.
| extend osFamily = iff(type in~ ('microsoft.web/sites', 'microsoft.web/sites/slots'),
    iff(siteKind contains 'linux', 'linux', 'windows'), '')
| join kind=leftouter (
    resourcecontainers
    | where type =~ 'microsoft.resources/subscriptions'
    | project subscriptionId, subscriptionName = name
) on subscriptionId
| join kind=leftouter (
    resources
    | where type =~ 'microsoft.web/serverfarms'
    | project planId = tolower(id), planTier = tostring(sku.tier)
) on planId
| project id, name, resourceGroup, subscriptionId, subscriptionName,
    workloadType, isSlot, planTier, images, aksVersion, vmOsType, osFamily, location
| order by id asc
KQL

echo "Pass 1: querying Resource Graph..." >&2

# Paging notes:
#   - 1000 records is the hard per-response ceiling; --first cannot exceed it.
#   - The query ends with 'order by id asc'. Without a deterministic sort,
#     --skip based paging is not stable and returns duplicates and gaps.
#   - Each page costs one query against the 15-per-5-seconds user quota, so
#     this pages sequentially. Grouping beats parallelising for Resource Graph;
#     the fan-out in pass 2 hits ARM, which has separate limits.
SKIP=0
: > "$WORK/graph.jsonl"
while :; do
  GRAPH_ARGS=(-q "$GRAPH_QUERY" --first "$PAGE_SIZE" --skip "$SKIP" --only-show-errors -o json)
  [ -n "$SUBSCRIPTION" ] && GRAPH_ARGS+=(--subscriptions "$SUBSCRIPTION")
  PAGE=$(az graph query "${GRAPH_ARGS[@]}")

  COUNT=$(echo "$PAGE" | jq '.data | length')
  echo "$PAGE" | jq -c '.data[]' >> "$WORK/graph.jsonl"

  [ "$COUNT" -lt "$PAGE_SIZE" ] && break
  SKIP=$((SKIP + PAGE_SIZE))
  echo "  fetched $SKIP so far..." >&2
done

TOTAL=$(wc -l < "$WORK/graph.jsonl" | tr -d ' ')
echo "  $TOTAL resources found." >&2

if [ "$TOTAL" -eq 0 ]; then
  echo "Nothing to inventory." >&2
  exit 0
fi

CSV_HEADER="name,resourceGroup,subscription,workloadType,isSlot,runtime,workerRuntime,hostVersion,os,planTier,flag,action,resourceId"

if [ "$SKIP_ARM" -eq 1 ]; then
  echo "Skipping the ARM probe. Worker model and host version will not be determined." >&2
  {
    echo "$CSV_HEADER"
    jq -r '[.name, .resourceGroup, (.subscriptionName // ""), .workloadType,
            (.isSlot|tostring), (.images // ""), "NOT PROBED", "NOT PROBED",
            (.osFamily // ""), (.planTier // ""),
            "UNKNOWN", "pass 2 skipped", .id] | @csv' "$WORK/graph.jsonl"
  } > "$OUTPUT"
  echo "Written: $OUTPUT" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Pass 2: ARM fan-out for what Graph cannot see
# ---------------------------------------------------------------------------
cat > "$WORK/probe.sh" <<'PROBEEOF'
#!/usr/bin/env bash
set -uo pipefail

RESOURCE_JSON="$1"
ARM="$2"
API_VERSION="$3"
# TARGET_VERSION, TARGET_MAJOR, SWA_MAX_APIRUNTIME, CONSUMPTION_MAX_SUPPORTED,
# V3_LINUX_CONSUMPTION_STOP, HOST_V1_SUPPORT_END and HOST_V2_V3_SUPPORT_END
# come in via the environment, exported by the parent script.

# Fail loudly rather than emitting a row of empty fields. If this fires, the
# JSON was mangled before it got here -- check how the caller passes it.
if ! echo "$RESOURCE_JSON" | jq -e . >/dev/null 2>&1; then
  echo "probe: input is not valid JSON: ${RESOURCE_JSON:0:80}" >&2
  exit 1
fi

# True if version $1 is strictly greater than version $2, for plain X.Y
# strings. Used to compare the -t threshold against fixed platform ceilings.
ver_gt() {
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# Major version out of FUNCTIONS_EXTENSION_VERSION. The setting is written
# several ways and all of them have to read the same: '~4' and '4' for a
# floating major, '4.1.3' or '3.0.15584' for an app pinned to a minor. A
# plain string compare against '~4' calls every pinned v4 app a v3 app.
# Anything non-numeric -- 'beta', 'latest', an empty setting -- returns empty
# and is reported as unknown rather than guessed at.
host_major() {
  local v="${1#\~}"
  v="${v%%.*}"
  case "$v" in
    ''|*[!0-9]*) echo "" ;;
    *)           echo "$v" ;;
  esac
}

# One field per resource type down here needs its own ARM call (config/web,
# the site root for Flex Consumption, app settings). Sharing this instead of
# repeating the GET at each call site.
arm_get() {
  az rest --method GET --url "${ARM}$1?api-version=${API_VERSION}" \
    --only-show-errors 2>/dev/null || echo '{}'
}

# action accumulates free-text across multiple branches (workload-type
# classification, then flag classification); this keeps every call site the
# same regardless of whether action already has content.
append_action() { action="${action:+$action; }$1"; }

# One jq call for every field pulled off $RESOURCE_JSON, instead of one
# subprocess per field -- this runs once per resource, thousands of times.
#
# Unit separator, not tab. Tab is IFS whitespace, so bash collapses runs of
# it into a single delimiter and every empty field silently shifts the rest
# one position left. A Container App has no planTier, so with @tsv its image
# tag lands in the tier variable and images comes back empty; a Function App
# has no images, aksVersion or vmOsType, so osFamily lands in images. \x1f is
# not IFS whitespace, so empty fields stay empty and in place.
IFS=$'\037' read -r id name rg sub wtype isslot tier images aksv osType osFam <<<"$(
  echo "$RESOURCE_JSON" | jq -r '[.id, .name, .resourceGroup, (.subscriptionName // ""),
    .workloadType, (.isSlot|tostring), (.planTier // ""), (.images // ""),
    (.aksVersion // ""), (.vmOsType // ""), (.osFamily // "")] | join("\u001f")'
)"

runtime=""
worker=""
hostVer=""
action=""
flag="REVIEW"

# One case statement instead of an if/elif chain, and one shared branch for
# the three resource types that all expose a plain image tag in ARM
# (Container Apps, Container App Jobs, Container Instances), instead of
# repeating the same four lines three times.
case "$wtype" in
  ContainerApp|ContainerAppJob|ContainerInstance)
    runtime="$images"
    worker="n/a"
    append_action "rebuild image on Ubuntu base"
    case "$images" in
      *:${TARGET_MAJOR}.0*|*net${TARGET_MAJOR}*) append_action "image tag suggests .NET ${TARGET_VERSION} - verify" ;;
      *)                                         append_action "check image tag manually" ;;
    esac
    ;;

  AksCluster)
    # The cluster is an ARM resource; the pods running inside it, and their
    # images, are not. Resource Graph can confirm the cluster exists, not what
    # is deployed to it. Checking the workload needs kubectl access or, where
    # enabled, Container Insights in Log Analytics (KubePodInventory /
    # ContainerInventory).
    runtime="k8s $aksv"
    worker="n/a"
    flag="MANUAL"
    append_action "AKS cluster found, pod images not inspected; check workload images via kubectl or Container Insights, not via ARM"
    ;;

  VirtualMachine|VmScaleSet)
    # ARM metadata cannot tell you whether this runs containerised or has
    # .NET installed directly on the host (IIS, a systemd service, and so
    # on). Only the OS itself is reliably readable.
    runtime="OS: ${osType:-unknown}"
    worker="n/a"
    flag="MANUAL"
    append_action "VM/VMSS found, runtime not determinable via ARM; check via Azure Monitor VM Insights, Update Manager, or a direct inventory - container vs. host-installed .NET cannot be told apart from ARM alone"
    ;;

  StaticWebApp)
    # Managed functions in Static Web Apps top out at
    # dotnet-isolated:${SWA_MAX_APIRUNTIME}; there is no in-place path past
    # that ceiling, only "bring your own functions" via a linked Function
    # App. apiRuntime lives in staticwebapp.config.json in the repository,
    # not in ARM, so it cannot be read here.
    runtime="see staticwebapp.config.json"
    worker="n/a"
    if ver_gt "$TARGET_VERSION" "$SWA_MAX_APIRUNTIME"; then
      flag="CRITICAL"
      append_action "SWA managed API has no .NET ${TARGET_VERSION} path; if the API is .NET, plan a linked Function App; check apiRuntime in staticwebapp.config.json"
    else
      flag="REVIEW"
      append_action "SWA managed API capped at .NET ${SWA_MAX_APIRUNTIME}; check apiRuntime in staticwebapp.config.json meets target .NET ${TARGET_VERSION}"
    fi
    ;;

  LogicAppStandard)
    # Runs on the Functions host, so it appears as a site with kind
    # functionapp,workflowapp. Flagged separately to keep it out of the
    # Functions counts.
    cfg=$(arm_get "${id}/config/web")
    runtime=$(echo "$cfg" | jq -r '.properties.netFrameworkVersion // .properties.linuxFxVersion // ""')
    worker="workflow"
    flag="REVIEW"
    append_action "Logic App Standard, check custom code extensions"
    ;;

  *)
    # FunctionApp and AppService both need siteConfig, read the same way.
    cfg=$(arm_get "${id}/config/web")
    linuxFx=$(echo "$cfg" | jq -r '.properties.linuxFxVersion // ""')
    netFx=$(echo "$cfg"   | jq -r '.properties.netFrameworkVersion // ""')
    runtime="${linuxFx:-$netFx}"

    if [ "$wtype" = "FunctionApp" ]; then
      # Flex Consumption keeps the runtime on the site resource, in
      # functionAppConfig.runtime -- not in siteConfig and not in app
      # settings. Checked separately or these apps read as UNKNOWN. Only
      # fetched for Function Apps: AppService never has functionAppConfig,
      # so the extra ARM call would come back empty every time.
      site=$(arm_get "$id")
      flexName=$(echo "$site" | jq -r '.properties.functionAppConfig.runtime.name // ""')
      flexVer=$(echo "$site"  | jq -r '.properties.functionAppConfig.runtime.version // ""')

      if [ -n "$flexName" ]; then
        runtime="${flexName}|${flexVer}"
        worker="$flexName"
        # Flex Consumption only ever ran on host v4, and it does not carry
        # FUNCTIONS_EXTENSION_VERSION. Set here so these apps do not fall
        # through the host-version check below as unknown.
        hostVer="~4"
        append_action "Flex Consumption - runtime in functionAppConfig"
      else
        # Listing app settings is a POST in ARM, not a GET. Reader is not
        # enough; this needs Microsoft.Web/sites/config/list/action.
        settings=$(az rest --method POST \
          --url "${ARM}${id}/config/appsettings/list?api-version=${API_VERSION}" \
          --only-show-errors 2>/dev/null || echo '{}')
        # Both settings come out of the same response, so the host version
        # costs no extra call and no extra permission over what pass 2
        # already needs.
        worker=$(echo "$settings" | jq -r '.properties.FUNCTIONS_WORKER_RUNTIME // ""')
        hostVer=$(echo "$settings" | jq -r '.properties.FUNCTIONS_EXTENSION_VERSION // ""')
        if [ -z "$worker" ]; then
          worker="UNREADABLE"
          append_action "no permission to list app settings"
        fi
      fi
    else
      worker="n/a"
    fi
    ;;
esac

# The flag column carries only the severity/category, so rows group cleanly
# by CRITICAL / ACTION / REVIEW / VERIFY / MANUAL / UNKNOWN / OK. Anything
# specific -- what to actually do about it -- goes in action instead,
# extending whatever action text earlier branches already set.
case "$wtype" in
  FunctionApp)
    # In-process hosting retires on its own fixed date regardless of which
    # version this run targets, so that branch stays unconditional.
    case "$worker" in
      dotnet)
        flag="CRITICAL"
        append_action "in-process, retires 2026-11-10" ;;
      UNREADABLE)
        flag="UNKNOWN"
        append_action "cannot read settings" ;;
      # dotnet-isolated and any other/unrecognized worker both pass on a
      # runtime match; they differ only in what an outright mismatch means
      # -- dotnet-isolated is a known worker so a mismatch is actionable,
      # anything else is unrecognized so it stays at the default REVIEW.
      *)
        if echo "$runtime" | grep -qiF "$TARGET_VERSION"; then
          flag="OK"
          append_action "isolated .NET ${TARGET_VERSION}"
        elif [ "$worker" = "dotnet-isolated" ]; then
          flag="ACTION"
          append_action "isolated, framework below ${TARGET_VERSION}"
        fi ;;
    esac
    # The host runtime version is a separate axis from the worker model and
    # from the -t threshold. v2 and v3 lost support on 2022-12-13 and v1
    # loses it on 2026-09-14, but only one combination stops executing:
    # v3 + Linux + Consumption, after 2026-09-30. Checked for every worker
    # runtime, not just dotnet -- a Node or Python app on v3 hits the same
    # date and would otherwise sit in the default REVIEW bucket.
    hostMajor="$(host_major "$hostVer")"
    if [ -n "$hostMajor" ] && [ "$hostMajor" -lt 4 ]; then
      flag="CRITICAL"
      if [ "$hostMajor" -eq 3 ] && [ "$osFam" = "linux" ] && [ "$tier" = "Dynamic" ]; then
        append_action "host v3 on Linux Consumption - STOPS RUNNING after ${V3_LINUX_CONSUMPTION_STOP}; migrate to ~4"
      elif [ "$hostMajor" -eq 1 ]; then
        append_action "host v1 (${hostVer}), support ends ${HOST_V1_SUPPORT_END}; migrate to ~4"
      else
        append_action "host v${hostMajor} (${hostVer}), out of support since ${HOST_V2_V3_SUPPORT_END}; migrate to ~4"
      fi
    elif [ -z "$hostMajor" ] && [ "$worker" != "UNREADABLE" ]; then
      flag="UNKNOWN"
      if [ -z "$hostVer" ]; then
        append_action "FUNCTIONS_EXTENSION_VERSION not set - host version undetermined"
      else
        append_action "FUNCTIONS_EXTENSION_VERSION is '${hostVer}', no numeric major - check manually"
      fi
    fi

    # The ceiling is a Linux Consumption ceiling. Windows Consumption sits on
    # the same Dynamic tier and is not affected, so the OS has to be part of
    # the condition or every Windows Consumption app gets told to move plans.
    if [ "$tier" = "Dynamic" ] && [ "$osFam" = "linux" ] \
       && ver_gt "$TARGET_VERSION" "$CONSUMPTION_MAX_SUPPORTED"; then
      append_action "Linux Consumption - .NET ${TARGET_VERSION} unsupported here (max: ${CONSUMPTION_MAX_SUPPORTED})"
      flag="CRITICAL"
      append_action "plan move required"
    fi
    ;;
  StaticWebApp|ContainerApp|ContainerAppJob|LogicAppStandard|ContainerInstance|AksCluster|VirtualMachine|VmScaleSet)
    : # flag already set above
    ;;
  AppService)
    # On Windows the stack setting is not proof the app moved. Every supported
    # runtime is installed side by side on the worker, so an older app keeps
    # binding to its actual version while netFrameworkVersion reports the
    # latest installed. Only the Linux value, which selects the container
    # image, actually constrains what runs.
    if echo "$runtime" | grep -qF "DOTNETCORE|${TARGET_VERSION}"; then
      flag="OK"
      append_action ".NET ${TARGET_VERSION} stack"
    elif echo "$runtime" | grep -qE "^v${TARGET_MAJOR}"; then
      flag="VERIFY"
      append_action "Windows stack says ${TARGET_MAJOR}, confirm loaded runtime; Windows: check RuntimeInformation.FrameworkDescription, not the stack setting"
    elif [ -n "$runtime" ]; then
      flag="ACTION"
      append_action "stack below ${TARGET_VERSION}"
    else
      flag="UNKNOWN"
      append_action "no runtime reported"
    fi
    ;;
esac

# One JSON object per resource, not a CSV row. Keeping this structured lets
# the caller both build the CSV and group the summary by flag without
# re-parsing quoted, comma-bearing CSV fields.
jq -cn --arg a "$name" --arg b "$rg" --arg c "$sub" --arg d "$wtype" \
       --arg e "$isslot" --arg f "$runtime" --arg g "$worker" --arg h "$tier" \
       --arg i "$flag" --arg j "$action" --arg k "$id" \
       --arg l "$hostVer" --arg m "$osFam" \
  '{name:$a, resourceGroup:$b, subscription:$c, workloadType:$d, isSlot:$e,
    runtime:$f, workerRuntime:$g, hostVersion:$l, os:$m, planTier:$h,
    flag:$i, action:$j, resourceId:$k}'
PROBEEOF
chmod +x "$WORK/probe.sh"

echo "Pass 2: probing $TOTAL resources via ARM (parallelism $PARALLEL)..." >&2

mkdir -p "$WORK/rows"
n=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  n=$((n + 1))
  "$WORK/probe.sh" "$line" "$ARM_ENDPOINT" "$API_VERSION" > "$WORK/rows/$(printf '%06d' "$n").json" &
  if [ $((n % PARALLEL)) -eq 0 ]; then
    wait
    printf '  probed %d/%d\r' "$n" "$TOTAL" >&2
  fi
done < "$WORK/graph.jsonl"
wait
printf '  probed %d/%d\n' "$n" "$TOTAL" >&2

# Sorted once here (by flag, then subscription, then name) so both the CSV
# and the per-flag summary below iterate the same, already-grouped order.
jq -s 'sort_by(.flag, .subscription, .name)' "$WORK"/rows/*.json > "$WORK/all.json"

{
  echo "$CSV_HEADER"
  jq -r '.[] | [.name, .resourceGroup, .subscription, .workloadType, .isSlot,
                .runtime, .workerRuntime, .hostVersion, .os, .planTier,
                .flag, .action, .resourceId] | @csv' "$WORK/all.json"
} > "$OUTPUT"

echo "" >&2
echo "Written: $OUTPUT" >&2
echo "" >&2
echo "Summary:" >&2

# PRIORITY only fixes display order, most urgent first
PRIORITY=(CRITICAL UNKNOWN ACTION VERIFY REVIEW MANUAL OK)
mapfile -t PRESENT_FLAGS < <(jq -r '[.[].flag] | unique | .[]' "$WORK/all.json")

# Only colorize when stderr is an actual terminal, so redirecting the summary
# to a file or another process doesn't end up with raw escape codes in it.
if [ -t 2 ]; then
  GRAY=$'\033[90m'
  RESET=$'\033[0m'
else
  GRAY=""
  RESET=""
fi

print_flag_group() {
  local f="$1"
  printf '  %s\n' "$f" >&2
  jq -r --arg f "$f" --arg gray "$GRAY" --arg reset "$RESET" \
    '.[] | select(.flag == $f) |
     "    - \(.name)  [\(.resourceGroup) / \(.subscription)]"
     + (if .action == "" then "" else "\n      " + $gray + .action + $reset end)' \
    "$WORK/all.json" >&2
}

declare -A is_present=()
for f in "${PRESENT_FLAGS[@]}"; do is_present["$f"]=1; done

declare -A shown=()
for p in "${PRIORITY[@]}"; do
  [ -n "${is_present[$p]:-}" ] || continue
  print_flag_group "$p"
  shown["$p"]=1
done
for f in "${PRESENT_FLAGS[@]}"; do
  [ -n "${shown[$f]:-}" ] && continue
  print_flag_group "$f"
done
echo "" >&2
echo "Rows written: $(( $(wc -l < "$OUTPUT") - 1 ))" >&2
