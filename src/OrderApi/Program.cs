using Microsoft.AspNetCore.Diagnostics.HealthChecks;

var builder = WebApplication.CreateBuilder(args);

// WebHost.CreateDefaultBuilder / IWebHost are obsolete in .NET 10 and, with
// TreatWarningsAsErrors, a build break rather than a warning.
// WebApplication is the replacement and has been since .NET 6.
builder.Services.AddHealthChecks();

var app = builder.Build();

// Liveness: run no checks at all. A 200 means the process is up and serving
// HTTP — the only condition a restart can actually fix.
app.MapHealthChecks("/healthz/live", new HealthCheckOptions { Predicate = _ => false });

// Readiness: only checks tagged "ready". Nothing carries that tag today, so
// this stays a cheap 200; when a DB check arrives with tags: ["ready"] it
// counts here and nowhere else.
app.MapHealthChecks("/healthz/ready", new HealthCheckOptions { Predicate = c => c.Tags.Contains("ready") });

// Reports the runtime the container is actually running, which is what you want
// visible per revision while traffic is split between two of them.
app.MapGet("/version", () => Results.Ok(new
{
    framework = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
    os = System.Runtime.InteropServices.RuntimeInformation.OSDescription,
    revision = Environment.GetEnvironmentVariable("CONTAINER_APP_REVISION")
}));

app.MapGet("/orders/{orderId}", (string orderId) => Results.Ok(new { orderId, status = "Placed" }));

app.Run();
