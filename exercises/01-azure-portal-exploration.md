# Exercise 1: Azure Portal Exploration

## Learning Objectives

By the end of this exercise, you will understand:

- How Azure Local resources appear and are organized in the Azure Portal
- The relationship between Arc-enabled servers, the cluster, and custom locations
- How Azure management features extend to hybrid resources
- What operations you can perform on Azure Local from the portal

## Prerequisites

- Completed Exercise 0 (architecture understanding)
- LocalBox fully deployed and cluster operational
- Access to Azure Portal

## Context

One of the key value propositions of Azure Local is that it's managed **from Azure**. Unlike traditional on-premises infrastructure where you need separate tools (vCenter, SCVMM, etc.), Azure Local resources appear right in the Azure Portal alongside your cloud resources. This exercise explores what that looks like in practice.

## The Challenge

Navigate the Azure Portal to build a complete mental model of your LocalBox deployment. By the end, you should be able to draw a diagram (on paper or whiteboard) showing the relationships between all the Azure resources that were created.

## Exploration Tasks

### Task 1: Resource Group Inventory

Open your LocalBox resource group in the Azure Portal.

**Challenge:** Categorize every resource into one of these groups:
- **Infrastructure** (networking, compute, storage)
- **Management** (monitoring, security, identity)
- **Azure Local** (cluster, Arc, custom locations)

How many resources are in each category? Were there any surprises?

<details>
<summary>🔍 Hint</summary>

Use the "Group by type" option in the resource group view to organize resources. Look for these types:
- Virtual machines, Disks, Network interfaces, NSGs → Infrastructure
- Log Analytics workspaces, Storage accounts → Management
- Machine - Azure Arc, Azure Local cluster, Custom Location → Azure Local

</details>

### Task 2: Trace the Arc-Enabled Server Details

Click on one of the Arc-enabled server resources (`AzLHOST1` or `AzLHOST2`).

**Questions to answer:**
- What operating system is reported?
- What extensions are installed? What does each one do?
- What is the "Connected Machine Agent" version?
- Can you see the machine's hardware/software inventory?

<details>
<summary>🔍 Hint</summary>

Navigate through these blades on the Arc-enabled server:
- **Overview** — Basic info, OS, agent version
- **Extensions** — Installed Azure extensions (monitoring, security)
- **Properties** — Detailed machine metadata

Extensions are how Azure pushes management capabilities to Arc-enabled machines — similar to VM extensions on Azure VMs.

</details>

### Task 3: Explore the Cluster Resource

Open the `localboxcluster` resource.

**Challenge:** Find answers to these questions using ONLY the Azure Portal:
1. How much total storage is available in the cluster?
2. What networking configuration does the cluster use?
3. What Azure services can be deployed on this cluster? (Check the custom location)
4. Is the cluster up to date, or are updates available?

<details>
<summary>⚠️ Spoiler: Where to Find Each Answer</summary>

1. **Storage**: Click on the cluster → Settings → Storage. You'll see the storage pool configured with Storage Spaces Direct (S2D) across both nodes.

2. **Networking**: Cluster → Settings → Networking shows the network ATC configuration.

3. **Deployable services**: Click on the Custom Location `jumpstart` → Arc-enabled services. You'll see `hybridaksextension` and the resource bridge, which enable deploying AKS clusters and VMs.

4. **Updates**: Cluster → Settings → Updates shows the current version and whether updates are available.

</details>

### Task 4: Understand Custom Locations

Custom Locations are a key Azure Arc concept. Find the `jumpstart` custom location.

**Challenge:** Explain in your own words:
- What problem do Custom Locations solve?
- How does a Custom Location relate to the physical (or emulated) cluster?
- What would happen if you deleted the Custom Location?

<details>
<summary>🔍 Hint</summary>

Think of Custom Locations as an "address label" that tells Azure: "when someone wants to deploy resources *here*, send them to *this specific cluster*." Without it, Azure wouldn't know where to place workloads on your on-prem infrastructure.

</details>

<details>
<summary>⚠️ Spoiler: Explanation</summary>

**Custom Locations** bridge the gap between Azure's resource model and your on-premises infrastructure:

- Azure resources need a `location` (e.g., `eastus`, `westeurope`)
- On-prem clusters aren't Azure regions, so they can't be a regular location
- A Custom Location is an extension that maps a specific cluster to a deployable target
- It's backed by an **Azure Arc Resource Bridge**, which is a lightweight Kubernetes cluster that acts as the "ambassador" between Azure and the on-prem infrastructure

If you deleted the Custom Location, you'd lose the ability to deploy new VMs or AKS clusters on the Azure Local cluster from the portal. Existing workloads would continue running.

</details>

### Task 5: Compare with "Normal" Azure Resources

This is a thought exercise. Look at how Arc-enabled resources compare to native Azure resources:

| Feature | Azure VM | Arc-enabled Server |
|---------|----------|--------------------|
| Where it runs | Azure datacenter | Anywhere |
| Show in Portal? | ✅ | ✅ |
| Azure Policy? | ✅ | ? |
| Azure Monitor? | ✅ | ? |
| Start/Stop from Portal? | ✅ | ? |
| Resize from Portal? | ✅ | ? |

**Fill in the `?` marks** by exploring the portal blades of an Arc-enabled server.

<details>
<summary>⚠️ Spoiler: Answers</summary>

| Feature | Azure VM | Arc-enabled Server |
|---------|----------|--------------------|
| Azure Policy? | ✅ | ✅ (via Guest Configuration) |
| Azure Monitor? | ✅ | ✅ (via extensions) |
| Start/Stop from Portal? | ✅ | ❌ (the machine isn't controlled by Azure compute) |
| Resize from Portal? | ✅ | ❌ (hardware is managed locally) |

This is a key insight: **Arc extends management and governance, not compute lifecycle.** Azure can monitor, audit, and enforce policy on Arc-enabled machines, but it doesn't control the power button or hardware allocation — that's handled by the local infrastructure (in this case, Azure Local/Hyper-V).

</details>

## Reflection Questions

1. **How does this management model compare to traditional on-prem tools like vCenter or SCVMM?** What are the advantages and trade-offs of managing everything through the Azure Portal?

2. **If you were an IT admin managing 50 physical servers across 3 branch offices, how would Arc help?** Think about what you explored — extensions, policies, monitoring — applied at scale.

3. **Why does Azure Local need both Arc-enabled servers AND a cluster resource?** What does each one represent, and what operations are available on each?

## Next Exercise

➡️ [Exercise 2: Networking & VM Management](./02-networking-and-vms.md)
