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
        OutputType output,
        string? outputFile)
    {
        var cred = new AzureCliCredential(new AzureCliCredentialOptions()
        {
            TenantId = tenantId.ToString()
        });
        _client = new ArmClient(cred);
        _subscription = await _client.GetSubscriptions().GetAsync(subscriptionId.ToString());
        await SequenceDeployment(GetSubscriptionLevelDeployment(deploymentName), output, outputFile);
    }

    public static async Task SequenceDeployment(
        Guid? tenantId,
        Guid subscriptionId,
        string resourceGroupName,
        string deploymentName,
        OutputType output,
        string? outputFile)
    {
        var cred = new AzureCliCredential(new AzureCliCredentialOptions()
        {
            TenantId = tenantId.ToString()
        });
        _client = new ArmClient(cred);
        _subscription = await _client.GetSubscriptions().GetAsync(subscriptionId.ToString());
        await SequenceDeployment(GetResourceGroupLevelDeployment(resourceGroupName, deploymentName), output,
            outputFile);
    }

    private static async Task SequenceDeployment(
        Task<Response<ArmDeploymentResource>> deployment,
        OutputType output,
        string? outputFile)
    {
        var deploymentTree = await Recurse(DateTimeOffset.MinValue, null, null, await deployment, 1);

        if (output == OutputType.Cli)
        {
            Console.WriteLine(TreeDrawer.Draw(deploymentTree));
        }
        else
        {
            if (outputFile != null)
            {
                await File.WriteAllTextAsync(outputFile, Jaegar.Output(deploymentTree));
                Console.WriteLine($"Written output to {outputFile}");
            }
            else
            {
                Console.WriteLine();
            }
        }
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
        DateTimeOffset firstDeploymentTime,
        Deployment? previousDeployment,
        string? resourceGroup,
        ArmDeploymentResource deployment,
        int level)
    {
        firstDeploymentTime = firstDeploymentTime == DateTimeOffset.MinValue
            ? deployment.Data.Properties.Timestamp!.Value.Subtract(deployment.Data.Properties.Duration!.Value)
            : firstDeploymentTime;

        var uId = Guid.NewGuid().ToString();

        var startTime = deployment.Data.Properties.Duration != null
            ? deployment.Data.Properties.Timestamp.GetValueOrDefault()
                .Subtract(deployment.Data.Properties.Duration.Value)
            : deployment.Data.Properties.Timestamp ?? firstDeploymentTime;

        if (previousDeployment != null && previousDeployment.EndTime != null && previousDeployment.StartTime != null)
        {
            if (startTime > previousDeployment.EndTime)
            {
                startTime = previousDeployment.EndTime.Value.Subtract(deployment.Data.Properties.Duration ??
                                                                      TimeSpan.Zero);
            }

            if (startTime < previousDeployment.StartTime)
            {
                startTime = previousDeployment.StartTime.Value;
            }
        }

        var deploymentItem = new Deployment()
        {
            Id = deployment.Id.ToString(),
            CorrelationId = deployment.Data.Properties.CorrelationId,
            UId = uId,
            Duration = deployment.Data.Properties.Duration,
            Name = deployment.Data.Name,
            ResourceGroup = resourceGroup,
            EndTime = startTime.Add(deployment.Data.Properties.Duration ?? TimeSpan.Zero),
            StartTime = startTime,
            StatusCode = deployment.Data.Properties.ProvisioningState?.ToString() ?? string.Empty,
            ParentDeploymentUId = previousDeployment?.UId ?? string.Empty,
            StatusMessage = deployment.Data.Properties.Error?.Message ?? string.Empty,
            Resources = await GetResources(deployment, startTime, deployment.Data.Properties.Timestamp).ToListAsync()
        };
        Console.WriteLine(deploymentItem.Name);

        deploymentItem.ChildDeployments =
            await GetDeployments(firstDeploymentTime, deploymentItem, deployment, level + 1).ToListAsync();
        return deploymentItem;
    }

    private static async IAsyncEnumerable<Resource> GetResources(
        ArmDeploymentResource deployment,
        DateTimeOffset deploymentStartTime,
        DateTimeOffset? deploymentEndTime)
    {
        await foreach (var operation in deployment.GetDeploymentOperationsAsync())
        {
            var operationStartTime =
                operation.Properties.Timestamp?.Subtract(operation.Properties.Duration ?? TimeSpan.Zero);

            if (operationStartTime < deploymentStartTime)
            {
                operationStartTime = deploymentStartTime;
            }

            var operationEndTime = operationStartTime.GetValueOrDefault()
                .Add(operation.Properties.Duration.GetValueOrDefault());

            if (deploymentEndTime.HasValue && operationEndTime > deploymentEndTime)
            {
                operationEndTime = deploymentEndTime.Value;
                operationStartTime = operationEndTime.Subtract(operation.Properties.Duration.GetValueOrDefault());
            }

            if (operation.Properties.TargetResource != null &&
                operation.Properties.TargetResource?.ResourceType?.Type != "deployments")
            {
                yield return new Resource()
                {
                    Id = operation.Properties.TargetResource!.Id,
                    Name = operation.Properties.TargetResource!.ResourceName,
                    OperationId = operation.Id,
                    StartTime = operationStartTime,
                    EndTime = operationEndTime,
                    Duration = operation.Properties.Duration.GetValueOrDefault(),
                    ProvisioningState = operation.Properties.ProvisioningState,
                    ProvisioningOperation = operation.Properties.ProvisioningOperation,
                    StatusCode = operation.Properties.StatusCode,
                    StatusMessage = operation.Properties.StatusMessage?.Status ?? string.Empty
                };
            }
        }
    }

    private static async IAsyncEnumerable<Deployment> GetDeployments(
        DateTimeOffset firstDeploymentTime,
        Deployment deployment,
        ArmDeploymentResource armDeployment,
        int level)
    {
        await foreach (var operation in armDeployment.GetDeploymentOperationsAsync())
        {
            if (operation.Properties.ProvisioningOperation == ProvisioningOperationKind.Create &&
                operation.Properties.TargetResource.ResourceType?.Type == "deployments")
            {
                var isResourceGroupLevel = operation.Properties.TargetResource.Id.Contains("resourceGroups",
                    StringComparison.InvariantCultureIgnoreCase);

                yield return await Recurse(
                    firstDeploymentTime,
                    deployment,
                    isResourceGroupLevel ? operation.Properties.TargetResource.Id.Split('/')[4] : null,
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