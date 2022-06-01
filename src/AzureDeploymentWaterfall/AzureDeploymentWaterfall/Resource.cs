using Azure.ResourceManager.Resources.Models;

namespace AzureDeploymentWaterfall;

public class Resource
{
    public string Id { get; set; }
    public string Name { get; set; }
    public string OperationId { get; set; }
    public DateTimeOffset? StartTime { get; set; }
    public DateTimeOffset? EndTime { get; set; }
    public TimeSpan? Duration { get; set; }
    public string ProvisioningState { get; set; }
    public ProvisioningOperationKind? ProvisioningOperation { get; set; }
    public string StatusCode { get; set; }
    public string StatusMessage { get; set; }
}