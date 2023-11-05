# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# AKSPerfTestScenarios.psm1
#  Powershell module which includes all the classes and functions to perform AKS performance test scenarios
using namespace System.Management.Automation;

# KubectlEvent
# - Class which holds event values returned from kubectl get pods --watch --output-watch-events 
class KubectlEvent {
    [string]static $Deleted = 'DELETED'

    [ValidateNotNullOrEmpty()][string]$Event #Event Type
    [ValidateNotNullOrEmpty()][string]$Name #Pod Name
    [ValidateNotNullOrEmpty()][string]$Status #Pod Status
    [ValidateNotNullOrEmpty()][double]$ElapsedTimeInMins #Time Duration

    KubectlEvent([string]$kubeEvent, [string]$name, [string]$status, [double]$timeDiff) {
        $this.Event = $kubeEvent
        $this.Name = $name
        $this.Status = $status
        $this.ElapsedTimeInMins = $timeDiff
    }


    KubectlEvent([string]$kubeEvent, [Pod]$pod, [double]$timeDiff) {
        $this.Event = $kubeEvent
        $this.Name = $pod.Name
        $this.Status = $pod.Status
        $this.ElapsedTimeInMins = $timeDiff
    }

    # Returns true if Event is 'DELETED'
    [boolean] IsDeleteEvent() {
        return $this.Event -eq [KubectlEvent]::Deleted
    }

}

# Pod
# - class which holds Pod data returned from kubectl get pods
# - it stores Name and Status of pods
class Pod {
    [ValidateNotNullOrEmpty()][string]$Name
    [ValidateNotNullOrEmpty()][string]$Status

    # Constructor which initializes Pod object by parsing the values returned from 'kubectl get pods'
    Pod([string[]]$splitLine) {
        # account for case where pod restarts, where the count can be 7
        if ($splitLine.Count -lt 5) {
            throw "The parsed pod contained $($splitLine.Count) items but we expected at least 5: $splitLine"
        }
        # Sample data:
        # NAME       READY   STATUS    RESTARTS   AGE   IP             NODE        NOMINATED NODE   READINESS GATES
        # podname1   1/1     Running   0          21d   10.240.0.214   nodename1   <none>           <none>
        $this.Name = $splitLine[0]
        $this.Status = $splitLine[2]
    }
}

# KubeStatuses
# - class to keep in tracking of the KubeEvents
class KubeStatuses {
    [ValidateNotNull()][hashtable]$Resources
    [ValidateNotNull()][hashtable]$StatusCounts

    KubeStatuses([hashtable]$resources) {
        $this.Resources = $resources
        $this.StatusCounts = @{}
        $this.Resources.GetEnumerator() |
        ForEach-Object {
            ++$this.StatusCounts[$_.Value]
        }
    }

    # Update the status table with the latest event
    # Returns true if previous pod status is different from the current status
    [boolean] Update([KubectlEvent]$kubeEvent) {
        # returns [string]::empty if not in hashtable
        [string]$prevStatus = $this.Resources[$kubeEvent.Name]
        if ($kubeEvent.IsDeleteEvent()) {
            $this.Resources.Remove($kubeEvent.Name)
            $this.UpdateStatusCount($prevStatus, [string]::empty)
            return $null -ne $prevStatus
        }
        else {
            $this.Resources[$kubeEvent.Name] = $kubeEvent.Status
            $this.UpdateStatusCount($prevStatus, $kubeEvent.Status)
            return $prevStatus -ne $kubeEvent.Status
        }
    }

    # Update the status count based on the previous and current statuses
    # This is to keep in tracking of how many pods in each statuses
    # e.g. After a while, we might get the following list of pod status with counts
    # 1 ContainerCreating 
    # 1 Pending
    # 3 Running
    [void] UpdateStatusCount([string]$prevStatus, [string]$newStatus) {
        # If previous status and current status are the same, do nothing
        if ($prevStatus -eq $newStatus) {
            return
        }
        # If previous and current are different, reduce the number of previous status by 1 and increase the new status count by 1
        if (-not [string]::IsNullOrWhiteSpace($prevStatus)) {
            --$this.StatusCounts[$prevStatus]
            if ($this.StatusCounts[$prevStatus] -lt 0) {
                throw "The status count for `$prevStatus=$prevStatus became negative."
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($newStatus)) {
            ++$this.StatusCounts[$newStatus]
        }
    }

    # Returns total count = total number of pods
    [int] GetTotalCount() {
        return $this.Resources.Count
    }

    # Returns the number of pods with $status
    [int] GetStatusCount([string]$status) {
        return $this.StatusCounts[$status]
    }

    [System.Collections.IEnumerator] GetEnumerator() {
        return $this.Resources.GetEnumerator()
    }
}

# EventMetric
# - class to hold Pods metrics with time range
# - Pod metrics are: 
#      PodRunningCount - number of pods in 'Running' state
#      PodTotalCount - number of all pods
# - e.g. 
# MetricName: PodRunningCount MetricValue: 0 StartTime: 01/01/2023 09:40:58 EndTime: 01/01/2023 09:40:58
# MetricName: PodTotalCount MetricValue: 0 StartTime: 01/01/2023 09:40:58 EndTime: 01/01/2023 09:40:58
class EventMetric {

    [datetime]$StartDateTime
    [datetime]$EndDateTime
    [string]$MetricName
    [double]$MetricValue

    EventMetric([datetime]$startDateTime, [datetime]$endDateTime, [string]$metricName, [double]$metricValue) {
        $this.StartDateTime = $startDateTime
        $this.EndDateTime = $endDateTime
        $this.MetricName = $metricName
        $this.MetricValue = $metricValue
    }

    [string] ToString() {
        return "MetricName: $($this.MetricName) MetricValue: $($this.MetricValue) StartTime: $($this.StartDateTime) EndTime: $($this.EndDateTime)"
    }
}

# PodDeploymentTest
# - class which performs Pod deployment test
class PodDeploymentTest {
    [string]static $PendingState = 'Pending'
    [string]static $RunningState = 'Running'


    [ValidateNotNullOrEmpty()][int]$ReplicaCount
    [ValidateNotNull()][KubeStatuses]$PodStatuses
    [System.Management.Automation.Job]$PodsJob

    # Consturctor 
    # - Initialize with how many replica of pods are deployed
    PodDeploymentTest([int]$replicaCount) {
        $this.ReplicaCount = $replicaCount
        $pods = [PodDeploymentTest]::CreatePodsFromCurrentState()
        $this.PodStatuses = [KubeStatuses]::new($pods)
    }

    # Get all current pods with statuses
    [hashtable]static CreatePodsFromCurrentState() {
        $pods = @{}
        kubectl get pods --no-headers --ignore-not-found |
        ForEach-Object {
            $pod = [Pod]::new($this.Split($_))
            $pods[$pod.Name] = $pod.Status
        }
        return $pods
    }

    # From the PodStatuses table, get the current status, i.e. number of running pods and total number of pods
    # returns array of Pod statuses in EventMetrics
    [psobject[]] PodStats([datetime]$startTime, [datetime]$endTime, [double]$elapsedTimeInMins) {
        # timestamp can be small negative number if change happens right after kubectl apply
        $elapsedTimeInMins = [System.Math]::Max($elapsedTimeInMins, 0.0)
        $runningCount = $this.PodStatuses.GetStatusCount([PodDeploymentTest]::RunningState)
        $podCount = $this.PodStatuses.GetTotalCount()

        return @(
            [EventMetric]::new($startTime, $endTime, "PodRunningCount", $runningCount),
            [EventMetric]::new($startTime, $endTime, "PodTotalCount", $podCount)
        )
    }

    # Get current PodStatuses
    [psobject[]] GetStats([datetime]$startTime, [datetime]$endTime, [double]$elapsedTimeInMins) {
        $stats = @()
        $stats += $this.PodStats($startTime, $endTime, $elapsedTimeInMins)
        return $stats
    }

    # From the pod event ($eventObj), check if the pod event type is 'ERROR' and returns true if it is Error type.
    [bool] IsError($eventObj) {
        $eventName, $_ = $this.Split($eventObj.Line)
        return $eventName -eq 'ERROR' -or $eventObj.Type -ne 'String'
    }

    # This method is to start pod event monitoring job (kubectl get pods --watch --output-watch-events) as a background job
    [void] StartJobs() {
        if ($null -ne $this.PodsJob) {
            throw 'Called start without stopping job.'
        }
        # Prepare script block for monitoring job
        $block = {
            kubectl get pods --watch --output-watch-events --no-headers 2>&1 |
            ForEach-Object {
                $timestamp = Get-Date
                Write-Output @{
                    Line      = $_
                    Timestamp = $timestamp
                    Type      = $_.GetType().Name
                }
            }
        }
        # Start new job 
        $this.PodsJob = Start-Job -Name 'PodsJob' -ScriptBlock $block
    }

    # This method is to poll events from the background pod event monitoring job
    # returns an array of events returned from the polling (not including previously polled events)
    [psobject[]] ProcessNewEvents([datetime]$startTime) {
        $output = @()
        # Receive the pod events from the job
        Receive-Job $this.PodsJob |
        ForEach-Object { # Loop through each event returned from the job
            # Check if the event is ERROR type
            if (-not $this.IsError($_)) {
                #if not, parse the event and update the pods statuses table
                $podEvent, $podArgs = $this.Split($_.Line)
                $pod = [Pod]::new($podArgs)
                $timeDiff = $_.Timestamp - $startTime
                $podEvent = [KubectlEvent]::new($podEvent, $pod, $timeDiff.TotalMinutes)
                if ($this.PodStatuses.Update($podEvent)) {
                    $output += $this.PodStats($startTime, $_.Timestamp, $podEvent.ElapsedTimeInMins)
                }
            }
            else {
                # If there's an error event, write error message
                $_.Line | Out-String | Write-Error
            }
        }
        return $output
    }

    # Stop the background pod monitoring job
    [void] StopJobs() {
        $($this.PodsJob)?.StopJob()
    }

    # check the status of the background pod monitoring job and returns ture if it's running
    [boolean] AllJobsRunning() {
        return $null -ne $this.PodsJob -and $this.PodsJob.State -eq 'Running'
    }

    # helper function to splite $line into array of substrings based on whitespace chars
    [string[]] Split([string]$line) {
        return $line -split "\s+"
    }

    # Check if all pods in running state. Throw an exception if the numbers don't match. 
    [void] CheckState() {
        if ($this.PodStatuses.GetStatusCount([PodDeploymentTest]::RunningState) -ne $this.PodStatuses.GetTotalCount()) {
            throw 'Message: State check failed. Found pods not in running state.'
        }
    }

    # Check if all pods in running state
    [bool] IsPodsInRunningState() {
        return $this.PodStatuses.GetStatusCount([PodDeploymentTest]::RunningState) -eq $this.ReplicaCount
    }

    # Get the names of all not-running pods
    [string[]] GetNotRunningPods() {
        $pods = @()
        $this.PodStatuses.GetEnumerator() |
        Where-Object { $_.Value -ne [PodDeploymentTest]::RunningState } |
        Select-Object -First 20 |
        ForEach-Object { $pods += $_.Key }
        return $pods
    }

    # Get the current state of the pods and update PodStatuses table
    [void] ResyncState() {
        $pods = [PodDeploymentTest]::CreatePodsFromCurrentState()
        $this.PodStatuses = [KubeStatuses]::new($pods)
    }

}

# ScenarioMetric
# - class which shows Scenario name and the total duration of the scenario run
# - This metric is used to keep tracking of all AKS scenarios and its run time. 
class ScenarioMetric {

    [timespan]$TotalElapsedTime
    [string]$ScenarioName

    ScenarioMetric([string]$scenarioName, [timespan]$totalElapsedTime) {
        $this.ScenarioName = $scenarioName
        $this.TotalElapsedTime = $totalElapsedTime
    }
}

# Logger
# - class to handle logging in Powershell
# - this is to control whether to show details in each scenario run
# - Powershell DebugPreference wasn't the option, since it will also impact az cli and kubectl calls made throughout the test
class Logger {
    [boolean]$SilentMode
    
    # Set silent mode flag for the Logger
    # If it's set to true, only the message with LogMessage calls will be displayed
    Logger([boolean]$silentMode) {
        $this.SilentMode = $silentMode
    }

    [void] LogMessage([string]$message) {
        Write-Host $message
    }

    [void] LogDebugMessage([string]$message) {
        if (-not $this.SilentMode) {
            Write-Host $message
        }
    }
}

# TestScenario
# - base class for AKS scenarios
# - Each scenario will have Scenario Name and Logger to log messages during the test run
class TestScenario {
    [ValidateNotNullOrEmpty()][string]$ScenarioName
    [ValidateNotNullOrEmpty()][Logger]$Logger
    [timespan]$TestTimeDuration
    
    TestScenario([string]$scenarioName, [Logger]$logger) {
        $this.ScenarioName = $scenarioName
        $this.Logger = $logger
    }

    [void] RunCustomScenarioLogic() {
    }

    [ScenarioMetric] RunScenario() {        
        $this.Logger.LogMessage("$($this.ScenarioName) - Start")
        $this.RunCustomScenarioLogic()        
        $this.Logger.LogMessage("$($this.ScenarioName) - End")
        return [ScenarioMetric]::new($this.ScenarioName, $this.TestTimeDuration)
    }
}

# ClusterCreationScenario
# - class which performs AKS cluster creation 
class ClusterCreationScenario : TestScenario {
    [ValidateNotNullOrEmpty()][string]$ClusterName
    [ValidateNotNullOrEmpty()][string]$ResourceGroupName
    [string]$K8sVersion
    [ValidateNotNullOrEmpty()][string]$NetworkPlugin
    [boolean]$UseOverlayNetwork
    [ValidateNotNullOrEmpty()][string]$SystempoolVMSku
    [int]$SystempoolNodeCount
    [ValidateNotNullOrEmpty()][string]$SkuTier

    ClusterCreationScenario([string]$scenarioName, [string]$clusterName, [string]$resourceGroupName, [string]$k8sVersion, [string]$networkPlugin, [boolean]$useOverlayNetwork, [string]$systempoolVMSku, [int]$systempoolNodeCount, [string]$skuTier, [Logger]$logger)
    : base($scenarioName, $logger) {
        $this.ClusterName = $clusterName
        $this.ResourceGroupName = $resourceGroupName
        $this.K8sVersion = $k8sVersion
        $this.NetworkPlugin = $networkPlugin
        $this.UseOverlayNetwork = $useOverlayNetwork
        $this.SystempoolVMSku = $systempoolVMSku
        $this.SystempoolNodeCount = $systempoolNodeCount
        $this.SkuTier = $skuTier
    }

    [void] RunCustomScenarioLogic() {
        $this.Logger.LogDebugMessage("Prepare cluster creation script")
        $clusterCreateScript = "az aks create --name $($this.ClusterName) --resource-group $($this.ResourceGroupName)"
        # k8s version - if not specified, latest version available in the region will be used. 
        if ($this.K8sVersion) {
            $clusterCreateScript += " --kubernetes-version $($this.K8sVersion)"
        }
        # Network configuration
        $clusterCreateScript += " --network-plugin $($this.NetworkPlugin)"
        if ($this.NetworkPlugin -eq "azure" -and $this.UseOverlayNetwork) {
            $clusterCreateScript += " --network-plugin-mode overlay"
        }
        # Systempool configuration
        $clusterCreateScript += " --nodepool-name systempool --node-vm-size $($this.SystempoolVMSku) --node-count $($this.SystempoolNodeCount)"
        # Sku Tier
        $clusterCreateScript += " --tier $($this.SkuTier)"

        $this.Logger.LogDebugMessage("The script to execute:")
        $this.Logger.LogDebugMessage($clusterCreateScript)

        $script = [ScriptBlock]::Create($clusterCreateScript)

        # Execute Cluster Creation script with retry
        $i = 0
        $times = 2
        $sleepSeconds = 300
        $succeeded = $false
        $lastResponseMessage = ''
        $this.Logger.LogDebugMessage("Execute the script to create new AKS cluster")
        while (($i -lt $times) -and (-not $succeeded)) {
            $i++
            try {
                $this.Logger.LogDebugMessage("Attempt $i (out of $times) ==========================================================")
                # set initial exitcode to 0
                # After the az aks create call, the exitcode will reflect the result of the call, 0 = SUCCESS
                $global:LASTEXITCODE = 0;
                $startTime = $(get-date)
                
                # Execute the prepared az aks create script. It will wait until the cluster is successfully provisioned with initial nodes
                $result = &$script
                
                # Record the time of the cluster creation call
                $elapsedTime = $(get-date) - $startTime
                $this.Logger.LogDebugMessage("Cluster Creation completed - $($elapsedTime.TotalSeconds) seconds")
                $this.TestTimeDuration = $elapsedTime

                $lastResponseMessage = "Last exit code is '$LASTEXITCODE'; result: '$result'"

                # To verify that the cluster is successfully provisioned, get the cluster information and check FQDN is successfully assigned. 
                $this.Logger.LogDebugMessage("Retrieve Cluster info to verify the provisioning state")
                $clusterInfo = (az aks show --resource-group $this.ResourceGroupName --name $this.ClusterName) | ConvertFrom-Json
        
                if (($null -ne $clusterInfo) -and ($clusterInfo.provisioningState -eq "Succeeded")) {
                    $aksFQDN = $clusterInfo.fqdn
                    if ([string]::IsNullOrWhiteSpace($aksFQDN)) {
                        $this.Logger.LogDebugMessage("Aks cluster provisioning response doesn't have fqdn info.")
                    }
                    else {
                        $this.Logger.LogDebugMessage("AKS_FQDN:$aksFQDN")
                        $succeeded = $true
                    }
                }
                else {
                    $this.Logger.LogDebugMessage("Aks cluster provisioningState is not 'Succeeded': $($clusterInfo.provisioningState)")
                    $this.Logger.LogDebugMessage("Last Response: $lastResponseMessage")
                }
            }
            catch {
                $lastResponseMessage = $_.Exception.Message
                $this.Logger.LogDebugMessage($lastResponseMessage)
            }
            # if result is not successful, retry
            if (($i -lt $times) -and (-not $succeeded)) {
                # sleep before next retry. No need to have sleep time for the last iteration
                $this.Logger.LogDebugMessage("Start sleep before retry for $sleepSeconds seconds")
                Start-Sleep -Seconds $sleepSeconds
            }    
        }

        if ($succeeded) {
            $this.Logger.LogDebugMessage("Successfully provisioned AKS cluster")
        }
        else {
            throw "Failed to provision AKS cluster. Result: $lastResponseMessage"
        }
    }
}

# NodepoolProvisionScenario
# - class which performs nodepool provisioning. It is used to add an userpool to the existing AKS cluster
class NodepoolProvisionScenario : TestScenario {
    [ValidateNotNullOrEmpty()][string]$ClusterName
    [ValidateNotNullOrEmpty()][string]$ResourceGroupName
    [ValidateNotNullOrEmpty()][string]$NodepoolName
    [ValidateNotNullOrEmpty()][string]$UserpoolVMSku
    [int]$UserpoolNodeCount

    NodepoolProvisionScenario([string]$scenarioName, [string]$clusterName, [string]$resourceGroupName, [string]$nodepoolName, [string]$userpoolVMSku, [int]$userpoolNodeCount, [Logger]$logger)
    : base($scenarioName, $logger) {
        $this.ClusterName = $clusterName
        $this.ResourceGroupName = $resourceGroupName
        $this.NodepoolName = $nodepoolName
        $this.UserpoolVMSku = $userpoolVMSku
        $this.UserpoolNodeCount = $userpoolNodeCount
    }

    [void] RunCustomScenarioLogic() {
        $this.Logger.LogDebugMessage("Prepare nodepool provision script")
        $nodePoolProvisionScript = "az aks nodepool add --resource-group $($this.ResourceGroupName) --cluster-name $($this.ClusterName) --name $($this.NodepoolName) --mode User"
        $nodePoolProvisionScript += " --node-vm-size $($this.UserpoolVMSku) --node-count $($this.UserpoolNodeCount)"
        $this.Logger.LogDebugMessage("The script to execute:")
        $this.Logger.LogDebugMessage($nodePoolProvisionScript)
        $script = [ScriptBlock]::Create($nodePoolProvisionScript)
        $startTime = $(get-date)
        # Execute prepared nodepool provisioning script. The script will return once the nodepool is successfully provisioned with initial node count
        $result = &$script
        # Record TestTimeDuration
        $this.TestTimeDuration = $(get-date) - $startTime
        $this.Logger.LogDebugMessage("Nodepool provision completed - $($this.TestTimeDuration.TotalSeconds) seconds")
    }
}

# PodDeploymentScenario
# - class which performs pod deployment. It will deploy $replicaCount number of pods to the cluster and monitor until all the pods are scheduled and in running state. 
class PodDeploymentScenario : TestScenario {
    [ValidateNotNullOrEmpty()][string]$DeploymentFilePath
    [int]$ReplicaCount

    PodDeploymentScenario([string]$scenarioName, [string]$deploymentFilePath, [int]$replicaCount, [Logger]$logger)
    : base($scenarioName, $logger) {
        $this.DeploymentFilePath = $deploymentFilePath # yaml deployment file
        $this.ReplicaCount = $replicaCount
    }

    [void] RunCustomScenarioLogic() {
        $timeout = 300 # Test timeout in 5 minutes. This can be changed if it's for large number of replicas

        $scaleTest = [PodDeploymentTest]::new($this.ReplicaCount)
        $this.Logger.LogDebugMessage("Start kubectl event monitoring job as a background")
        # start pod events monitoring jobs as a background job
        $scaleTest.StartJobs()
        
        $startTime = Get-Date
        # output - array of pod statuses at each event
        $output = @()
        # initialize the array with the current time
        $output += $scaleTest.GetStats($startTime, $startTime, 0.0)

        # deploy the pod(s) with using the yaml deployment file
        kubectl apply -f $this.DeploymentFilePath
        $startTime = Get-Date

        $podStillPending = $true
        $pollingDuration = $(Get-Date) - $startTime;

        # Poll the pod events every 5 seconds until either the timeout or all the pods in running state
        $this.Logger.LogDebugMessage("Start polling events from the monitoring job")
        while ($pollingDuration.TotalSeconds -lt $timeout) {
            # if the event monitoring job is still running, poll the events
            if ($scaleTest.AllJobsRunning()) {
                $output += $scaleTest.ProcessNewEvents($startTime)
            }
            else {
                # if the job is not in running state, stop the job and resync the state
                $this.Logger.LogDebugMessage("Long polling fallback executing:")
                $scaleTest.StopJobs()
                $scaleTest.ResyncState()
                $endTime = $(Get-Date)
                $currentTime = $endTime - $startTime
                $output += $scaleTest.GetStats($startTime, $endTime, $currentTime.TotalSeconds)
            }
            # Check the status of all the pods based on the last retrieved events and check if there's any pod not in running state
            $podStillPending = -not $scaleTest.IsPodsInRunningState()
            $pollingDuration = $(Get-Date) - $startTime;
            $this.Logger.LogDebugMessage("Is pod still pending = '$podStillPending', Total time elapsed = $($pollingDuration.TotalSeconds) seconds")
            if (-not $podStillPending) {
                break
            }
            Start-Sleep -Seconds 5
        }
        $this.Logger.LogDebugMessage("Events: ")
        $output | ForEach-Object { $this.Logger.LogDebugMessage($_.ToString()) }
        $scaleTest.StopJobs()

        # if there's any pending pod, it's a failure. Log current status and throw exception
        if ($podStillPending) {
            $endTime = $(Get-Date)
            $failedTimestamp = $endTime - $startTime
            $finalMarker = $scaleTest.GetStats($startTime, $endTime, $failedTimestamp.TotalMinutes)
            $this.Logger.LogDebugMessage($finalMarker.WriteToHost())
            throw " Message: Stateful set update did not finish on all pods."
        }
        $scaleTest.CheckState()
        # Total Elapsed time can be retrieved from the last event which was the one reached the running state
        $lastEvent = $output[-1]
        # Record TestTimeDuration
        $this.TestTimeDuration = $lastEvent.EndDateTime - $lastEvent.StartDateTime
    }
}

# NodepoolScaleScenario
# - class which performs scale operations on a nodepool. It invokes 'az aks nodepool scale' command and monitor until it reaches the target node count (all nodes in READY state)
class NodepoolScaleScenario : TestScenario {
    [ValidateNotNullOrEmpty()][string]$ClusterName
    [ValidateNotNullOrEmpty()][string]$ResourceGroupName
    [ValidateNotNullOrEmpty()][string]$NodepoolName
    [int]$TargetNodeCount
    [int]$MonitorPollIntervalSeconds
    [timespan]$TestTimeout

    NodepoolScaleScenario([string]$scenarioName, [string]$clusterName, [string]$resourceGroupName, [string]$nodepoolName, [int]$targetNodeCount, [int]$monitorPollIntervalSeconds, [Logger]$logger)
    : base($scenarioName, $logger) {
        $this.ClusterName = $clusterName
        $this.ResourceGroupName = $resourceGroupName
        $this.NodepoolName = $nodepoolName
        $this.TargetNodeCount = $targetNodeCount
        $this.MonitorPollIntervalSeconds = $monitorPollIntervalSeconds
        $this.TestTimeout = New-TimeSpan -Minutes 5 # Set scale test timeout to 5 minutes. This can be modified.
    }

    [void] RunCustomScenarioLogic() {
        $this.Logger.LogDebugMessage("Scale $($this.NodepoolName) to $($this.TargetNodeCount) nodes")
        # invoke scale operation with --no-wait flag. It will trigger the scale and returns
        az aks nodepool scale --resource-group $this.ResourceGroupName --cluster-name $this.ClusterName --name $this.NodepoolName --node-count $this.TargetNodeCount --no-wait
        # After the trigger, run monitor function to montior the number of nodes as it reaches the target node count
        # Capture the total duration time. 
        $this.TestTimeDuration = $this.WaitNodePoolAgentCountToTargetCount()
    }

    [timespan] WaitNodePoolAgentCountToTargetCount()
    {
        $StartTime = $(get-date)
        $this.Logger.LogDebugMessage("Resource group: $($this.ResourceGroupName), ClusterName: $($this.ClusterName),  NodePoolName: $($this.NodepoolName), TargetCount: $($this.TargetNodeCount), PollIntervalInSeconds: $($this.MonitorPollIntervalSeconds), TestTimeout: $($this.TestTimeout.TotalMinutes) minutes")
        $elapsedTime = $StartTime - $StartTime
        
        $this.Logger.LogDebugMessage("Start monitoring for scaling to the target count...")
        $availableCount = -1
        $provisionState = "Succeeded"
        $results = @()
        while (($elapsedTime -le $this.TestTimeout) -and (($availableCount -ne $this.TargetNodeCount) -or (!"Succeeded".Equals($provisionState)))) {
            if ($elapsedTime -gt [TimeSpan]::Zero) {
                $this.Logger.LogDebugMessage("Sleep for $($this.MonitorPollIntervalSeconds) before next polling")
                Start-Sleep $this.MonitorPollIntervalSeconds
            }
            
            # Get the nodes data using kubectl
            $results = kubectl get nodes --no-headers
            $elapsedTime = $(get-date) - $StartTime

            $availableCount = 0
            $totalUserAgentCount = 0
            # foreach rows returned from the get nodes call, count the READY nodes and total number of nodes including pending ones
            foreach ($result in $results) {
                if ($result -match "Ready" -and $result -notmatch "NotReady" -and $result -match $this.NodepoolName) {
                    $availableCount++
                }
                # By excluding systempool, only count user pool nodes.
                if ($result -notmatch "systempool") {
                    $totalUserAgentCount++
                }
            }

            # To get more details about the nodepool, get nodepool information using az aks nodepool show
            $nodePoolInfo =  (az aks nodepool show --resource-group $this.ResourceGroupName --cluster-name $this.ClusterName --name $this.NodepoolName) | ConvertFrom-Json
            $provisionState = $nodePoolInfo.provisioningState #check the provisioning state of the nodepool
            # Log current status
            $this.Logger.LogDebugMessage("[Total elapsed seconds]: $($elapsedTime.TotalSeconds) | [Available (Ready) node count]: $availableCount | [Total node count]: $totalUserAgentCount | [Nodepool Provisioning State]: $provisionState")
            $this.Logger.LogDebugMessage("-------------------------------------------------------------------------------------------------------------")
        }

        # If it failed to reach the target node count after the test timeout, log the list of node information and throw exception
        if (($elapsedTime -ge $this.TestTimeout) -and ($availableCount -ne $this.TargetNodeCount)) {
            $this.Logger.LogDebugMessage("List of Nodes($($results.Count)) which are not ready...")
            foreach ($result in $results) {
                if ($result -match "Ready" -and $result -notmatch "NotReady") {
                    $this.Logger.LogDebugMessage("Ready: $result")
                }
                else {
                    $this.Logger.LogDebugMessage("Not Ready: $result")
                }
            }
            throw "Failed to reach to target AgentCount: $($this.TargetNodeCount), currently: $availableCount"
        }
        if (($elapsedTime -ge $this.TestTimeout) -and ($provisionState -ne "Succeeded")) {
            throw "Failed to reach to target state 'Succeeded', current state: $provisionState"
        }

        return $elapsedTime
    }
}

# ClusterDeletionScenario
# - class which performs cluster deletion and records the time it takes to delete the cluster
class ClusterDeletionScenario : TestScenario {
    [ValidateNotNullOrEmpty()][string]$ClusterName
    [ValidateNotNullOrEmpty()][string]$ResourceGroupName

    ClusterDeletionScenario([string]$scenarioName, [string]$clusterName, [string]$resourceGroupName, [Logger]$logger)
    : base($scenarioName, $logger) {
        $this.ClusterName = $clusterName
        $this.ResourceGroupName = $resourceGroupName
    }
    
    [void] RunCustomScenarioLogic() {
        $this.Logger.LogDebugMessage("Delete the AKS cluster '$($this.ClusterName)'")
        $startTime = $(get-date)
        # invoke az aks delete call which will return after the cluster deletion is completed
        az aks delete --name $this.ClusterName --resource-group $this.ResourceGroupName --yes
        $this.TestTimeDuration = $(get-date) - $startTime
        Write-Debug "Cluster Deletion has been completed - $($this.TestTimeDuration.TotalSeconds) seconds"
    }
}

# Functions to create scenarios
function New-ClusterCreationScenario([string]$clusterName, [string]$resourceGroupName, [string]$k8sVersion, [string]$networkPlugin, [boolean]$useOverlayNetwork, [string]$systempoolVMSku, [int]$systempoolNodeCount, [string]$skuTier, [Logger]$logger) {
    return [ClusterCreationScenario]::new("AKS Cluster Creation", $clusterName, $resourceGroupName, $k8sVersion, $networkPlugin, $useOverlayNetwork, $systempoolVMSku, $systempoolNodeCount, $skuTier, $logger)
}

function New-NodepoolProvisionScenario([string]$clusterName, [string]$resourceGroupName, [string]$nodepoolName, [string]$userpoolVMSku, [int]$userpoolNodeCount, [Logger]$logger) {
    return [NodepoolProvisionScenario]::new("AKS Nodepool Provision", $clusterName, $resourceGroupName, $nodepoolName, $userpoolVMSku, $userpoolNodeCount, $logger)
}

function New-PodDeploymentScenario([string]$deploymentFilePath, [int]$replicaCount, [Logger]$logger) {
    return [PodDeploymentScenario]::new("$replicaCount Pod(s) Deployment", $deploymentFilePath, $replicaCount, $logger)
}

function New-NodepoolScaleScenario([string]$scenarioName, [string]$clusterName, [string]$resourceGroupName, [string]$nodepoolName, [int]$targetNodeCount, [int]$monitorPollIntervalSeconds, [Logger]$logger) {
    return [NodepoolScaleScenario]::new($scenarioName, $clusterName, $resourceGroupName, $nodepoolName, $targetNodeCount, $monitorPollIntervalSeconds, $logger)
}

function New-ClusterDeletionScenario([string]$clusterName, [string]$resourceGroupName, [Logger]$logger)
{
    return [ClusterDeletionScenario]::new("AKS Cluster Deletion", $clusterName, $resourceGroupName, $logger)
}

function New-Logger([boolean]$silentMode) {
    return [Logger]::new($silentMode)
}