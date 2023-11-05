# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# RunAKSPerformanceTest.ps1 is used to run AKS performance test scenarios, which includes Cluster Creation, Nodepool Provision, Pod Deployment, Nodepool Scale-out (scale-in), Cluster Deletion
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Region = "eastus",

    [Parameter(Mandatory = $false)]
    [string]$ClusterName = 'perfTestCluster',

    [Parameter(Mandatory = $false)]
    [string]$K8sVersion,

    [Parameter(Mandatory = $false)]
    [ValidateSet("azure", "kubenet")]
    [string]$NetworkPlugin = "azure",

    [Parameter(Mandatory = $false)]
    [bool]$UseOverlayNetwork = $true,

    [Parameter(Mandatory = $false)]
    [string]$SystempoolVMSku = "Standard_D8ds_v5",

    [Parameter(Mandatory = $false)]
    [string]$SystempoolNodeCount = 3,

    [Parameter(Mandatory = $false)]
    [ValidateSet("free", "premium", "standard")]
    [string]$SkuTier = "standard",

    [Parameter(Mandatory = $false)]
    [string]$UserpoolVMSku = "Standard_D8ds_v5",

    [Parameter(Mandatory = $false)]
    [string]$UserpoolInitialNodeCount = 3,

    [Parameter(Mandatory = $false)]
    [string]$UserpoolScaleTargetNodeCount = 53,

    [Parameter(Mandatory = $false)]
    [int]$MonitorPollIntervalSeconds = 5,

    [Parameter(Mandatory = $false)]
    [boolean]$SilentMode = $false
)
# Empty object for final output
$output = @{}

# Initialize Logger
Import-Module -Name $(Join-Path "$PSScriptRoot" "AKSPerfTestScenarios.psm1") -Force
$Logger = New-Logger -SilentMode $SilentMode

# 0. Login with prompt
$Logger.LogMessage("Login to Az Account - Start")
$Logger.LogDebugMessage("Prompt Az Login to proceed")
$response = az login
$response = az account set -s $SubscriptionId
$Logger.LogDebugMessage("Successfully login to Az account")
$Logger.LogMessage("Login to Az Account - End")

# 1. Check existence of resource group and create the new group
$Logger.LogMessage("Create new resource group - Start")
$Logger.LogDebugMessage("Check if resource group '$ResourceGroupName' already exist")
$resourceGroupExist = az group exists -n $ResourceGroupName
if ($resourceGroupExist -eq 'true') {
    $Logger.LogDebugMessage("Resource group '$ResourceGroupName' already exists")
} else {
    $Logger.LogDebugMessage("Create new resource group")
    $response = az group create --name $ResourceGroupName --location $Region
    $Logger.LogDebugMessage("Successfully created resource group '$ResourceGroupName'")
}
$Logger.LogMessage("Create new resource group - End")

# 2. Cluster creation
# Name the cluster based on the resource group name
$clusterCreationScenario = New-ClusterCreationScenario -ClusterName $ClusterName `
                                                        -ResourceGroupName $ResourceGroupName `
                                                        -K8sVersion $K8sVersion `
                                                        -NetworkPlugin $NetworkPlugin `
                                                        -UseOverlayNetwork $UseOverlayNetwork `
                                                        -SystempoolVMSku $SystempoolVMSku `
                                                        -SystempoolNodeCount $SystempoolNodeCount `
                                                        -SkuTier $SkuTier `
                                                        -Logger $Logger
$scenarioMetric = $clusterCreationScenario.RunScenario()
$output[$scenarioMetric.ScenarioName] = "$($scenarioMetric.TotalElapsedTime.TotalSeconds) seconds"


# connect to the aks cluster
$Logger.LogMessage("Connect to AKS cluster - Start")
$Logger.LogDebugMessage("Get access credentials for AKS cluster")
az aks get-credentials --resource-group $ResourceGroupName --name $ClusterName --overwrite-existing 
$Logger.LogDebugMessage("Successfully updated .kube/config file with the access credentials")
$Logger.LogMessage("Connect to AKS cluster - End")

# 3. Nodepool (userpool) provision
$userpoolName = 'userpool'
$nodepoolProvisionScenario = New-NodepoolProvisionScenario -ClusterName $ClusterName `
                                                            -ResourceGroupName $ResourceGroupName `
                                                            -NodepoolName $userpoolName `
                                                            -UserpoolVMSku $UserpoolVMSku `
                                                            -UserpoolNodeCount $UserpoolInitialNodeCount `
                                                            -Logger $Logger
$scenarioMetric = $nodepoolProvisionScenario.RunScenario()
$output[$scenarioMetric.ScenarioName] = "$($scenarioMetric.TotalElapsedTime.TotalSeconds) seconds"

# # 4. Deploy a pod and monitor scheduling time
$deploymentFilePath = $(Join-Path $PSScriptRoot "pod-deployment.yaml")
$replicaCount = 1
$podDeploymentScenario = New-PodDeploymentScenario -DeploymentFilePath $deploymentFilePath `
                                                    -ReplicaCount $replicaCount `
                                                    -Logger $Logger
$scenarioMetric = $podDeploymentScenario.RunScenario()
$output[$scenarioMetric.ScenarioName] = "$($scenarioMetric.TotalElapsedTime.TotalSeconds) seconds"

# 5. Scale-out additional 50 nodes (target node count 53)
$nodepoolScaleOutScenario = New-NodepoolScaleScenario -ScenarioName "Nodepool Scale-out to $UserpoolScaleTargetNodeCount Nodes" `
                                                        -ClusterName $ClusterName `
                                                        -ResourceGroupName $ResourceGroupName `
                                                        -NodepoolName $userpoolName `
                                                        -TargetNodeCount $UserpoolScaleTargetNodeCount `
                                                        -MonitorPollIntervalSeconds $MonitorPollIntervalSeconds `
                                                        -Logger $Logger
$scenarioMetric = $nodepoolScaleOutScenario.RunScenario()
$output[$scenarioMetric.ScenarioName] = "$($scenarioMetric.TotalElapsedTime.TotalSeconds) seconds"

$Logger.LogMessage("Sleep for 2 minutes before Scale-In test")
Start-Sleep -Seconds 120

# 6. Scale-in to initial node count (target node count 3)
$nodepoolScaleInScenario = New-NodepoolScaleScenario -ScenarioName "Nodepool Scale-in to $UserpoolInitialNodeCount Nodes" `
                                                        -ClusterName $ClusterName `
                                                        -ResourceGroupName $ResourceGroupName `
                                                        -NodepoolName $userpoolName `
                                                        -TargetNodeCount $UserpoolInitialNodeCount `
                                                        -MonitorPollIntervalSeconds $MonitorPollIntervalSeconds `
                                                        -Logger $Logger
$scenarioMetric = $nodepoolScaleInScenario.RunScenario()
$output[$scenarioMetric.ScenarioName] = "$($scenarioMetric.TotalElapsedTime.TotalSeconds) seconds"

# 7. Delete AKS cluster
$clusterDeletionScenario = New-ClusterDeletionScenario -ClusterName $ClusterName `
                                                        -ResourceGroupName $ResourceGroupName `
                                                        -Logger $Logger
$scenarioMetric = $clusterDeletionScenario.RunScenario()
$output[$scenarioMetric.ScenarioName] = "$($scenarioMetric.TotalElapsedTime.TotalSeconds) seconds"

# 8. Delete Resource group
$Logger.LogMessage("Delete resource group - Start")
$Logger.LogDebugMessage("Delete the resource group '$ResourceGroupName'")
az group delete -n $ResourceGroupName --yes
$Logger.LogMessage("Delete resource group - End")

# 9. Write to output file
$filePath = "output.json"
$outputArray = @()
# If output file already exists, read the content as Json object
if (Test-Path $filePath -PathType Leaf) {
    $outputContent = Get-Content -Raw -Path $filePath | ConvertFrom-Json
    $outputArray = @($outputContent)
}
# Add the current output to the array
$outputArray += $output
# Write output to the logs
$outputJson = ConvertTo-Json $output 
$Logger.LogDebugMessage($outputJson)
# Write the combined output to the output file
ConvertTo-Json $outputArray | Set-Content -Path $filePath

$Logger.LogMessage("Completed the AKS Performance Test")