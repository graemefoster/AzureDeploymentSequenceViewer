// See https://aka.ms/new-console-template for more information

using System.CommandLine;
using System.CommandLine.Builder;
using System.CommandLine.Parsing;
using AzureDeploymentWaterfall;

var tenantIdOption = new Option<Guid?>("--tenant-id")
{
    IsRequired = false
};
var subscriptionIdOption = new Option<Guid>("--subscription-id")
{
    IsRequired = true
};
var resourceGroupOption = new Option<string?>("--resource-group")
{
    IsRequired = false,
};
var deploymentNameOption = new Option<string>("--deployment-name")
{
    IsRequired = true
};
var outputOption = new Option<OutputType>("--output")
{
    IsRequired = true
};

var outputFileOption = new Option<string?>("--output-file")
{
    IsRequired = false
};

var rootCommand = new RootCommand("AzureDiagrams");

var subscriptionCommand = new Command("subscription")
{
    tenantIdOption,
    subscriptionIdOption,
    deploymentNameOption,
    outputOption,
    outputFileOption
};

var resourceGroup = new Command("resource-group")
{
    tenantIdOption,
    subscriptionIdOption,
    resourceGroupOption,
    deploymentNameOption,
    outputOption,
    outputFileOption
};

rootCommand.AddCommand(subscriptionCommand);
rootCommand.AddCommand(resourceGroup);

subscriptionCommand.SetHandler((Guid? tenantId, Guid subscriptionId, string deploymentName, OutputType output, string? outputFile) =>
{
    Sequencer.SequenceDeployment(
            tenantId,
            subscriptionId,
            deploymentName,
            output,
            outputFile
        )
        .Wait();
}, tenantIdOption, subscriptionIdOption, deploymentNameOption, outputOption, outputFileOption);

resourceGroup.SetHandler((Guid? tenantId, Guid subscriptionId, string resourceGroupName, string deploymentName, OutputType output, string? outputFile) =>
{
    Sequencer.SequenceDeployment(
            tenantId,
            subscriptionId,
            resourceGroupName,
            deploymentName,
            output,
            outputFile
        )
        .Wait();
}, tenantIdOption, subscriptionIdOption, resourceGroupOption, deploymentNameOption, outputOption, outputFileOption);

var parser =
    new CommandLineBuilder(rootCommand)
        .UseDefaults()
        .UseHelp()
        .UseExceptionHandler((e, ctx) =>
        {
            Console.WriteLine(e.InnerException?.Message ?? e.Message);
            Console.WriteLine(e.ToString());
            ctx.ExitCode = -1;
        }).Build();

return await parser.InvokeAsync(args);