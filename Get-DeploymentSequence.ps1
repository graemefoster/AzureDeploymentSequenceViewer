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
        $FirstDeploymentTime,
        $DeploymentId,
        $Deployment,
        $ParentDeploymentUId,
        $DeploymentDuration,
        $DeploymentOperationsObject,
        $Level
    )

    $indent = New-Object -TypeName 'string' -ArgumentList @("`t", $Level)

    #Special deployment: treat a deployment named 'environment' as something special. Lots of my projects use a deployment named environment to store context information
    if ($null -eq $FirstDeploymentTime) {
        $FirstDeploymentTime = $Deployment.Timestamp
    }

    #Run some adjustments - sometimes we grab deployments that happened in the past.
    $deploymentEndTime = [System.DateTimeOffset]::new($Deployment.Timestamp)
    $deploymentStartTime = $deploymentEndTime.Add(-$DeploymentDuration)
    Write-Host "$($indent)Deployment into $($Deployment.DeploymentName) with $($DeploymentOperationsObject.Count) operations. Deployment Timestamp: $($deploymentStartTime.ToLocalTime().ToString("HH:mm:ss.ffffzzz"))"

    $deploymentUid = [Guid]::NewGuid().ToString()
    $deploymentInfo = @{
        Id                  = $DeploymentId
        UId                 = $deploymentUid
        IsTimingFromParent  = $false
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
        $indent = $using:indent
        $allChildDeployments = $using:allChildDeployments
        $allChildResources = $using:allChildResources
        $FirstDeploymentTime = $using:FirstDeploymentTime

        # # DEBUGGING
        # foreach ( $operation in $DeploymentOperationsObject) {

        $operationDetails = (ConvertFrom-Json (Invoke-AzRestMethod "https://management.azure.com$($operation.Id)?api-version=2020-06-01").Content) 
        $timestamp = [System.DateTimeOffset]::new([System.DateTime]::Parse($operationDetails.properties.timestamp, [System.Globalization.CultureInfo]::CreateSpecificCulture("en-US"), [System.Globalization.DateTimeStyles]::AssumeUniversal))
        $duration = [System.Xml.XmlConvert]::ToTimeSpan($operationDetails.properties.duration)
        $operationStartTime = $timestamp.Add(-$duration)
        
        #Adjust the time on the operation if it reports as before the Deployment Start Time.
        if ($operationStartTime -lt $deploymentStartTime) {
            Write-Host "$($indent)- :: Operation start-time of $($operation.OperationId) reports before parent deployment start time. Shifting from $($operationStartTime.ToLocalTime().ToString("HH:mm:ss.ffffzzz")) to $($deploymentStartTime.ToLocalTime().ToString("HH:mm:ss.ffffzzz")) ::"
            $operationStartTime = $deploymentStartTime
        }

        if ($operation.TargetResource -like '*Microsoft.Resources/deployments*') {

            Write-Host "$($indent)- Deployment Operation $($operation.OperationId) to $($operation.TargetResource) @ $($operationStartTime.ToLocalTime().ToString("HH:mm:ss.ffffzzz"))"
            
            $asSeenFromParentDeployment = @{
                Id                  = $operation.OperationId
                UId                 = [Guid]::NewGuid().ToString()
                IsTimingFromParent  = $true
                ParentDeploymentUId = $deploymentUid
                Name                = $operation.TargetResource
                StartTime           = $operationStartTime
                EndTime             = $timestamp
                Duration            = $duration
                ChildDeployments    = @()
                Resources           = @()
                ProvisioningState   = $operation.ProvisioningOperation
                StatusCode          = $operation.StatusCode
                StatusMessage       = $operation.StatusMessage
            }

            if ($operation.TargetResource -like '*/resourceGroups/*') {
                $deployment = Get-AzResourceGroupDeployment -Id $operation.TargetResource -ErrorAction Continue
                if ($null -ne $deployment) {
                    $newDeployment = (_TraceResourceGroupDeployment -FirstDeploymentTime $FirstDeploymentTime -Deployment $deployment -DeploymentId $operation.TargetResource -DeploymentUId $asSeenFromParentDeployment.UId -OperationTimestamp $operationStartTime -Level ($level + 1))
                }
            }
            else {
                $deployment = Get-AzSubscriptionDeployment -DeploymentId $operation.TargetResource -ErrorAction Continue
                if ($null -ne $deployment) {
                    $newDeployment = (_TraceSubscriptionDeployment -FirstDeploymentTime $FirstDeploymentTime -Deployment $deployment -DeploymentId $operation.TargetResource -DeploymentUId $asSeenFromParentDeployment.UId -OperationTimestamp $operationStartTime -Level ($level + 1))
                }
            } 
            
            # Look for deployments way before / way ahead of time. Adjust them to fit with what the parent saw.
            if ($null -ne $deployment) {
                if ($newDeployment.StartTime -lt $asSeenFromParentDeployment.StartTime -or $newDeployment.StartTime -gt $asSeenFromParentDeployment.EndTime) {
                    $newDeployment.StartTime = $operationStartTime
                    $newDeployment.EndTime = $timestamp
                    $newDeployment.Duration = $duration
                }
                $asSeenFromParentDeployment.ChildDeployments = @($newDeployment)
                ($allChildDeployments).Add($asSeenFromParentDeployment)
            }
            else {

                #Not Found the deployment...
                Write-Host "$($indent)- Failed to find deployment $($operation.TargetResource)"
                $newResource = @{
                    Id                    = $operation.TargetResource
                    OperationId           = $operation.Id
                    StartTime             = $operationStartTime
                    EndTime               = $timestamp
                    Duration              = $duration
                    ProvisioningState     = $operation.ProvisioningState
                    ProvisioningOperation = $operation.ProvisioningOperation
                    StatusCode            = $operation.StatusCode
                    StatusMessage         = $operation.StatusMessage
                }
    
                ($allChildResources).Add($newResource)
            }

        }
        elseif (-not [string]::IsNullOrWhiteSpace($operation.TargetResource)) {

            $resourceName = $operationDetails.properties.targetResource.resourceName
            $resourceType = $operationDetails.properties.targetResource.resourceType
            Write-Host "$($indent)- Resource $($resourceType)/$($resourceName). Operation ($($operation.OperationId)) Timestamp: $($operationStartTime.ToLocalTime().ToString("HH:mm:ss.ffffzzz"))"

            $newResource = @{
                Id                    = $operation.TargetResource
                OperationId           = $operation.Id
                StartTime             = $operationStartTime
                EndTime               = $timestamp
                Duration              = $duration
                ProvisioningState     = $operation.ProvisioningState
                ProvisioningOperation = $operation.ProvisioningOperation
                StatusCode            = $operation.StatusCode
                StatusMessage         = $operation.StatusMessage
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
        $FirstDeploymentTime,
        $Deployment,
        $DeploymentId,
        $DeploymentUId,
        $Level
    )

    $indent = New-Object -TypeName 'string' -ArgumentList @("`t", $Level)
    Write-Debug "$($indent)Processing Subscription Deployment $($DeploymentId)"

    #Duration property not exposed on Get-AzDeployment
    $deploymentDuration = [System.Xml.XmlConvert]::ToTimeSpan((ConvertFrom-Json (Invoke-AzRestMethod "https://management.azure.com$($DeploymentId)?api-version=2018-01-01").Content).properties.duration)
    $deploymentOperations = Get-AzSubscriptionDeploymentOperation -DeploymentObject $deployment

    return (_Recurse -FirstDeploymentTime $FirstDeploymentTime -DeploymentId $DeploymentId -Deployment $deployment -ParentDeploymentUId $DeploymentUId -DeploymentDuration $deploymentDuration -DeploymentOperationsObject $deploymentOperations -Level ($Level + 1))
}

Function _TraceResourceGroupDeployment {
    param (
        $FirstDeploymentTime,
        $Deployment,
        $DeploymentId,
        $DeploymentUId,
        $Level
    )

    $indent = New-Object -TypeName 'string' -ArgumentList @("`t", $Level)
    Write-Debug "$($indent)Processing Resource Group $($DeploymentId)"

    #Duration property not exposed on Get-AzDeployment
    $deploymentDuration = [System.Xml.XmlConvert]::ToTimeSpan((ConvertFrom-Json (Invoke-AzRestMethod "https://management.azure.com$($DeploymentId)?api-version=2018-01-01").Content).properties.duration)
    $deploymentOperations = Get-AzResourceGroupDeploymentOperation -DeploymentName $deployment.DeploymentName -ResourceGroupName $deployment.ResourceGroupName

    return (_Recurse -FirstDeploymentTime $FirstDeploymentTime -DeploymentId $DeploymentId -Deployment $deployment -ParentDeploymentUId $DeploymentUId -DeploymentDuration $deploymentDuration -DeploymentOperationsObject $deploymentOperations -Level ($Level + 1))
}
Function _BuildOpenTelemetryModel {
    param (
        $TenantId,
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
        processID     = $Deployment.IsTimingFromParent ? "prt" : "tmp"
        tags          = @(
            @{
                key   = 'error'
                type  = 'boolean'
                value = $Deployment.ProvisioningState -eq 'Failed'
            },
            @{
                key   = 'start-time'
                type  = 'string'
                value = $Deployment.StartTime.ToLocalTime().ToString("HH:mm:ss.ffffzzz")
            },
            @{
                key   = 'end-time'
                type  = 'string'
                value = $Deployment.EndTime.ToLocalTime().ToString("HH:mm:ss.ffffzzz")
            },
            @{
                key   = 'url'
                type  = 'string'
                value = "https://portal.azure.com/#blade/HubsExtension/DeploymentDetailsBlade/overview/id/$([System.Uri]::EscapeDataString($Deployment.Id))"
            }
        )
        status        = $Deployment.ProvisioningState
    }
    if ($null -ne $Deployment.ParentDeploymentUId) {
        $currentEntry.references += @{
            refType = "CHILD_OF"
            traceID = $TraceId
            spanID  = $Deployment.ParentDeploymentUId
            Id      = $Deployment.AzureId
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
                },
                @{
                    key   = 'start-time'
                    type  = 'string'
                    value = $resource.StartTime.ToLocalTime().ToString("HH:mm:ss.ffffzzz")
                },
                @{
                    key   = 'end-time'
                    type  = 'string'
                    value = $resource.EndTime.ToLocalTime().ToString("HH:mm:ss.ffffzzz")
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
            $spans += (_BuildOpenTelemetryModel -Deployment $deployment -TraceId $TraceId -TenantId $TenantId)
        }
    }

    return $spans
}

try {
    $context = (Get-AzContext)
    if ($Subscription -eq $true) {
        $deployment = Get-AzSubscriptionDeployment -DeploymentId "/subscriptions/$($context.Subscription.Id)/providers/Microsoft.Resources/deployments/$($DeploymentName)" -ErrorAction Continue
        $Deployments = (_TraceSubscriptionDeployment -FirstDeploymentTime $null -OperationTimestamp $null -Deployment $deployment -DeploymentId $deployment.Id -Level 0 -DeploymentUId ([Guid]::NewGuid()).ToString())
    }
    else {
        $deploymentId = "/subscriptions/$($context.Subscription.Id)/resourceGroups/$($ResourceGroupName)/providers/Microsoft.Resources/deployments/$($DeploymentName)"
        $deployment = Get-AzResourceGroupDeployment -Id $deploymentId -ErrorAction Continue
        $Deployments = (_TraceResourceGroupDeployment -FirstDeploymentTime $null -OperationTimestamp $null -Deployment $deployment -DeploymentId $deploymentId -Level 0 -DeploymentUId ([Guid]::NewGuid()).ToString())
    }

    $uniqueTraceId = ([Guid]::NewGuid()).ToString()
    $allSpans = (_BuildOpenTelemetryModel -FirstDeploymentTime $null -Deployment $Deployments -TenantId $context.Tenant.Id -TraceId $uniqueTraceId)

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
                    prt = @{
                        serviceName = "parentView"
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