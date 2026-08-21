using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using OrderFunctions.Services;

namespace OrderFunctions;

/// <summary>
/// HTTP trigger using the ASP.NET Core integration, so the signature matches what
/// an in-process .NET 8 function looked like. Without ConfigureFunctionsWebApplication()
/// in Program.cs this would take HttpRequestData and return HttpResponseData.
/// </summary>
public class HttpOrderFunction(IOrderService orderService, ILogger<HttpOrderFunction> logger)
{
    [Function(nameof(GetOrder))]
    public async Task<IActionResult> GetOrder(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "orders/{orderId}")]
        HttpRequest request,
        string orderId)
    {
        logger.LogInformation("Reading order {OrderId}", orderId);

        var order = await orderService.GetAsync(orderId);

        return order is null
            ? new NotFoundResult()
            : new OkObjectResult(order);
    }
}
