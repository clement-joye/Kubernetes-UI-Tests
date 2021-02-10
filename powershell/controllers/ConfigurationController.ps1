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
    Configuration controller used to initialize the configuration, create the deployment files, dispose the deployment files. 
#>

. ".\services\LoggingService.ps1"

 function New-Configuration {

    param(
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [String] $Path
    )

    try { 

        Write-TimestampOutput -Message "---[Configuration started]---"

        $FileContent = Get-Content -Raw -Path $Path
        $Configuration = $FileContent | ConvertFrom-Json 

        Write-TimestampOutput -Message "---[Configuration done]--- success`r`n"
    }
    catch {

        Write-TimestampOutput -Message "---[Configuration done]--- failure`r`n"
        Write-Error $_ -ErrorAction Stop
    }
    
    $Configuration
}

function Add-DeploymentFiles {

    param(
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [PSCustomObject[]] $Deployments,
        [Parameter ( Mandatory = $True, Position = 1, ValueFromPipelineByPropertyName = $True )]
        [string] $YamlTemplate,
        [Parameter ( Mandatory = $True, Position = 2, ValueFromPipelineByPropertyName = $True )]
        [PSCustomObject] $TemplateParameters
    )

    ForEach ( $Deployment in $Deployments ) {
        
        $Template = $YamlTemplate
        $PodName = $Deployment.Name

        if( [string]::IsNullOrEmpty( $PodName ) -eq $True ) {

            throw "Deployment name is missing."
        }

        ForEach ( $Parameter in $TemplateParameters.PsObject.Properties ) {

            if ( $Parameter.Value -match '\$(\w+)' ) {

                $Value = $Parameter.Value -replace '\$(\w+)', (Get-Variable -Name $Matches[1] -ValueOnly -Scope 0)
            }

            else {

                $Value = $Parameter.Value
            }

            $Template = $Template -replace "{$( $Parameter.Name )}", $Value
        }

        Write-TimestampOutput "Creating $($Deployment.Path) with value:`r`n$Template"
        #Write-TimestampOutput "Creating $($Deployment.Path)"
        
        New-Item -Path $Deployment.Path -ItemType "file" -Value $Template -Force
    }
}

function Initialize-DeploymentFiles {

    param(
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [PSCustomObject] $FileParameters
    )

    try { 

        Write-TimestampOutput -Message "---[Prepare Deployment Files started]---"

        # Test files
        $Filenames = Get-ChildItem "..\cypress\integration" -Filter $FileParameters.Include -Exclude $FileParameters.Exclude -Recurse

        if( $Filenames.Count -eq 0 ) {

            throw "No test files found in ..\cypress\integration. Please check your configuration."
        }

        Write-TimestampOutput -Message "Identified $($Filenames.Count) test files."

        # Deployment Files
        $Deployments = @()

        ForEach ( $Filename in $Filenames ) {

            $PodName = $Filename.Name.Replace(".spec.js", "")
            $YamlFilepath = "..\deployments\$PodName.yaml"
            
            $Deployments+= ( [PSCustomObject] @{ Name = $PodName; Path = $YamlFilepath; Deployed = $False } )
            Write-TimestampOutput -Message "$PodName / $YamlFilepath"
        }
        
        Write-TimestampOutput -Message "---[Prepare Deployment Files done]--- success`r`n"
    }
    catch {

        Write-TimestampOutput -Message "---[Prepare Deployment Files done]--- failure`r`n"
        Write-Error $_ -ErrorAction Stop
    }

    $Deployments
}

function New-DeploymentFiles {

    param(
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [PSCustomObject[]] $Deployments,
        [Parameter ( Mandatory = $True, Position = 1, ValueFromPipelineByPropertyName = $True )]
        [PSCustomObject] $TemplateParameters
    )

    try { 

        Write-TimestampOutput -Message "---[New Deployments Files started]---"

        # Yaml Template
        $YamlTemplate = Get-Content "..\k8s\cypress-testrun-pod.yaml" -Raw

        if( $Null -eq $YamlTemplate ) {

            throw "Yaml template is null. Please check your configuration."
        }

        Write-TimestampOutput -Message "YamlTemplate: $YamlTemplate"

        # Deployment Files
        Add-DeploymentFiles -Deployments $Deployments -YamlTemplate $YamlTemplate -TemplateParameters $TemplateParameters | Out-Null
        
        Write-TimestampOutput -Message "---[New Deployment Files done]--- success`r`n"
    }
    catch {

        Write-TimestampOutput -Message "---[New Deployment Files done]--- failure`r`n"
        Write-Error $_
    }

    $Deployments
}

function Remove-DeploymentFiles {

    param(
       [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
       [PSCustomObject[]] $Deployments
    )

    try {

        Write-TimestampOutput -Message "---[Started] Removing Deployment Files."

        if ( (Test-Path "..\deployments\") -eq $True ) {

            Remove-Item –Path "..\deployments\"  –Recurse -Force
        }
        
        Write-TimestampOutput -Message "---[Done] Removing Deployment Files."
    }
    catch {

        Write-Error $_
    }
}