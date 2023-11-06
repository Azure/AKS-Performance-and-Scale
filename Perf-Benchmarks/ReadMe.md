# About this project:

This repoository's goal is to help AKS users understand Performance and Scalability best practices for AKS and Kubernetes and also help them benchmark certain scaling performance SLOs. 

Below document provides the steps to run a pre-created script that provisions an AKS cluster, scales up the nodepool to 50 Nodes and measures the time time taken to scale up, allowing customers to use it as a reproducable benchmark for node scaling on AKS.

## Prerequisites
### Az Account
The first step of the script is to login to Az. An Az Account is required to run this script. 
### Subscription
Subscription ID is required for the test. The script requires that the user have enough permission to deploy new resources within the subscription. 
<div style="padding: 10px; border: 2px solid #df4577;">
   <p style="font-weight:bold; font-size: 16px">⚠️ Please make sure that there is enough quota for the cores required to run the script in the subscription. ⚠️</p>
   <ul>
      <li> By default, systempool uses `Standard_D8ds_v5` with 3 nodes and userpool users `Standard_D8ds_v5` and scale-out to 53 nodes. Which means, there needs to be at least 448 cores available for the SKU type Ddsv5 in the subscription & region
      <li> If there are enough cores for other SKU types, the SKU can be changed through the script parameters. Please see below for more information about the parameters</li>
   </ul>
</div>

### Tools
Throughout the test, it is required to have the following tools:
- az cli - [[how to install]](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-windows?tabs=azure-cli)
- kubectl - [[how to install]](https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/)

## How to Run Test
1. Clone the repository to a local folder location
   ```
   git clone <repository name> . 
   ```
2. Open Powershell and Navigate to the folder where the repo was cloned
3. Run the following command with parameter values
   ```
   PS > .\RunAKSPerformanceTest.ps1 -SubscriptionId <Subscription Id> -ResourceGroupName <Resourcegroup Name>
   ```
4. Once the test is completed, output.json file will be produced in the same folder location. And the file will include the summary of the test results:
   ```json
   {
        "AKS Nodepool Provision": "167.3903461 seconds",
        "Nodepool Scale-in to 3 Nodes": "135.761791 seconds",
        "Nodepool Scale-out to 53 Nodes": "118.312894 seconds",
        "AKS Cluster Creation": "709.2348797 seconds",
        "1 Pod(s) Deployment": "4.6561146 seconds",
        "AKS Cluster Deletion": "283.2609832 seconds"
   }
   ```

### Parameters
Following parameters can be used to configure the AKS performance test

| Parameter Name | Required | Description | Default |
|:---------------|:---------|:------------|:-------:|
| SubscriptionId | Required | ID of an Azure subscription which will be used for resource deployment throughout the test. (Note: All the resources will be deleted after the test) ||
| ResourceGroupName | Required | Name of new Azure resource group which will be used for resource deployment throughout the test. New resource group will be created by this value ||
| Region | Optional | Name of a valid Azure region (e.g. eastus, westus3). New resource group will be created under the selected region | eastus |
| ClusterName | Optional | Name of the new AKS cluster | perfTestCluster |
| K8sVersion | Optional | Kubernetes version of the new AKS cluster. If not passed, the latest version available in the selected region will be used | |
| NetworkPlugin | Optional | Network plugin value which will be used in AKS cluster creation. Valid values are 'azure' or 'kubenet' | azure |
| UseOverlayNetwork | Optional | Only applicable when NetworkPlugin is 'azure'. true = Use Overlay Network | true |
| SystempoolVMSku | Optional | VM SKU of the systempool | Standard_D8ds_v5 |
| SystempoolNodeCount | Optional | Initial systempool node count | 3 |
| SkuTier | Optional | Pricing tier of cluster management. Valid values are 'free', 'premium', or 'standard' | standard |
| UserpoolVMSku | Optional | VM SKU of the userpool. During the performance test, one userpool (nodepool with 'User' mode) will be added to the cluster and will be used for performance test | Standard_D8ds_v5 |
| UserpoolInitialNodeCount | Optional | Initial userpool node count | 3 |
| UserpoolScaleTargetNodeCount | Optional | Target node count which will be used in scale-out performance test. Default is 53, 50 additional node to the initial count | 53 |
| MonitorPollIntervalSeconds | Optional | During the scale-out performance test, it checks the current number of the nodes every `MonitorPollIntervalSeconds` seconds until it reaches the target node count | 5 |
| SilentMode | Optional | If there is no need to see detail logging message, set this to true | false |

## Visualization
The data from `output.json` can be visualized by running the `visual.py` script in a Jupyter / JupyterLab notebook. Each completed benchmarking test, by default, will append the new run data to the same `output.json` file in the format of an array of json objects. Running `visual.py` in a Jupyter notebook will generate summary statistics and scatterplots for all the results.

