
This page documents the test benchmarks for node sclaing latency as conducted by the AKS team. Your experience may vary slightly based on the below listed factors, in case you see significant variance in your own test runs or production environment please create an issue in this project and engage with AKS product Group.

# AKS 1 Node Scale Out
Below are the configurations used to conduct these benchmark tests:
* Scale Type: Manual
* VM SKU: Standard_D8ds_v4
* Networking: Overlay CNI
* Region: West US 3
* K8s Version: Latest
* Node Image: Latest GA
* Cluster Tier: Standard Tier Uptime SLA
* Scale: 3 to 4 nodes
* Latency is defined as the duration from scale requested to operation completed

### October 2024

| P50 | P90 | P99 | P99.9 | # of Runs|
| ----------------- | ----------------- | ----------------- | ----------------- |---------|
| 53s |	67s |	79s |	123s | 537 |

### June 2024

| P50 | P90 | P99 | P99.9 | # of Runs|
| ----------------- | ----------------- | ----------------- | ----------------- |---------|
| 57s |	69s |	90s |	184s | 1384 |

### September 2023

| P50 | P90 | P99 | P99.9 | # of Runs|
| ----------------- | ----------------- | ----------------- | ----------------- |---------|
| 72s |	86s |	121s | 483s | 1998 |

# AKS 50 Node Scale Out
Below are the configurations used to conduct these benchmark tests:
* Scale Type: Manual
* VM SKU: Standard_D8ds_v5
* Networking: Overlay CNI
* Region: West US 3
* K8s Version: Latest
* Node Image: Latest GA
* Cluster Tier: Standard Tier Uptime SLA
* Scale: 3 to 53 nodes
* Latency is defined as the duration from scale requested to operation completed

### October 2024
| P50 | P90 |  P95 | P99 | # of Runs|
| ----------------- | ----------------- | ----------------- | ----------------- |---------|
| 76s |	91s |	112s | 250s | 1003 |

### June 2024
| P50 | P90 |  P95 | P99 | # of Runs|
| ----------------- | ----------------- | ----------------- | ----------------- |---------|
| 76s |	94s |	115s | 256s | 697 |

### January 2024  
| P50 | P90 |  P95 | P99 | # of Runs|
| ----------------- | ----------------- | ----------------- | ----------------- |---------|
| 100s | 135s | 160s | 261s |	1006 |

### November 2023  
| P50 | P90 |  P95 | P99 | # of Runs|
| ----------------- | ----------------- | ----------------- | ----------------- |---------|
| 116s | 160s | 199s | 346s | 1014 |
