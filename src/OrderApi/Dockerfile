# .NET 10: the default tags resolve to Ubuntu 24.04 "Noble Numbat".
# Debian images are not shipped for .NET 10 at all, so this is not a preference
# you can opt out of by picking a different default tag.
#
# Pin the distro explicitly. `10.0` and `10.0-noble` mean the same thing today,
# and being explicit means the next default change is visible in a diff.
FROM mcr.microsoft.com/dotnet/sdk:10.0-noble AS build
WORKDIR /src

COPY ["OrderApi.csproj", "./"]
RUN dotnet restore "OrderApi.csproj"

COPY . .
RUN dotnet publish "OrderApi.csproj" -c Release -o /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble AS final
WORKDIR /app

# Ubuntu package names, not Debian ones. This is the layer that breaks on upgrade:
# look up the equivalent at https://packages.ubuntu.com/ before assuming your
# registry is at fault.
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        libfontconfig1 \
        fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# The non-root `app` user has shipped in the Linux images since .NET 8. If your
# Dockerfile creates a user called `app` itself, that now collides.
USER $APP_UID

COPY --from=build /app/publish .

ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

ENTRYPOINT ["dotnet", "OrderApi.dll"]
