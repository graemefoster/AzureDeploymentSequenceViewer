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
        $StartTimeViewedFromParent,
        $DeploymentDuration,
        $DeploymentOperationsObject,
        $Level
    )

    Write-Debug "Recursing into $($DeploymentId) with $($DeploymentOperationsObject.Count) operations"

    #Run some adjustments - sometimes we grab deployments that happened in the past.
    $deploymentEndTime = [System.DateTimeOffset]::new($Deployment.Timestamp)
    $deploymentStartTime = $deploymentEndTime.Add(-$DeploymentDuration)
    if ($null -ne $StartTimeViewedFromParent) {
        if ($StartTimeViewedFromParent -gt $deploymentStartTime) {
            $deploymentStartTime = $StartTimeViewedFromParent
            $deploymentEndTime = $deploymentStartTime.Add($DeploymentDuration)
        }
    }

    $deploymentUid = [Guid]::NewGuid().ToString()
    $deploymentInfo = @{
        Id                  = $DeploymentId
        UId                 = $deploymentUid
        ParentDeploymentUId = $ParentDeploymentUId
        Name                = $Deployment.DeploymentName
        StartTime           = $deploymentStartTime
        EndTime             = $deploymentEndTime
        Duration            = $DeploymentDuration
        ChildDeployments    = @()
        Resources           = @()
        ProvisioningState   = $Deployment.ProvisioningState
        StatusCode          = $Deployment.StatusCode
        StatusMessage       = $Deployment.StatusMessage
    }
    
    $allChildDeployments = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    $allChildResources = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

    $no = $function:_TraceSubscriptionDeployment.ToString()
    $way = $function:_TraceResourceGroupDeployment.ToString()
    $man = $function:_Recurse.ToString()

    $DeploymentOperationsObject | ForEach-Object -Parallel {

        $operation = $_

        $function:_TraceSubscriptionDeployment = $using:no
        $function:_TraceResourceGroupDeployment = $using:way
        $function:_Recurse = $using:man

        $deploymentStartTime = $using:deploymentStartTime
        $deploymentUid = $using:deploymentUid
        $level = $using:Level
        $allChildDeployments = $using:allChildDeployments
        $allChildResources = $using:allChildResources

        # DEBUGGING
        # foreach ( $operation in $DeploymentOperationsObject) {

        $operationDetails = (ConvertFrom-Json (Invoke-AzRestMethod "https://management.azure.com$($operation.Id)?api-version=2020-06-01").Content) 
        $timestamp = [System.DateTimeOffset]::new([System.DateTime]::Parse($operationDetails.properties.timestamp, [System.Globalization.CultureInfo]::CreateSpecificCulture("en-US"), [System.Globalization.DateTimeStyles]::AssumeUniversal))
        $duration = [System.Xml.XmlConvert]::ToTimeSpan($operationDetails.properties.duration)
        $operationStartTime = $timestamp.Add(-$duration)

        #Adjust the time on the operation if it reports as before the Deployment Start Time.
        if ($operationStartTime -lt $deploymentStartTime) {
            $operationStartTime = $deploymentStartTime
        }

        if ($operation.TargetResource -like '*Microsoft.Resources/deployments*') {
            if ($operation.TargetResource -like '*/resourceGroups/*') {
                $newDeployment = (_TraceResourceGroupDeployment -DeploymentId $operation.TargetResource -DeploymentUId $deploymentUid -OperationTimestamp $operationStartTime -Level ($level + 1))
            }
            else {
                $newDeployment += (_TraceSubscriptionDeployment -DeploymentId $operation.TargetResource -DeploymentUId $deploymentUid -OperationTimestamp $operationStartTime -Level ($level + 1))
            } 

            ($allChildDeployments).Add($newDeployment)

        }
        elseif (-not [string]::IsNullOrWhiteSpace($operation.TargetResource)) {
            $newResource = @{
                Id                = $operation.TargetResource
                StartTime         = $operationStartTime
                EndTime           = $timestamp
                Duration          = $duration
                ProvisioningState = $operation.ProvisioningState
                StatusCode        = $operation.StatusCode
                StatusMessage     = $operation.StatusMessage
            }

            ($allChildResources).Add($newResource)
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
        $OperationTimestamp,
        $Level
    )

    $indent = New-Object -TypeName 'string' -ArgumentList @("`t", $Level)
    Write-Debug "$($indent)Processing Subscription $($DeploymentId)"

    #Duration property not exposed on Get-AzDeployment
    $deployment = Get-AzSubscriptionDeployment -DeploymentId $DeploymentId
    $deploymentDuration = [System.Xml.XmlConvert]::ToTimeSpan((ConvertFrom-Json (Invoke-AzRestMethod "https://management.azure.com$($DeploymentId)?api-version=2018-01-01").Content).properties.duration)
    $deploymentOperations = Get-AzSubscriptionDeploymentOperation -DeploymentObject $deployment

    return (_Recurse -DeploymentId $DeploymentId -Deployment $deployment -ParentDeploymentUId $DeploymentUId -StartTimeViewedFromParent $OperationTimestamp -DeploymentDuration $deploymentDuration -DeploymentOperationsObject $deploymentOperations -Level ($Level + 1))
}

Function _TraceResourceGroupDeployment {
    param (
        $DeploymentId,
        $DeploymentUId,
        $OperationTimestamp,
        $Level
    )

    $indent = New-Object -TypeName 'string' -ArgumentList @("`t", $Level)
    Write-Debug "$($indent)Processing Resource Group $($DeploymentId)"

    #Duration property not exposed on Get-AzDeployment
    $deployment = Get-AzResourceGroupDeployment -Id $DeploymentId

    $deploymentDuration = [System.Xml.XmlConvert]::ToTimeSpan((ConvertFrom-Json (Invoke-AzRestMethod "https://management.azure.com$($DeploymentId)?api-version=2018-01-01").Content).properties.duration)
    $deploymentOperations = Get-AzResourceGroupDeploymentOperation -DeploymentName $deployment.DeploymentName -ResourceGroupName $deployment.ResourceGroupName

    return (_Recurse -DeploymentId $DeploymentId -Deployment $deployment -ParentDeploymentUId $DeploymentUId -StartTimeViewedFromParent $OperationTimestamp -DeploymentDuration $deploymentDuration -DeploymentOperationsObject $deploymentOperations -Level ($Level + 1))
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
        tags          = @(
            @{
                key   = 'error'
                type  = 'boolean'
                value = $Deployment.ProvisioningState -eq 'Failed'
            }
        )
        status        = $Deployment.ProvisioningState
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
            tags          = @(
                @{
                    key   = 'error'
                    type  = 'boolean'
                    value = $resource.ProvisioningState -eq 'Failed'
                }
            )
        }
        if ($resource.ProvisioningState -eq 'Failed') {
            $resourceEntry.tags += @{
                key   = 'statusCode'
                type  = 'string'
                value = $resource.StatusCode
            }
            $resourceEntry.tags += @{
                key   = 'statusMessage'
                type  = 'string'
                value = $resource.StatusMessage
            }
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

try {
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

}
catch {
    Write-Output "An error occurred running the script"
    Write-Output $_
}