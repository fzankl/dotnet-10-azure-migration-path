using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OrderFunctions.Services;

// The .NET 10 entry point for the isolated worker model.
//
// Before (in-process, .NET 8): a Startup class deriving from FunctionsStartup and
// registered with [assembly: FunctionsStartup(typeof(Startup))].
// After: a plain top-level program with the same shape as any ASP.NET Core app.
var builder = FunctionsApplication.CreateBuilder(args);

// Enables the ASP.NET Core HTTP integration, which lets HTTP triggers keep using
// HttpRequest and IActionResult. Remove this line and triggers must be rewritten
// against HttpRequestData and HttpResponseData instead.
builder.ConfigureFunctionsWebApplication();

builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

builder.Services.AddSingleton<IOrderService, OrderService>();

builder.Build().Run();
