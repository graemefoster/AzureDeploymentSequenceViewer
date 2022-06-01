namespace AzureDeploymentWaterfall;

public class Deployment
{
    public string Id { get; set; }
    public string UId { get; set; }
    public bool IsTimingFromParent { get; set; }
    public string ParentDeploymentUId { get; set; }
    public string Name { get; set; }
    public string ResourceGroup { get; set; }
    public DateTimeOffset? StartTime { get; set; }
    public DateTimeOffset? EndTime { get; set; }
    public TimeSpan? Duration { get; set; }
    public Deployment[] ChildDeployments { get; set; }
    public Resource[] Resources { get; set; }
    public string ProvisioningState { get; set; }
    public string StatusCode { get; set; }
    public string StatusMessage { get; set; }
}