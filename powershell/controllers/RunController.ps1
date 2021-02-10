<# 
PSScriptInfo 
.VERSION 1.0 
.AUTHOR Clément Joye 
.COMPANYNAME ADACA Authority AB 
.COPYRIGHT (C) 2020 Clément Joye / ADACA Authority AB - All Rights Reserved 
.LICENSEURI https://github.com/clement-joye/Kubernetes-UI-Tests/blob/main/LICENSE 
.PROJECTURI https://github.com/clement-joye/Kubernetes-UI-Tests 
#>
#Requires -Version 5
<#
    .SYNOPSIS
    Run controller used to deploy the resources to the cluster, monitor the pods, dispose the resources of the cluster, export the results to local host.
#>

. ".\services\LoggingService.ps1"
. ".\services\KubectlService.ps1"
. ".\services\AksService.ps1"

function Clear-Deployments {
    
    Clear-KubectlDeployments -Kind "pod"
    Clear-KubectlDeployments -Kind "pvc"
    Clear-KubectlDeployments -Kind "pv"
    Clear-KubectlDeployments -Kind "configmap"
}

function Wait-ClusterReady {

    param(
       [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
       [PSCustomObject] $ClusterParameters,
       [Parameter ( Mandatory = $False, Position = 1, ValueFromPipelineByPropertyName = $True )]
       [int] $Timeout = 500
    )

    $IsLocal = $ClusterParameters.IsLocal
    $Wait = $ClusterParameters.Wait
    $Name = $ClusterParameters.Name
    $ResourceGroup = $ClusterParameters.ResourceGroup

    if( $IsLocal -eq $False ) {

        if ( $Wait -eq $False ) {

            Wait-AksClusterState -ResourceGroup $ResourceGroup -Name $Name -State "created"
        }
        
        Get-AksCredentials -ResourceGroup $ResourceGroup -Name $Name
    }

    Set-KubectlContext $Name
}

function New-Deployments {

    param(
       [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
       [PSCustomObject[]] $Deployments,
       [Parameter ( Mandatory = $False, Position = 1, ValueFromPipelineByPropertyName = $True )]
       [int] $MaxPodLimit = -1
    )

    try {

        Write-TimestampOutput -Message "---[Deployment started]---`r`n"

        $Count = 0

        ForEach ( $Deployment in $Deployments ) {

            if ( $MaxPodLimit -eq -1 ) {
            
                Write-TimestampOutput -Message "Checking for file existence $($Deployment.Path): $(Test-Path $Deployment.Path -PathType Leaf)"

                Add-KubectlDeployment -Name $Deployment.Name -Filepath $Deployment.Path
            }
            else {

                if ( $Deployment.Deployed -eq $True) {

                    continue;
                }

                Write-TimestampOutput -Message "Checking for file existence $($Deployment.Path): $(Test-Path $Deployment.Path -PathType Leaf)"

                Add-KubectlDeployment -Name $Deployment.Name -Filepath $Deployment.Path
                
                $Deployment.Deployed = $True

                $Count++

                if ( $Count -ge $MaxPodLimit ) {

                    break;
                }
            }
        }
        
        Write-TimestampOutput -Message "---[Deployment done]--- success`r`n"
    }
    catch {

        Write-TimestampOutput -Message "---[Deployment done]--- failure`r`n"
        Write-Error $_
    }
}

function Initialize-Deployments {

    param(
       [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
       [PSCustomObject[]] $ResourcesDeployments,
       [Parameter ( Mandatory = $True, Position = 1, ValueFromPipelineByPropertyName = $True )]
       [PSCustomObject[]] $ReportsDeployments,
       [Parameter ( Mandatory = $True, Position = 2, ValueFromPipelineByPropertyName = $True )]
       [PSCustomObject[]] $Deployments
    )

    # Clear Deployments
    Clear-Deployments

    # Resources Deployments
    New-Deployments -Deployments $ResourcesDeployments
    Wait-PodsReady -Deployments ( $ResourcesDeployments | Where-Object { $_.Name -like "*pod" } ).Name
    
    # Reports Deployments
    New-Deployments -Deployments $ReportsDeployments
    Wait-PodsReady -Deployments ( $ReportsDeployments | Where-Object { $_.Name -like "*pod" } ).Name

    Add-ConfigMap -Name "cypress-config" -SourcePath "../cypress.json"

    # Clear previous resources and reports
    Invoke-PodCommand -PodName "resources-pod" -Command "rm -rf ./cypress/*"
    Invoke-PodCommand -PodName "reports-pod" -Command "rm -rf ./reports/*"

    # Copy cypress resources
    Copy-LocalToPod -PodName "resources-pod" -SourcePath "../cypress/" -DestinationPath "/"

    # Test folder
    $Files = ( ( Invoke-PodCommand -PodName "resources-pod" -Command "find /cypress/integration -name '*.spec.js'") | Out-String )

    ForEach ($Deployment in $Deployments) {

        if ( $Files -notlike "*$($Deployment.Name)*" ) {

            throw "Copy of resources failed"
        }
    }
    
    Clear-KubectlDeployments -Kind "pod"
}

function Wait-PodsReady {

    param(
       [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
       [string[]] $Deployments,
       [Parameter ( Mandatory = $False, Position = 1, ValueFromPipelineByPropertyName = $True )]
       [int] $Timeout = 180
    )

    try {

        Write-TimestampOutput -Message "[Started] Waiting for pods ready"

        Wait-MultiplePodConditions -Condition "Ready" -PodNames $Deployments
    
        Write-TimestampOutput -Message "[Done] Waiting for pods ready - Success"
    }
    catch {

        Write-TimestampOutput -Message "[Done] Waiting for pods ready - Failure"
        Write-Error $_ -ErrorAction Stop
    }
}

function Wait-PodsSucceededOrFailed {

    param(
       [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
       [PSCustomObject[]] $Deployments,
       [Parameter ( Mandatory = $True, Position = 1, ValueFromPipelineByPropertyName = $True )]
       [int] $MaxPodLimit,
       [Parameter ( Mandatory = $False, Position = 2, ValueFromPipelineByPropertyName = $True )]
       [int] $Timeout = 300,
       [Parameter ( Mandatory = $False, Position = 3, ValueFromPipelineByPropertyName = $True )]
       [int] $Interval = 5
    )

    Start-Sleep -s 3
    $Count = 0
    $Animation = @( ".", "..", "..." )
    $CompletedHistory = @()

    do {

        if ( ($Count % $Interval) -eq 0 ) {

            $PodsRunning = Get-PodsInfo -Status "Running"
            $PodsFailed = Get-PodsInfo -Status "Failed"
            $PodsCompleted = Get-PodsInfo -Status "Succeeded"
            $RemainingDeployments = ( $Deployments | Where-Object { $_.Deployed -eq $False } )

            $RunningNumber   = $PodsRunning.Count
            $FailedNumber    = $PodsFailed.Count
            $RemainingNumber = $RemainingDeployments.Count
            $CompletedNumber = $CompletedHistory.Count
            
            $RunningPercent   = [math]::Round( $RunningNumber   / $Deployments.Count * 100 )
            $FailedPercent    = [math]::Round( $FailedNumber    / $Deployments.Count * 100 )
            $CompletedPercent = [math]::Round( $CompletedNumber / $Deployments.Count * 100 )
            $RemainingPercent = [math]::Round( $RemainingNumber / $Deployments.Count * 100 )

            ForEach ( $Item in $PodsCompleted ) { 
                
                if( $CompletedHistory.Contains($Item.PodName) -eq $False ) {

                    Remove-KubectlDeployment -Kind "pod" -Name $Item.PodName
    
                    $CompletedHistory += $Item.PodName 
                }
            }
    
            ForEach ( $Item in $PodsFailed ) { Write-TimestampOutput -Message "$(Get-PodLogs -PodName $Item.PodName)`r`n" }

            if ( ( $RunningNumber -lt $MaxPodLimit ) -And $RemainingNumber -gt 0 ) {

                New-Deployments -Deployments $Deployments -MaxPodLimit 1
            }
        }

        Write-Progress -Activity 'Running' -Status "$(Get-TimeStamp) Test Pod status: Running: $RunningPercent% - Succeeded: $CompletedPercent% - Failed: $FailedPercent% - Queued: $RemainingPercent% $($Animation[ ($Count % 4)])"
        
        Start-Sleep -s 1

        $Count++

    } while ( ($RunningNumber -gt 0 -Or $RemainingNumber -gt 0) -And $FailedNumber -eq 0)

    $Pods = @{}
    $PodsCompleted = Get-PodsInfo -Status "Succeeded"
    
    ForEach ( $Item in $PodsRunning          ) { if ($Pods.ContainsKey( $Item.PodName ) -eq $False) { $Pods.Add( $Item.PodName, "Running"      ) }}
    ForEach ( $Item in $CompletedHistory     ) { if ($Pods.ContainsKey( $item         ) -eq $False) { $Pods.Add( $Item,         "Succeeded"    ) }}
    ForEach ( $Item in $PodsFailed           ) { if ($Pods.ContainsKey( $Item.PodName ) -eq $False) { $Pods.Add( $Item.PodName, "Failed"       ) }}
    ForEach ( $Item in $RemainingDeployments ) { if ($Pods.ContainsKey( $Item.Name    ) -eq $False) { $Pods.Add( $Item.Name,    "Not Deployed" ) }}

    Write-Progress -Activity "Running" -Completed

    Write-TimestampOutput -Message "$($Pods | Out-String) `r`n"
}

function Export-TestResults {

    param(
       [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
       [String] $SourcePath,
       [Parameter ( Mandatory = $True, Position = 1, ValueFromPipelineByPropertyName = $True )]
       [String] $DestinationPath,
       [Parameter ( Mandatory = $True, Position = 2, ValueFromPipelineByPropertyName = $True )]
       [PSCustomObject[]] $ReportDeployments
    )

    try {
        
        Write-TimestampOutput -Message "---[Result export started]---"

        New-Item -Path $DestinationPath -ItemType Directory -Force

        Remove-Item -Path "$DestinationPath*" -Recurse -Force

        $Deployment = $ReportDeployments | Where-Object { $_.Name -like "*pod" }

        Write-TimestampOutput -Message "Checking for file existence $($Deployment.Path): $(Test-Path $Deployment.Path -PathType Leaf)"

        Add-KubectlDeployment -Name $Deployment.Name -Filepath $Deployment.Path

        Wait-PodCondition -Condition "Ready" -PodName $Deployment.Name -Timeout 30

        Copy-PodToLocal -PodName $Deployment.Name -SourcePath $SourcePath -DestinationPath $DestinationPath

        if( (Get-ChildItem $DestinationPath | Measure-Object).Count -eq 0 ) {

            throw "Empty results."
        }

        Write-TimestampOutput -Message "---[Result export done]--- success`r`n"
    }
    catch {

        Write-TimestampOutput -Message "---[Result export done]--- failure`r`n"
        Write-Error $_
    }
}