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
    Main entry point for Kubernetes UI Tests

    .DESCRIPTION
    Create a cluster or use an existing one to run ui tests, then dispose all resources.

    .NOTES
    Can be run locally with Kubernetes installed or against Azure Kubernetes Service (AKS)

    .PARAMETER Mode
    Specifies the mode for the script. Default value: All

    .PARAMETER Environment
    Specifies the configuration file to use. Default value: DEBUG

    .INPUTS
    None. You cannot pipe objects to Invoke-K8sTests.

    .EXAMPLE
    PS> .\Invoke-K8sTests.ps1 -Mode "All" -Environment "DEBUG"
    PS> .\Invoke-K8sTests.ps1 -Mode "Create" -Environment "TEST"
    PS> .\Invoke-K8sTests.ps1 -Mode "Run" -Environment "TEST"
    PS> .\Invoke-K8sTests.ps1 -Mode "Dispose" -Environment "TEST"
#>

[CmdletBinding()]
Param (
    [Parameter ( Mandatory = $False, Position = 0, ValueFromPipelineByPropertyName = $True )]
    [String] $Mode = "All",
    [Parameter ( Mandatory = $False, Position = 1, ValueFromPipelineByPropertyName = $True )]
    [String] $Environment = "DEBUG"
)

Begin {

    . ".\controllers\ConfigurationController.ps1"
    . ".\controllers\ClusterController.ps1"
    . ".\controllers\RunController.ps1"
    . ".\services\LoggingService.ps1"
    . ".\services\KubectlService.ps1"

    $DebugPreference = "Continue"

    function Configure {

        Clear-Logs | OUt-Null

        $Configuration = New-Configuration -Path "..\config\config.$Environment.json"

        Foreach ($Property in $Configuration.PSObject.Properties) {
            Write-Debug $Property.Name
            Write-Debug "$( $Property.Value | Out-String ) `r`n"
        }

        $Deployments = Initialize-DeploymentFiles

        if ( $Null -eq  $Deployments -Or $Deployments.Count -eq 0 ) {
            Write-Error "Deployments cannot be null or empty. Please check configuration file." -ErrorAction Stop
        }
    
        $Configuration, $Deployments
    }

    function Create {

        # Cluster
        Add-Cluster -ClusterParameters $Configuration.ClusterParameters

        # Deployment Files
        New-DeploymentFiles -Deployments $Deployments -TemplateParameters $( $Configuration.TemplateParameters )
    }
    
    function Run {

        try {

            # Wait for cluster ready
            Wait-ClusterReady -ClusterParameters $Configuration.ClusterParameters
                
            Initialize-Deployments -ResourcesDeployments $Configuration.ResourcesDeployments -ReportsDeployments $Configuration.ReportsDeployments
            
            # TestRun Deployments
            New-Deployments -Deployments $Deployments

            # Wait For Pods Ready
            Wait-PodsReady -Deployments $Deployments.Name

            # Wait For Pods Completed Or Failed
            Wait-PodsSucceededOrFailed -Deployments $Deployments.Name
            
            # Export Test Results
            Export-TestResults -SourcePath "/data" -DestinationPath "../reports/" -ReportDeployments $Configuration.ReportsDeployments
        }
        catch {

            Write-Error $_ -ErrorAction Stop
        }
    }
    
    function Dispose {
    
        try {

            # Remove Deployment Files
            Remove-DeploymentFiles -Deployments $Deployments

            # Wait for cluster ready
            Wait-ClusterReady -ClusterParameters $Configuration.ClusterParameters
                
            # Clear resources from cluster
            Clear-Deployments

            # Remove Cluster
            Remove-Cluster -ClusterParameters $Configuration.ClusterParameters
        }
        catch {

            Write-Error $_ -ErrorAction Stop
        }
        
    }

    $Configuration, $Deployments = Configure
}

Process {
    
    switch ( $Mode ) {

        "All" {
            Create
            Run
        }

        "Create" {
            Create
        }

        "Run" {
            Create
            Run
        }
    }
}

End {

    switch ( $Mode ) {

        "All" {
            Dispose
        }

        "Dispose" {
            Dispose
        }
    }
}

