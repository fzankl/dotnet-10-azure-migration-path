using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using OrderFunctions.Services;

namespace OrderFunctions;

/// <summary>
/// Queue-triggered function with an output binding.
///
/// In the in-process model the output was an [ServiceBus(...)] out parameter or an
/// IAsyncCollector&lt;T&gt;. In the isolated worker model the output binding becomes an
/// attribute on the method and the return value carries the payload.
/// </summary>
public class ServiceBusOrderFunction(IOrderService orderService, ILogger<ServiceBusOrderFunction> logger)
{
    [Function(nameof(HandleOrderPlaced))]
    [ServiceBusOutput("order-confirmations", Connection = "ServiceBusConnection")]
    public async Task<OrderConfirmation> HandleOrderPlaced(
        [ServiceBusTrigger("orders-placed", Connection = "ServiceBusConnection")]
        OrderPlaced message)
    {
        logger.LogInformation("Handling order {OrderId}", message.OrderId);

        return await orderService.ConfirmAsync(message.OrderId);
    }
}

/// <summary>Inbound message contract.</summary>
/// <param name="OrderId">Identifier of the order that was placed.</param>
/// <param name="PlacedAtUtc">Timestamp the order was accepted, in UTC.</param>
public record OrderPlaced(string OrderId, DateTimeOffset PlacedAtUtc);
