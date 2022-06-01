namespace AzureDeploymentWaterfall;

public static class AsyncEnumerableExtensions
{
    public static async Task<T[]> ToListAsync<T>(this IAsyncEnumerable<T> items,
        CancellationToken cancellationToken = default)
    {
        var results = new List<T>();
        await foreach (var item in items.WithCancellation(cancellationToken)
                           .ConfigureAwait(false))
            results.Add(item);
        return results.ToArray();
    }
}