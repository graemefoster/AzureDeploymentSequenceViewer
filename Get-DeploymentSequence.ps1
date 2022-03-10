param (
    [Parameter(Mandatory = $true, ParameterSetName = 'Subscription')]
    [switch]
    $Subscription,

    [Parameter(Mandatory = $true, ParameterSetName = 'ResourceGroup')]
    [string]
    $ResourceGroupName,

    [Parameter(Mandatory = $true, ParameterSetName = 'ResourceGroup')]
    [Parameter(Mandatory = $true, ParameterSetName = 'Subscription')]
    [string]
    $DeploymentName,
    
    [Parameter(Mandatory = $true, ParameterSetName = 'ResourceGroup')]
    [Parameter(Mandatory = $true, ParameterSetName = 'Subscription')]
    [string]
    $OutputFile
    
)

Function _Recurse() {
    param (
        $DeploymentId,
        $Deployment,
        $ParentDeploymentUId,
        $DeploymentDuration,
        $DeploymentOperationsObject,
        $Level
    )

    Write-Debug "Recursing into $($DeploymentId) with $($DeploymentOperationsObject.Count) operations"

    $deploymentUid = [Guid]::NewGuid().ToString()
    $deploymentInfo = @{
        Id                  = $DeploymentId
        UId                 = $deploymentUid
        ParentDeploymentUId = $ParentDeploymentUId
        Name                = $Deployment.DeploymentName
        StartTime           = [System.DateTimeOffset]::new($Deployment.Timestamp) - $DeploymentDuration
        EndTime             = [System.DateTimeOffset]::new($Deployment.Timestamp)
        Duration            = $DeploymentDuration
        ChildDeployments    = @()
        Resources           = @()
    }
    
    $allChildDeployments = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    $allChildResources = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

    $no = $function:_TraceSubscriptionDeployment.ToString()
    $way = $function:_TraceResourceGroupDeployment.ToString()
    $man = $function:_Recurse.ToString()

    $DeploymentOperationsObject | ForEach-Object -Parallel {


        $function:_TraceSubscriptionDeployment = $using:no
        $function:_TraceResourceGroupDeployment = $using:way
        $function:_Recurse = $using:man

        if ($_.TargetResource -like '*Microsoft.Resources/deployments*') {

            if ($_.TargetResource -like '*/resourceGroups/*') {
                $newDeployment = (_TraceResourceGroupDeployment -DeploymentId $_.TargetResource -DeploymentUId $using:deploymentUid -Level ($using:Level + 1))
            }
            else {
                $newDeployment += (_TraceSubscriptionDeployment -DeploymentId $_.TargetResource -DeploymentUId $using:deploymentUid -Level ($using:Level + 1))
            } 

            ($using:allChildDeployments).Add($newDeployment)

        }
        elseif (-not [string]::IsNullOrWhiteSpace($_.TargetResource)) {
            $operationDetails = (ConvertFrom-Json (Invoke-AzRestMethod "https://management.azure.com$($_.Id)?api-version=2020-06-01").Content) 
            $timestamp = [System.DateTimeOffset]::new([System.DateTime]::Parse($operationDetails.properties.timestamp, [System.Globalization.CultureInfo]::CreateSpecificCulture("en-US"), [System.Globalization.DateTimeStyles]::AssumeUniversal))
            $duration = [System.Xml.XmlConvert]::ToTimeSpan($operationDetails.properties.duration)
            $newResource = @{
                Id        = $_.TargetResource
                StartTime = $timestamp - $duration
                EndTime   = $timestamp
                Duration  = $duration
            }

            ($using:allChildResources).Add($newResource)
        }
    }

    $deploymentInfo.ChildDeployments = $allChildDeployments.ToArray()
    $deploymentInfo.Resources = $allChildResources.ToArray()

    return $deploymentInfo
}

Function _TraceSubscriptionDeployment {
    param (
        $DeploymentId,
        $DeploymentUId,
        $Level
    )

    $indent = New-Object -TypeName 'string' -ArgumentList @("`t", $Level)
    Write-Debug "$($indent)Processing Subscription $($DeploymentId)"

    #Duration property not exposed on Get-AzDeployment
    $deployment = Get-AzSubscriptionDeployment -DeploymentId $DeploymentId
    $deploymentDuration = [System.Xml.XmlConvert]::ToTimeSpan((ConvertFrom-Json (Invoke-AzRestMethod "https://management.azure.com$($DeploymentId)?api-version=2018-01-01").Content).properties.duration)
    $deploymentOperations = Get-AzSubscriptionDeploymentOperation -DeploymentObject $deployment

    return (_Recurse -DeploymentId $DeploymentId -Deployment $deployment -ParentDeploymentUId $DeploymentUId -DeploymentDuration $deploymentDuration -DeploymentOperationsObject $deploymentOperations -Level ($Level + 1))
}

Function _TraceResourceGroupDeployment {
    param (
        $DeploymentId,
        $DeploymentUId,
        $Level
    )

    $indent = New-Object -TypeName 'string' -ArgumentList @("`t", $Level)
    Write-Debug "$($indent)Processing Resource Group $($DeploymentId)"

    #Duration property not exposed on Get-AzDeployment
    $deployment = Get-AzResourceGroupDeployment -Id $DeploymentId
    $deploymentDuration = [System.Xml.XmlConvert]::ToTimeSpan((ConvertFrom-Json (Invoke-AzRestMethod "https://management.azure.com$($DeploymentId)?api-version=2018-01-01").Content).properties.duration)
    $deploymentOperations = Get-AzResourceGroupDeploymentOperation -DeploymentName $deployment.DeploymentName -ResourceGroupName $deployment.ResourceGroupName

    return (_Recurse -DeploymentId $DeploymentId -Deployment $deployment -ParentDeploymentUId $DeploymentUId -DeploymentDuration $deploymentDuration -DeploymentOperationsObject $deploymentOperations -Level ($Level + 1))
}
Function _BuildOpenTelemetryModel {
    param (
        $Deployment,
        $TraceId
    )

    $spans = @()

    #Turn into something like Open Telemetry:
    $currentEntry = @{
        traceID       = $TraceId
        spanID        = $Deployment.UId
        operationName = $Deployment.Name
        references    = @()
        startTime     = $Deployment.StartTime.ToUnixTimeMilliSeconds() * 1000
        duration      = $Deployment.Duration.TotalMilliseconds * 1000
        processID     = "tmp"
    }
    if ($null -ne $Deployment.ParentDeploymentUId) {
        $currentEntry.references += @{
            refType = "CHILD_OF"
            traceID = $TraceId
            spanID  = $Deployment.ParentDeploymentUId
        }
    }
    else {
        Write-Debug "No parent for $($Deployment.Id)"
    }

    $spans += $currentEntry

    foreach ($resource in $Deployment.Resources) {
        $resourceIdParts = $resource.Id.Split('/')
        $resourceEntry = @{
            traceID       = $TraceId
            spanID        = $Deployment.UId
            operationName = [string]::Join('/', $resourceIdParts[4..($resourceIdParts.Count - 1)])
            references    = @(@{
                    refType = "CHILD_OF"
                    traceID = $TraceId
                    spanID  = $Deployment.UId
                })
            startTime     = $resource.StartTime.ToUnixTimeMilliSeconds() * 1000
            duration      = $resource.Duration.TotalMilliseconds * 1000
            processID     = "rsc"
        }
        $spans += $resourceEntry
    }

    foreach ($deployment in $Deployment.ChildDeployments) {
        if ($null -ne $deployment) {
            $spans += (_BuildOpenTelemetryModel -Deployment $deployment -TraceId $TraceId)
        }
    }

    return $spans
}

$context = (Get-AzContext)
if ($Subscription -eq $true) {
    $Deployments = (_TraceSubscriptionDeployment -DeploymentId "/subscriptions/$($context.Subscription.Id)/providers/Microsoft.Resources/deployments/$($DeploymentName)" -Level 0 -DeploymentUId ([Guid]::NewGuid()).ToString())
}
else {
    $Deployments = (_TraceResourceGroupDeployment -DeploymentId "/subscriptions/$($context.Subscription.Id)/resourceGroups/$($ResourceGroupName)/providers/Microsoft.Resources/deployments/$($DeploymentName)" -Level 0 -DeploymentUId ([Guid]::NewGuid()).ToString())
}

$uniqueTraceId = ([Guid]::NewGuid()).ToString()
$allSpans = (_BuildOpenTelemetryModel -Deployment $Deployments -TraceId $uniqueTraceId)

$openTelemetryLikeModel = @{
    data = @(
        @{
            traceID   = $uniqueTraceId
            spans     = $allSpans
            processes = @{
                tmp = @{
                    serviceName = "template"
                }
                rsc = @{
                    serviceName = "resource"
                }
            }
        }
    )
}

ConvertTo-Json -InputObject $openTelemetryLikeModel -Depth 50 | Out-File -FilePath $OutputFile

Write-Host "Written output to $OutputFile"

