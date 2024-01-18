
This page documents the test benchmarks for node sclaing latency as conducted by the AKS team. Your experience may vary slightly based on the below listed factors, in case you see significant variance in your own test runs or production environment please create an issue in this project and engage with AKS product Group.

### AKS 50 Node Scale Out
Below are the configurations used to conduct these benchmark tests
* Scale Type: Manual
* VM SKU: Standard_D8ds_v5
* Networking: Overlay CNI
* Region: East US
* K8s Version: Latest
* Node Image: Latest GA
* Cluster Tier: Standard Tier Uptime SLA

# 1/15/24 test results 
### Results - Latency to scale up the nodepool from 3 to 53 nodes (based on 7 days of tests).
  
| P50 | P90 |  P95 | P99 | # of Runs|
| ----------------- | ----------------- | ----------------- | ----------------- |---------|
| 1.67 Mins|	2.25 Mins|	2.67 Mins|	4.35 Mins|	1006 |

# 11/06/23 test results 
### Results - Latency to scale up the nodepool from 3 to 53 nodes (based on 7 days of tests).
  
| P50 | P90 |  P95 | P99 | # of Runs|
| ----------------- | ----------------- | ----------------- | ----------------- |---------|
| 1.94 Mins|	2.68 Mins|	3.32 Mins|	5.78 Mins|	1014 |
