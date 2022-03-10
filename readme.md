# Get-DeploymentSequence

A Powershell script that can output a timeline of an Azure deployment in an OpenTelemetry format for viewing in a tool like Jaegar.

``` powershell
Connect-AzAccount -Tenant "<tenant>"

Set-AzContext -Subscription "<subscription>

.\Get-DeploymentWaterfall.ps1 -ResourceGroupName <rg-name> -DeploymentName "<deployment-name>" -OutputFile .\deployment-trace.json

```

Produces traces that look like this

![Sample Trace](/assets/sample-trace.png)
