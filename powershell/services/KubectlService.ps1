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
    Utility functions for kubectl: test connection, get pods info, set context, wait for condition, copy data, invoke pod command, add deployment, remove deployment, clear deployments.
#>

. ".\services\LoggingService.ps1"

function Test-KubectlConnection {

    param(
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [String] $Name
    )

    return ( (kubectl cluster-info dump | Out-String) -ne "" )
}

function Get-PodsInfo {

    param(
        [Parameter ( Mandatory = $False, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [String] $Status = $Null,
        [Parameter ( Mandatory = $False, Position = 1, ValueFromPipelineByPropertyName = $True )]
        [String] $Level = "minimal",
        [Parameter ( Mandatory = $False, Position = 2, ValueFromPipelineByPropertyName = $True )]
        [String] $Namespace = "default"
    )

    try {

        if($Status -eq $Null) {

            $Podslist = ( kubectl get pods --namespace $namespace -o json ) | convertfrom-Json
        }

        else {

            $Podslist = ( kubectl get pods --namespace $namespace --field-selector=status.phase=$Status -o json ) | convertfrom-Json
        }

        $PodsArrayList = [System.Collections.ArrayList]::new()
        
        switch ( $Level )
        {
            "minimal" { 
                
                Foreach ( $Pod in $Podslist.Items ) {
                    [void] $PodsArrayList.Add( [PSCustomObject] @{ 
                        PodName =   $Pod.metadata.name
                        Status  =   $Pod.status.phase
                    })
                }
            }

            "expanded" {
                
                Foreach ( $Pod in $Podslist.Items ) {
                    [void] $PodsArrayList.Add( [PSCustomObject] @{ 
                        PodName      =   $Pod.metadata.name
                        Status       =   $Pod.status.phase
                        restartCount =   $Pod.status.containerStatuses[0].restartCount
                        StartTime    =   $Pod.status.startTime
                        image        =   $Pod.status.containerStatuses[0].image
                        Node         =   $Pod.spec.nodeName 
                        NodeType     =   $Pod.spec.nodeSelector
                    })
                }
            }
        }

        $PodsArrayList
    }
    catch {
        "An error occurred that could not be resolved."
    }
}

function Set-KubectlContext {

    param(
        
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [String] $Name
    )

    Write-TimestampOutput -Message "[Started] Switching context."
    kubectl config use-context $Name
    Write-TimestampOutput -Message "[Done] Switching context."

    if( (Test-KubectlConnection -Name $Name) -eq $False ) {

        throw "Connection is down or cluster does not exist."
    }
}

function Wait-PodCondition {

    param(
        
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [String] $Condition,
        [Parameter ( Mandatory = $True, Position = 1, ValueFromPipelineByPropertyName = $True )]
        [String] $PodName,
        [Parameter ( Mandatory = $False, Position = 2, ValueFromPipelineByPropertyName = $True )]
        [String] $Namespace = "default",
        [Parameter ( Mandatory = $False, Position = 3, ValueFromPipelineByPropertyName = $True )]
        [int] $Timeout = 180
    )

    $output = kubectl wait --for=condition=$Condition pod $PodName --namespace $Namespace --timeout=$( $Timeout )s 
    
    return ($output -eq "pod/$PodName condition met")
}

function Wait-MultiplePodConditions {

    param(
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [String] $Condition,
        [Parameter ( Mandatory = $True, Position = 1, ValueFromPipelineByPropertyName = $True )]
        [String[]] $PodNames,
        [Parameter ( Mandatory = $False, Position = 2, ValueFromPipelineByPropertyName = $True )]
        [String] $Namespace = "default",
        [Parameter ( Mandatory = $False, Position = 3, ValueFromPipelineByPropertyName = $True )]
        [int] $Timeout = 180
    )

    $Jobs = @{}
    
    ForEach ($PodName in $PodNames) { 
        
        $WaitScriptBlock = {

            Param( $Condition, $PodName, $Namespace, $Timeout )

            Begin {
                . ".\services\KubectlService.ps1"
            }

            Process {
                Wait-PodCondition -Condition $Condition -PodName $PodName -Namespace $Namespace -Timeout $Timeout
            }
        }
        
        $Job = Start-Job -Name "Wait_$PodName" -ArgumentList $Condition, $PodName, $Namespace, $Timeout -ScriptBlock $WaitScriptBlock

        $Jobs.Add( $PodName, $Job )
    }
    
    Get-Job | Wait-Job | Out-Null

    ForEach ( $Key in $Jobs.Keys ) {
        
        $Ready = Receive-Job $Jobs[$Key]
        
        if( $Ready -ne $True ) {

            throw "Wait condition timed out."
        }
    }
}

function Copy-PodToLocal {
    
    param(
        
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [String] $PodName,
        [Parameter ( Mandatory = $True, Position = 1, ValueFromPipelineByPropertyName = $True )]
        [String] $SourcePath,
        [Parameter ( Mandatory = $True, Position = 2, ValueFromPipelineByPropertyName = $True )]
        [String] $DestinationPath
    )
    
    Start-Sleep -Seconds 3

    ( kubectl cp "${PodName}:$SourcePath" "$DestinationPath" )
}

function Copy-LocalToPod {
    
    param(
        
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [String] $PodName,
        [Parameter ( Mandatory = $True, Position = 1, ValueFromPipelineByPropertyName = $True )]
        [String] $SourcePath,
        [Parameter ( Mandatory = $True, Position = 2, ValueFromPipelineByPropertyName = $True )]
        [String] $DestinationPath
    )

    ( kubectl cp "$SourcePath" "${PodName}:$DestinationPath" )
}

function Invoke-PodCommand {

    param(
        
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [String] $PodName,
        [Parameter ( Mandatory = $True, Position = 1, ValueFromPipelineByPropertyName = $True )]
        [String] $Command
    )
    
    ( kubectl exec $PodName -- sh -c $Command )
}

function Get-PodLogs {

    param(
        
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [String] $PodName
    )
    
    ( ( kubectl logs $PodName ) -replace '\n','\r\n' )
}

function Add-ConfigMap {

    param(
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [String] $Name,
        [Parameter ( Mandatory = $True, Position = 1, ValueFromPipelineByPropertyName = $True )]
        [String] $SourcePath
    )

    Write-TimestampOutput -Message "[Started] Creating configmap for $Name at $SourcePath."

    kubectl create configmap $Name --from-file $SourcePath

    Write-TimestampOutput -Message "[Done] Creating configmap for $Name at $SourcePath."
    
}

function Add-KubectlDeployment {

    param(
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [String] $Name,
        [Parameter ( Mandatory = $True, Position = 1, ValueFromPipelineByPropertyName = $True )]
        [String] $Filepath
    )

    Write-TimestampOutput -Message "[Started] Creating deployment for $Name at $Filepath."

    kubectl create -f $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Filepath)

    Write-TimestampOutput -Message "[Done] Creating deployment for $Name at $Filepath."
}

function Remove-KubectlDeployment {
    
    param(
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [String] $Kind,
        [Parameter ( Mandatory = $True, Position = 1, ValueFromPipelineByPropertyName = $True )]
        [String] $Name,
        [Parameter ( Mandatory = $False, Position = 2, ValueFromPipelineByPropertyName = $True )]
        [int] $Timeout = 15
    )

    Write-TimestampOutput -Message "[Started] Removing $Kind $Name"

    kubectl delete $Kind $Name --now --timeout "$($Timeout)s"

    Write-TimestampOutput -Message "[Done] Removing $Kind $Name"
}

function Clear-KubectlDeployments {
    
    param(
        [Parameter ( Mandatory = $True, Position = 0, ValueFromPipelineByPropertyName = $True )]
        [String] $Kind,
        [Parameter ( Mandatory = $False, Position = 1, ValueFromPipelineByPropertyName = $True )]
        [int] $Timeout = 15
    )

    Write-TimestampOutput -Message "[Started] Removing all existing $Kind(s)"

    kubectl delete $Kind --all --now --timeout "$($Timeout)s"
    
    Write-TimestampOutput -Message "[Done] Removing all existing $Kind(s)"
}

