<# 
PSScriptInfo 
.VERSION 1.0 
.AUTHOR Clément Joye 
.COMPANYNAME Authority 
.COPYRIGHT (C) 2020 Clément Joye - All Rights Reserved 
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
       [int] $Timeout = 500
    )

    try {

        Write-TimestampOutput -Message "---[Deployment started]---`r`n"

        ForEach ( $Deployment in $Deployments ) {

            Write-TimestampOutput -Message "Checking for file existence $($Deployment.Path): $(Test-Path $Deployment.Path -PathType Leaf)"

            Add-KubectlDeployment -Name $Deployment.Name -Filepath $Deployment.Path
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
       [PSCustomObject[]] $ReportsDeployments
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

    # Clear previous resrouces and reports
    Invoke-PodCommand -PodName "resources-pod" -Command "rm -rf ./cypress/*"
    Invoke-PodCommand -PodName "reports-pod" -Command "rm -rf ./data/*"

    # Copy cypress resources
    Copy-LocalToPod -PodName "resources-pod" -SourcePath "../cypress/" -DestinationPath "/"
    # Copy-LocalToPod -PodName "resources-pod" -SourcePath "../cypress.json" -DestinationPath "/cypress.json"

    # Test folder
    $Folder = (Invoke-PodCommand -PodName "resources-pod" -Command "ls ./")

    if ( $Folder -Notcontains "cypress" ) {

        throw "Copy of resources failed"
    }

    # Test cypress folder
    $Folder = (Invoke-PodCommand -PodName "resources-pod" -Command "ls ./cypress")

    if ( $Folder.Count -eq 0 ) {

        throw "Copy of resources failed"
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
       [string[]] $Deployments,
       [Parameter ( Mandatory = $False, Position = 1, ValueFromPipelineByPropertyName = $True )]
       [int] $Timeout = 300,
       [Parameter ( Mandatory = $False, Position = 2, ValueFromPipelineByPropertyName = $True )]
       [int] $Interval = 5
    )

    Start-Sleep -s 3
    $Count = 0
    $Animation = @( ".", "..", "..." )

    do {

        if ( ($Count % $Interval) -eq 0 ) {

            $PodsRunning = Get-PodsInfo -Status "Running"
            $PodsFailed = Get-PodsInfo -Status "Failed"
        }

        $RunningNumber   = $PodsRunning.Count
        $FailedNumber    = $PodsFailed.Count
        $SucceededNumber = $Deployments.Count - $RunningNumber - $FailedNumber
        
        $RunningPercent   = [math]::Round( $RunningNumber   / $Deployments.Count * 100 )
        $FailedPercent    = [math]::Round( $FailedNumber    / $Deployments.Count * 100 )
        $SucceededPercent = [math]::Round( $SucceededNumber / $Deployments.Count * 100 )

        Write-Progress -Activity 'Running' -Status "$(Get-TimeStamp) Test Pod status: Running: $RunningPercent% - Succeeded: $SucceededPercent% - Failed: $FailedPercent% $($Animation[ ($Count % 4) ])"
        
        Start-Sleep -s 1
        $Count++
        
        if( $PodsRunning.Count -eq 0 -Or $PodsError.Count -ne 0 ) {

            break
        }

    } while ( $PodsRunning.Count -gt 0 -And $PodsError.Count -eq 0 )

    $Pods = @{}
    $PodsCompleted = Get-PodsInfo -Status "Succeeded"
    
    ForEach ( $Item in $PodsRunning   ) { if ($Pods.ContainsKey($Item.PodName) -eq $False) { $Pods.Add( $Item.PodName, "Running"   ) }}
    ForEach ( $Item in $PodsCompleted ) { if ($Pods.ContainsKey($Item.PodName) -eq $False) { $Pods.Add( $Item.PodName, "Succeeded" ) }}
    ForEach ( $Item in $PodsError     ) { if ($Pods.ContainsKey($Item.PodName) -eq $False) { $Pods.Add( $Item.PodName, "Failed"    ) }}

    Write-Progress -Activity "Running" -Completed

    Write-TimestampOutput -Message "$Pods `r`n"
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

        if( (Get-ChildItem $Path | Measure-Object).Count -eq 0 ) {

            throw "Empty results."
        }

        Write-TimestampOutput -Message "---[Result export done]--- success`r`n"
    }
    catch {

        Write-TimestampOutput -Message "---[Result export done]--- failure`r`n"
        Write-Error $_
    }
}