using Azure;
using Azure.Identity;
using Azure.ResourceManager;
using Azure.ResourceManager.Resources;
using Azure.ResourceManager.Resources.Models;
using AzureDeploymentWaterfall.Tree;

namespace AzureDeploymentWaterfall;

class Sequencer
{
    private static ArmClient _client;
    private static Response<SubscriptionResource> _subscription;

    public static async Task SequenceDeployment(
        Guid? tenantId,
        Guid subscriptionId,
        string deploymentName,
        OutputType output)
    {
        var cred = new AzureCliCredential(new AzureCliCredentialOptions()
        {
            TenantId = tenantId.ToString()
        });
        _client = new Azure.ResourceManager.ArmClient(cred);
        _subscription = await _client.GetSubscriptions().GetAsync(subscriptionId.ToString());
        var deployment = await GetSubscriptionLevelDeployment(deploymentName);
        var deploymentTree = await Recurse(null, null, null, deployment, 1);

        Console.WriteLine(TreeDrawer.Draw(deploymentTree));
    }

    private static async Task<Response<ArmDeploymentResource>> GetSubscriptionLevelDeployment(string deploymentName)
    {
        return await _subscription.Value.GetArmDeploymentAsync(deploymentName);
    }

    private static async Task<Response<ArmDeploymentResource>> GetResourceGroupLevelDeployment(string rg,
        string deploymentName)
    {
        return await (await _subscription.Value.GetResourceGroupAsync(rg)).Value.GetArmDeploymentAsync(deploymentName);
    }

    private static async Task<Deployment> Recurse(
        DateTimeOffset? firstDeploymentTime,
        string? resourceGroup,
        ArmDeploymentResource? parentDeployment,
        ArmDeploymentResource deployment,
        int level)
    {
        firstDeploymentTime ??=
            deployment.Data.Properties.Timestamp?.Subtract(deployment.Data.Properties.Duration!.Value);

        return new Deployment()
        {
            Id = deployment.Id.ToString(),
            Duration = deployment.Data.Properties.Duration,
            Name = deployment.Data.Name,
            ResourceGroup = resourceGroup,
            EndTime = deployment.Data.Properties.Timestamp,
            StartTime = deployment.Data.Properties.Duration != null
                ? deployment.Data.Properties.Timestamp?.Subtract(deployment.Data.Properties.Duration.Value)
                : null,
            StatusCode = deployment.Data.Properties.ProvisioningState?.ToString() ?? string.Empty,
            ParentDeploymentUId = parentDeployment?.Id.ToString() ?? string.Empty,
            StatusMessage = deployment.Data.Properties.Error?.Message ?? string.Empty,
            ChildDeployments = await GetDeployments(firstDeploymentTime, deployment, level + 1).ToListAsync(),
            Resources = await GetResources(deployment).ToListAsync()
        };
    }

    private static async IAsyncEnumerable<Resource> GetResources(ArmDeploymentResource deployment)
    {
        await foreach (var operation in deployment.GetDeploymentOperationsAsync())
        {
            if (operation.Properties.ProvisioningOperation == ProvisioningOperationKind.Create &&
                operation.Properties.TargetResource != null &&
                operation.Properties.TargetResource?.ResourceType?.Type != "deployments")
            {
                yield return new Resource()
                {
                    Id = operation.Properties.TargetResource!.Id,
                    Name = operation.Properties.TargetResource!.ResourceName,
                    OperationId = operation.Id,
                    StartTime =
                        operation.Properties.Timestamp?.Subtract(operation.Properties.Duration ?? TimeSpan.Zero),
                    EndTime = operation.Properties.Timestamp,
                    Duration = operation.Properties.Duration,
                    ProvisioningState = operation.Properties.ProvisioningState,
                    ProvisioningOperation = operation.Properties.ProvisioningOperation,
                    StatusCode = operation.Properties.StatusCode,
                    StatusMessage = operation.Properties.StatusMessage?.Status ?? string.Empty
                };
            }
        }
    }

    private static async IAsyncEnumerable<Deployment> GetDeployments(
        DateTimeOffset? firstDeploymentTime,
        ArmDeploymentResource deployment,
        int level)
    {
        await foreach (var operation in deployment.GetDeploymentOperationsAsync())
        {
            if (operation.Properties.ProvisioningOperation == ProvisioningOperationKind.Create &&
                operation.Properties.TargetResource.ResourceType?.Type == "deployments")
            {
                var isResourceGroupLevel = operation.Properties.TargetResource.Id.Contains("resourceGroups",
                    StringComparison.InvariantCultureIgnoreCase);

                yield return await Recurse(
                    firstDeploymentTime,
                    isResourceGroupLevel ? operation.Properties.TargetResource.Id.Split('/')[4] : null,
                    deployment,
                    isResourceGroupLevel
                        ? await GetResourceGroupLevelDeployment(
                            operation.Properties.TargetResource.Id.Split('/')[4],
                            operation.Properties.TargetResource.ResourceName)
                        : await GetSubscriptionLevelDeployment(operation.Properties.TargetResource.ResourceName),
                    level
                );
            }
        }
    }
}