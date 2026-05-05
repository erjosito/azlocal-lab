# Azure Local Operations - SRE Knowledge Base

## Overview

This document teaches the Azure SRE Agent how Azure Local environments are structured, how common incidents present themselves, and what remediation patterns are appropriate. It is designed for hybrid incident investigation where the root cause could live in Azure, Azure Arc, Kubernetes, storage, networking, or the Azure Local hosts themselves.

## Azure Local Architecture and Components

An Azure Local environment usually contains these layers:

1. **Azure control plane**
   - Azure Local cluster resource
   - Azure Arc resource representations
   - Azure Monitor, Policy, RBAC, and alerts
2. **Azure Local infrastructure layer**
   - Physical or nested hosts
   - Failover clustering
   - Storage Spaces Direct / storage pool / CSV volumes
   - Logical networks and VM networking
3. **Workload virtualization layer**
   - Azure Local VMs
   - AKS on Azure Local node VMs
4. **Platform services layer**
   - AKS on Azure Local
   - Arc-enabled Kubernetes
   - Arc extensions and custom locations
   - Azure Arc-enabled data services
5. **Application layer**
   - User VMs, databases, and containerized workloads

### Operating Principle

When investigating incidents, always separate:

- **Management plane symptoms**: Azure Portal, Arc, policies, monitor ingestion, inventory gaps
- **Data plane symptoms**: application downtime, VM failure, pod crash loops, storage latency, packet loss

A management plane issue does not always mean workloads are down. A data plane issue can exist even when Azure resource inventory still looks healthy.

---

## Category 1: Cluster Health Issues

### Scenario 1.1: One Azure Local Node Is Down or Disconnected
- **Impact**: Reduced cluster resiliency; possible loss of failover capacity; maintenance operations become risky
- **Symptoms**: One node shows offline in cluster views, Azure health signals degrade, workloads may live-migrate or rebalance
- **Root Cause**: Host VM crash, nested host outage, patching failure, failed reboot, or network loss between nodes
- **Detection**:
  - Azure Portal shows degraded cluster health
  - `Get-ClusterNode` shows a node as `Down` or `Paused`
  - `az monitor activity-log list --resource-group <rg> --offset 6h`
- **Resolution**:
  - Verify the failed host is powered on and reachable
  - Restore management and cluster network connectivity
  - Resume the node after confirming health
  - Rebalance workloads only after cluster stability is restored
- **Prevention**: Use planned maintenance workflows, validate host health before patching, and monitor node heartbeat / availability

### Scenario 1.2: Cluster Quorum at Risk
- **Impact**: Cluster may lose ability to coordinate failover decisions; workload disruption becomes possible
- **Symptoms**: Repeated cluster warnings, unstable ownership changes, failover actions blocked or delayed
- **Root Cause**: Multiple node failures, witness misconfiguration, or unstable node-to-node communication
- **Detection**:
  - Failover clustering events indicate quorum warnings
  - `Get-ClusterQuorum`
  - `Get-ClusterGroup`
- **Resolution**:
  - Restore missing nodes or witness connectivity
  - Validate cluster communication paths
  - Correct witness configuration before planned changes continue
- **Prevention**: Maintain a valid quorum witness design, avoid simultaneous maintenance on multiple nodes, and alert on repeated cluster membership changes

---

## Category 2: Storage Failures

### Scenario 2.1: Storage Pool or Virtual Disk Is Degraded
- **Impact**: Performance degradation, reduced resiliency, increased rebuild risk, possible workload impact
- **Symptoms**: Storage warnings in cluster health, higher latency, degraded virtual disk state, noisy failovers
- **Root Cause**: Failed physical disk, storage service issue, misbehaving host, or underlying nested disk problem in lab environments
- **Detection**:
  - `Get-StoragePool`
  - `Get-VirtualDisk`
  - `Get-PhysicalDisk`
  - Azure Monitor metrics show rising latency or storage warnings
- **Resolution**:
  - Identify the failed disk or host path
  - Replace or recover the failed component
  - Allow repair / rebuild to complete before resuming risky operations
  - Confirm volumes return to healthy state
- **Prevention**: Capacity planning, proactive disk health monitoring, and validating hardware / VM storage dependencies before upgrades

### Scenario 2.2: CSV / Volume Capacity Nearly Exhausted
- **Impact**: VM writes fail, Kubernetes persistent volumes fail to expand or attach, performance drops, services may go read-only or crash
- **Symptoms**: Low free space alerts, failed application writes, pod scheduling issues for stateful workloads
- **Root Cause**: Unexpected data growth, logs consuming disk, snapshots left in place, insufficient storage planning
- **Detection**:
  - `Get-Volume`
  - `kubectl describe pvc <name>` for storage-backed pods
  - Azure Monitor alerts for low capacity
- **Resolution**:
  - Free unused data, snapshots, or logs
  - Expand storage if the design supports it
  - Move non-critical workloads off the affected volume
- **Prevention**: Capacity alerts, retention policies, and headroom planning for both VM and Kubernetes storage

---

## Category 3: VM/Workload Failures

### Scenario 3.1: VM Fails to Start or Becomes Unresponsive
- **Impact**: Application outage for VM-hosted services; possible dependency failure for clustered apps or management tools
- **Symptoms**: VM stuck in starting state, heartbeat lost, guest unreachable over RDP/SSH, Azure resource still visible
- **Root Cause**: Guest OS failure, resource pressure on host, broken boot volume, or integration service issues
- **Detection**:
  - `Get-VM`
  - `Get-VMNetworkAdapter`
  - `az vm list -g <rg> -o table`
  - Azure activity logs for recent VM operations
- **Resolution**:
  - Check host capacity and VM state
  - Review guest console / boot diagnostics if available
  - Restart or fail over the VM only after confirming storage/network dependencies
- **Prevention**: Guest patching discipline, VM monitoring, and right-sizing to avoid CPU or memory starvation

### Scenario 3.2: Application Healthy at Host Level but Service Is Down
- **Impact**: End users experience outage even though infrastructure looks healthy
- **Symptoms**: VM is running, pods are scheduled, but application endpoint returns errors or timeouts
- **Root Cause**: App crash, dependency outage, service misconfiguration, expired certificate, bad deployment, or DNS issue
- **Detection**:
  - Application logs
  - `kubectl get pods,svc -A`
  - Azure Monitor alert correlated with app-specific metrics or availability tests
- **Resolution**:
  - Confirm whether the fault is in the app, not the host
  - Roll back the last change if the failure is tied to deployment timing
  - Restore dependency connectivity or credentials
- **Prevention**: Synthetic testing, change control, and workload-specific health probes

---

## Category 4: Networking Issues

### Scenario 4.1: Logical Network / VLAN Misconfiguration
- **Impact**: VMs or AKS nodes lose connectivity; east-west and north-south traffic may fail
- **Symptoms**: Intermittent or total packet loss, inability to reach gateways, pods failing readiness because dependencies cannot be reached
- **Root Cause**: Wrong VLAN, wrong subnet, NIC mapping drift, switch config mismatch, or malformed logical network settings
- **Detection**:
  - `Get-VMNetworkAdapter`
  - `Get-NetIPAddress`
  - `kubectl exec <pod> -- nslookup <target>` and connectivity checks from pods
  - Azure Monitor connectivity alerts or Connection Monitor failures
- **Resolution**:
  - Correct VLAN / subnet mapping
  - Validate gateway and DNS configuration
  - Reattach affected VM or host adapters to the correct logical network
- **Prevention**: Document network design clearly, validate after changes, and use synthetic connectivity tests between critical tiers

### Scenario 4.2: DNS or Name Resolution Failure
- **Impact**: Workloads appear down even when IP connectivity exists; service discovery breaks
- **Symptoms**: Timeouts on hostname-based connections, applications fail to find databases or APIs, cluster control plane components may become unstable
- **Root Cause**: Wrong DNS server, stale records, unreachable resolver, or CoreDNS issue in AKS
- **Detection**:
  - `Resolve-DnsName <name>`
  - `kubectl get pods -n kube-system`
  - `kubectl logs -n kube-system deployment/coredns`
- **Resolution**:
  - Restore correct DNS server settings
  - Fix stale or missing records
  - Restart or repair DNS components only after identifying configuration drift
- **Prevention**: Monitor DNS dependencies, validate records during deployment, and keep name resolution paths simple for critical services

---

## Category 5: AKS on Azure Local Issues

### Scenario 5.1: Pods in CrashLoopBackOff
- **Impact**: Containerized application outage or partial outage
- **Symptoms**: Pods restart repeatedly, services have no ready endpoints, alerts fire for unhealthy containers
- **Root Cause**: Bad image, bad startup command, missing secret, broken config, or failed dependency
- **Detection**:
  - `kubectl get pods -A`
  - `kubectl describe pod <pod-name>`
  - `kubectl logs <pod-name> --previous`
  - Azure Monitor log alert for `CrashLoopBackOff`
- **Resolution**:
  - Inspect recent deployment changes
  - Correct the image, command, secret, or config
  - Roll back to the last known good ReplicaSet if needed
- **Prevention**: Readiness/liveness probes, staged rollouts, and alerting on restart count trends

### Scenario 5.2: AKS Node NotReady or Resource Exhaustion
- **Impact**: Scheduling failures, evictions, degraded application performance, loss of cluster headroom
- **Symptoms**: Pending pods, evicted pods, high CPU/memory on nodes, kubelet-related alerts
- **Root Cause**: Host resource shortage, oversized workloads, insufficient AKS node count, or storage/network dependency failure on the node VM
- **Detection**:
  - `kubectl get nodes`
  - `kubectl describe node <node-name>`
  - `kubectl top nodes`
  - Azure Monitor metrics for node pressure
- **Resolution**:
  - Free or rebalance resources
  - Scale the node pool or reduce workload demand
  - Investigate whether the problem is actually upstream in Azure Local host capacity
- **Prevention**: Resource requests/limits, node capacity planning, and alerts on pressure conditions before evictions begin

---

## Category 6: Arc Integration Issues

### Scenario 6.1: Azure Arc Resource Appears Disconnected
- **Impact**: Loss of Azure management visibility, stale inventory, delayed policy/compliance reporting, possible loss of extension workflows
- **Symptoms**: Resource still exists in Azure but shows disconnected or stale heartbeat; Azure-side operations fail even though local workloads continue running
- **Root Cause**: Outbound connectivity issue, expired credentials, Arc agent failure, or proxy/firewall changes
- **Detection**:
  - Azure Portal connection status
  - `az connectedk8s list -g <rg> -o table`
  - `az k8s-extension list --cluster-name <cluster-name> --cluster-type connectedClusters -g <rg> -o table`
- **Resolution**:
  - Restore outbound connectivity to Azure endpoints
  - Restart or repair the Arc agent / extension components
  - Revalidate identity and proxy settings
- **Prevention**: Monitor Arc heartbeat, document outbound dependencies, and alert on disconnected resources quickly

### Scenario 6.2: Arc Extension or Custom Location Problem Blocks Platform Services
- **Impact**: New platform services fail to deploy or manage correctly; Azure-side lifecycle actions fail
- **Symptoms**: Extension provisioning errors, custom location unavailable, data services or AKS management workflows fail
- **Root Cause**: Failed extension upgrade, namespace permissions issue, extension configuration drift, or broken custom location binding
- **Detection**:
  - `az k8s-extension list --cluster-name <cluster-name> --cluster-type connectedClusters -g <rg> -o table`
  - `kubectl get pods -A`
  - Azure activity logs for failed extension operations
- **Resolution**:
  - Identify the failing extension and namespace
  - Repair or redeploy the extension if necessary
  - Confirm the custom location still maps to the intended Arc-enabled Kubernetes cluster
- **Prevention**: Validate extension health after upgrades and treat custom locations as critical platform dependencies

---

## Category 7: Arc-Enabled Data Services Issues

### Environment Context — LocalBox Lab

In the emulated LocalBox environment, AKS worker nodes typically use `Standard_A4_v2` VMs. Despite the 8 GB nominal RAM, Kubernetes only reports **~2.5 GB allocatable memory per worker node** (the rest is consumed by the OS, kubelet, and system reservations). The control plane node has ~7.5 GB allocatable but is tainted `NoSchedule` by default.

**Key resource figures for planning:**
- Worker node allocatable: ~1900m CPU, ~2.5 GB memory each
- Control plane node: ~4 CPU, ~7.5 GB memory (tainted `node-role.kubernetes.io/control-plane:NoSchedule`)
- Arc Data Controller `controldb-0` pod: requests **4 GB RAM** minimum
- SQL Managed Instance (General Purpose, 2 vCPUs): requests **4 vCPUs + 16 GB RAM**

### Custom Locations for Data Services

Arc-enabled data services require their **own custom location** on the AKS Arc-connected cluster. This is separate from the Azure Local cluster's `jumpstart-cl` custom location.

- The custom location must target the **Arc-enabled Kubernetes cluster** (not the Azure Local cluster resource)
- The `--location` parameter must match the connected cluster's region (e.g., `westeurope`)
- Region mismatch between the connected cluster and the custom location will cause a deployment error

```bash
# Get the AKS cluster's connected cluster ID
aksClusterId=$(az connectedk8s show -n localbox-aks -g <rg> --query id -o tsv)

# Get the data services extension ID
extensionId=$(az k8s-extension show --cluster-name localbox-aks --cluster-type connectedClusters -g <rg> --name arc-data-services --query id -o tsv)

# Create custom location — region must match the cluster
az customlocation create -n aks-data-location -g <rg> \
  --namespace arc \
  --host-resource-id $aksClusterId \
  --cluster-extension-ids $extensionId \
  --location westeurope
```

### Scenario 7.1: Arc Data Controller Stuck in "Deploying" State

- **Impact**: No data services can be created; SQL MI deployment is blocked
- **Symptoms**: Data controller resource in Azure shows "Deploying" indefinitely; `controldb-0` pod in Pending or ContainerCreating state
- **Root Cause**: Insufficient node memory. `controldb-0` requests 4 GB RAM but no worker node has 4 GB allocatable memory in the emulated environment.
- **Detection**:
  ```bash
  kubectl get pods -n arc
  kubectl describe pod controldb-0 -n arc
  kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
  ```
  Look for `Insufficient memory` in pod events.
- **Resolution**:
  - **Option 1 (preferred for production):** Scale to nodes with ≥ 16 GB RAM (e.g., `Standard_D4s_v3`)
  - **Option 2 (lab workaround):** Remove the control-plane taint so the control plane node (with ~7.5 GB) can schedule data service pods:
    ```bash
    kubectl taint nodes <control-plane-node> node-role.kubernetes.io/control-plane:NoSchedule-
    ```
  - After removing the taint, the scheduler will place `controldb-0` on the control plane node and the data controller will transition to "Ready"
- **Prevention**: When deploying AKS clusters that will host data services, use at least 16 GB per node. Add a sizing note to runbooks.

### Scenario 7.2: Arc Data Services Extension Installation Failure

- **Impact**: Cannot create custom location or data controller; entire data services stack is blocked
- **Symptoms**: Extension shows "Failed" in Azure Portal or CLI; pods in the `arc` namespace are missing or crashing
- **Root Cause**: The `microsoft.arcdataservices` extension is **not available in the portal Extensions gallery** — it must be installed via CLI. Attempting portal installation results in "extension not found" or silent failure.
- **Detection**:
  ```bash
  az k8s-extension list --cluster-name localbox-aks --cluster-type connectedClusters -g <rg> -o table
  kubectl get pods -n arc
  ```
- **Resolution**:
  Install the extension via CLI only:
  ```bash
  az k8s-extension create --cluster-name localbox-aks \
    --cluster-type connectedClusters -g <rg> \
    --name arc-data-services \
    --extension-type microsoft.arcdataservices \
    --auto-upgrade false \
    --scope cluster \
    --config Microsoft.CustomLocation.ServiceAccount=sa-bootstrapper
  ```
  Wait for provisioning state to show "Succeeded" before creating the custom location.
- **Prevention**: Document that Arc data services extension is CLI-only. Do not attempt portal-based extension installation.

### Scenario 7.3: SQL Managed Instance Pods Stuck in Pending

- **Impact**: SQL MI is not available; application databases cannot be served
- **Symptoms**: SQL MI resource shows "Deploying" in Azure; pods in the `arc` namespace (especially `sqlmi-*`) are Pending
- **Root Cause**: SQL MI General Purpose (2 vCPUs) requests at minimum **4 vCPUs and 16 GB RAM**. Combined with data controller overhead, the cluster needs substantial free capacity.
- **Detection**:
  ```bash
  kubectl get pods -n arc
  kubectl describe pod <sqlmi-pod> -n arc
  kubectl top nodes
  ```
- **Resolution**:
  - Scale the node pool to 3+ nodes: `az aksarc nodepool scale --cluster-name localbox-aks -g <rg> --name nodepool1 --node-count 3`
  - If using the emulated environment with small nodes, remove the control-plane taint (see Scenario 7.1)
  - Verify total cluster allocatable resources exceed data controller + SQL MI combined requirements
- **Prevention**: Plan cluster capacity before deploying data services. A minimum of 3 nodes with 16 GB RAM each is recommended for SQL MI workloads.

### Scenario 7.4: Custom Location Region Mismatch Error

- **Impact**: `az customlocation create` fails with region mismatch error; data services deployment is blocked
- **Symptoms**: Error message: "Host resource region: <X> does not match Custom Location region: <Y>"
- **Root Cause**: The `--location` parameter on `az customlocation create` defaults to a different region than the connected cluster
- **Detection**: The error message itself is clear and diagnostic
- **Resolution**:
  Add `--location <cluster-region>` explicitly to the create command. The region must match the Arc-connected cluster's region, not the resource group's region.
- **Prevention**: Always specify `--location` explicitly when creating custom locations. Check the cluster region first:
  ```bash
  az connectedk8s show -n localbox-aks -g <rg> --query location -o tsv
  ```

### Data Controller Configuration Notes

- **Kubernetes config template**: Use `azure-arc-aks-hci` for AKS on Azure Local (not `azure-arc-aks` which is for cloud AKS)
- **SQL MI creation path**: SQL MI is a **top-level Azure resource** — search "SQL Managed Instance – Azure Arc" in the portal, or navigate via Azure Arc → SQL managed instances. It is NOT created from the data controller blade.
- **Expected pods in `arc` namespace** after full deployment:
  - Data controller: `controldb-0`, `controller-*`, `logsdb-0`, `logsui-*`, `metricsdb-0`, `metricsdc-*`, `metricsui-*`
  - SQL MI: `<instance-name>-0` (plus additional pods for HA if configured)

---

## Investigation Playbook

### Step-by-Step Approach

1. **Classify the symptom first**
   - Is this management plane only, data plane only, or both?
2. **Identify the affected layer**
   - Azure / Arc
   - Azure Local cluster
   - Storage
   - VM
   - AKS / Kubernetes
   - Application
3. **Correlate recent changes**
   - Activity Log, deployment history, patching windows, cluster operations
4. **Check dependencies in order**
   - Cluster health → storage → networking → compute → Kubernetes → workload
5. **Prefer evidence over assumptions**
   - Use metrics, logs, pod events, cluster state, and host health to support findings
6. **Recommend the least risky fix first**
   - Roll back recent changes before attempting invasive recovery

---

## Diagnostic Command Quick Reference

### Azure CLI

```bash
az resource list -g <resource-group> -o table
az monitor activity-log list --resource-group <resource-group> --offset 6h
az monitor alert list --resource-group <resource-group> -o table
az connectedk8s list -g <resource-group> -o table
az k8s-extension list --cluster-name <cluster-name> --cluster-type connectedClusters -g <resource-group> -o table
az vm list -g <resource-group> -o table
```

### Kubernetes

```bash
kubectl get nodes
kubectl get pods -A
kubectl describe pod <pod-name>
kubectl logs <pod-name> --previous
kubectl top nodes
kubectl top pods -A
kubectl get pvc -A
```

### PowerShell / Azure Local Host Diagnostics

```powershell
Get-ClusterNode
Get-ClusterGroup
Get-StoragePool
Get-VirtualDisk
Get-PhysicalDisk
Get-Volume
Get-VM
Get-VMNetworkAdapter
Resolve-DnsName <name>
```

## Key Remediation Principle

Do not assume every Azure Local incident should be fixed from Azure first. Azure is often where you **see** the incident, but the actual repair may need to happen in Kubernetes, in the guest workload, on the Azure Local hosts, or in the local network path.
