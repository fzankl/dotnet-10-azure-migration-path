namespace OrderFunctions.Services;

/// <summary>
/// Placeholder implementation. Replace it with your own data access; the point of
/// the sample is the hosting and binding shape, not the business logic.
/// </summary>
public class OrderService : IOrderService
{
    public Task<Order?> GetAsync(string orderId)
        => Task.FromResult<Order?>(new Order(orderId, "Placed"));

    public Task<OrderConfirmation> ConfirmAsync(string orderId)
        => Task.FromResult(new OrderConfirmation(orderId, DateTimeOffset.UtcNow));
}
