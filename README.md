# .NET 10 in Azure: A Path Through Your Estate

Sample code for the article [.NET 10 in Azure: A Path Through Your Estate](https://blog.fzankl.de/dotnet-10-azure-migration-path).

.NET 8 and .NET 9 both reach end of support on **10 November 2026**, and the Azure Functions in-process model retires on the same day.

## Repository map

| Path | Article step |
| --- | --- |
| `scripts/full-inventory.sh` | **1.** Two-pass estate inventory (Resource Graph, then an ARM fan-out for what Graph can't see). Outputs a CSV |
| `src/OrderFunctions` | **2.** Function app on the .NET 10 isolated worker: HTTP trigger via the ASP.NET Core integration, Service Bus trigger with an output binding |
| `src/OrderApi` | **2, 3.** Containerised ASP.NET Core app. `Dockerfile` (.NET 10 / Ubuntu) vs `Dockerfile.net8.before` (.NET 8 / Debian). Exposes `/version` |
| `infrastructure/containerapp` | **4.** Container App, multiple-revision mode with a weighted traffic split |
| `infrastructure/appservice` | **5.** App Service on .NET 10 with a staging slot and `sticky_settings` |
| `infrastructure/functionapp-inprocess-before` | **6.** "Before": Windows Consumption, in-process, .NET 8 |
| `infrastructure/functionapp-isolated-after` | **6.** "After": same plan, isolated worker, .NET 10 |
| `infrastructure/functionapp` | **6.** Flex Consumption (`runtime_name` / `runtime_version`) |
| `infrastructure/functionapp-premium` | **6.** Elastic Premium (typed `application_stack` block) |

## Running the inventory

Needs `az` and `jq`. See the header of `scripts/full-inventory.sh` for options, permissions and limits.

```bash
az login

# Smoke test: if this returns rows, scope and permissions are fine
az graph query -q "resources | summarize count() by type"

./scripts/full-inventory.sh -o estate.csv        # whole estate, target .NET 10.0
./scripts/full-inventory.sh -s <sub-id> -n       # one subscription, pass 1 only (Reader is enough)
./scripts/full-inventory.sh -t 8.0               # different target version
```

Pass 1 needs Reader. Pass 2 additionally needs `Microsoft.Web/sites/config/list/action`, because listing application settings is a POST in ARM, not a read.

Both passes are read-only. Nothing is written, no app setting is changed.

## Everything else

The `src/` and `infrastructure/` directories are configuration examples for the article, not a deployable solution.  
They exist to be read and diffed. Each Terraform directory is a standalone configuration, and `Dockerfile.net8.before` is there to be diffed, not built.

```bash
diff infrastructure/functionapp-inprocess-before/main.tf \
     infrastructure/functionapp-isolated-after/main.tf
git diff --no-index src/OrderApi/Dockerfile.net8.before src/OrderApi/Dockerfile
```

If you do want to apply them: `resource_group_name`, `name_prefix` and `location` are required everywhere and have no defaults; `infrastructure/containerapp` additionally requires `container_image`. `src/OrderFunctions/local.settings.json.example` has to be copied to `local.settings.json` and filled in before running the function app locally.

## A note on how this was written

The code in this repository was written with AI assistance. The inventory script was reviewed and run against a live tenant before publishing; the Terraform and application samples are read-and-diff material for the article, not a deployable solution.
