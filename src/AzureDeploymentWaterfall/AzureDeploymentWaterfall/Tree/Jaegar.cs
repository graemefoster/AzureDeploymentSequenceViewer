using System.Text.Json;

namespace AzureDeploymentWaterfall.Tree;

public static class Jaegar
{
    public static string Output(Deployment deployment)
    {
        var spans = new List<object>();
        var traceId = Guid.NewGuid().ToString();
        BuildModel(spans, traceId, deployment);
        return JsonSerializer.Serialize(new
        {
            data = new[]
            {
                new
                {
                    traceID = traceId, spans,
                    processes = new
                    {
                        tmp = new
                        {
                            serviceName = "template"
                        },
                        rsc = new
                        {
                            serviceName = "resource"
                        },
                        prt = new
                        {
                            serviceName = "overarching"
                        }
                    }
                }
            }
        });
    }

    private static void BuildModel(IList<object> spans, string traceId, Deployment deployment)
    {
        var currentEntry = new
        {
            traceID = traceId,
            spanID = deployment.UId,
            operationName = deployment.Name,
            references = new List<object>(),
            startTime = deployment.StartTime!.Value.ToUnixTimeMilliseconds() * 1000,
            duration = deployment.Duration!.Value.TotalMilliseconds * 1000,
            processID = deployment.IsTimingFromParent ? "prt" : "tmp",
            tags = new[]
            {
                new
                {
                    key = "error",
                    type = "boolean",
                    value = deployment.StatusCode == "Failed" ? "true" : "false"
                },
                new
                {
                    key = "correlation-id",
                    type = "string",
                    value = deployment.CorrelationId
                },
                new
                {
                    key = "start-time",
                    type = "string",
                    value = deployment.StartTime.Value.ToLocalTime().ToString("HH:mm:ss.ffffzzz")
                },
                new
                {
                    key = "end-time",
                    type = "string",
                    value = deployment.EndTime.Value.ToLocalTime().ToString("HH:mm:ss.ffffzzz")
                },
                new
                {
                    key = "url",
                    type = "string",
                    value =
                        $"https://portal.azure.com/#blade/HubsExtension/DeploymentDetailsBlade/overview/id/{Uri.EscapeDataString(deployment.Id)}"
                }
            },
            status = deployment.StatusCode
        };

        if (deployment.ParentDeploymentUId != null)
        {
            currentEntry.references.Add(new
            {
                refType = "CHILD_OF",
                traceID = traceId,
                spanID = deployment.ParentDeploymentUId,
                Id = deployment.Id
            });
        }

        spans.Add(currentEntry);

        foreach (var resource in deployment.Resources)
        {
            var resourceIdParts = resource.Id.Split('/');
            var resourceEntry = new
            {
                traceID = traceId,
                spanID = deployment.UId,
                operationName = string.Join('/', resourceIdParts[4..^1]),
                references = new[]
                {
                    new
                    {
                        refType = "CHILD_OF",
                        traceID = traceId,
                        spanID = deployment.UId
                    }
                },
                startTime = resource.StartTime.Value.ToUnixTimeMilliseconds() * 1000,
                duration = resource.Duration.Value.TotalMilliseconds * 1000,
                processID = "rsc",
                tags = new List<object>()
                {
                    new
                    {
                        key = "error",
                        type = "boolean",
                        value = resource.ProvisioningState == "Failed" ? "true" : "false",
                    },
                    new
                    {
                        key = "start-time",
                        type = "string",
                        value = resource.StartTime.Value.ToLocalTime().ToString("HH:mm:ss.ffffzzz")
                    },
                    new
                    {
                        key = "end-time",
                        type = "string",
                        value = resource.EndTime.Value.ToLocalTime().ToString("HH:mm:ss.ffffzzz")
                    }
                }
            };

            if (resource.ProvisioningState == "Failed")
            {
                resourceEntry.tags.Add(new
                {
                    key = "statusCode",
                    type = "string",
                    value = resource.StatusCode
                });

                resourceEntry.tags.Add(new
                {
                    key = "statusMessage",
                    type = "string",
                    value = resource.StatusMessage
                });
            }

            spans.Add(resourceEntry);
        }

        foreach (var childDeployment in deployment.ChildDeployments)
        {
            BuildModel(spans, traceId, childDeployment);
        }
    }
}