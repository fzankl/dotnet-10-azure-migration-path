namespace OrderFunctions.Services;

public interface IOrderService
{
    Task<Order?> GetAsync(string orderId);

    Task<OrderConfirmation> ConfirmAsync(string orderId);
}

/// <summary>Minimal order projection returned by the HTTP trigger.</summary>
/// <param name="OrderId">Identifier of the order.</param>
/// <param name="Status">Current processing status.</param>
public record Order(string OrderId, string Status);

/// <summary>Outbound message contract written to the confirmations queue.</summary>
/// <param name="OrderId">Identifier of the confirmed order.</param>
/// <param name="ConfirmedAtUtc">Timestamp the confirmation was issued, in UTC.</param>
public record OrderConfirmation(string OrderId, DateTimeOffset ConfirmedAtUtc);
