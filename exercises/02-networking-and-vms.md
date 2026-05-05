# Exercise 2: Networking & VM Management

## Learning Objectives

By the end of this exercise, you will understand:

- How logical networks work on Azure Local and why they're needed
- How to create VM images from Azure Marketplace for on-prem deployment
- The end-to-end workflow for deploying a VM on Azure Local through Azure Portal
- IP addressing, VLAN segmentation, and DNS in a hybrid environment

## Prerequisites

- Completed Exercises 0 and 1
- LocalBox cluster fully deployed and operational
- RDP access to LocalBox-Client VM

## Context

In a traditional Azure deployment, you create a VNet, add a subnet, and deploy a VM — Azure handles all the networking plumbing. On Azure Local, you're responsible for the physical (or emulated) network. You need to create **logical networks** that map to your actual network infrastructure before you can deploy VMs. This is closer to how a real datacenter operates.

## Understanding the Network Before You Start

LocalBox comes with preconfigured network segments at the infrastructure level (Hyper-V virtual switches and VLAN routing on the VM-Router). These exist in the underlying network fabric but are **not** automatically visible as Azure "Logical Network" resources — you need to create those yourself in Challenge 1.

To see the raw network topology, you'd check the VM-Router (`ip addr`, `ip route`) or the Hyper-V switch config on the nodes. Here's what the infrastructure provides:

| Network | Subnet | VLAN | Purpose |
|---------|--------|------|---------|
| Management | 192.168.1.0/24 | - | Cluster nodes, DC, router |
| VM Network | 192.168.200.0/24 | 200 | Arc-managed VMs |
| AKS Network | 10.10.0.0/24 | 110 | AKS workload clusters |

> **Key concept:** Unlike Azure VNets (which are software-defined and abstract), logical networks on Azure Local map directly to physical switch ports, VLANs, and IP ranges. Creating a logical network in Azure doesn't create the underlying network — it merely *declares* an existing network segment so Azure can assign IPs and attach VM NICs to it. If you get the VLAN or subnet wrong, your VMs won't have connectivity.

---

## Challenge 1: Create a Logical Network

**Goal:** Create a logical network resource that maps to the preconfigured VM subnet (192.168.200.0/24, VLAN 200) so you can deploy VMs.

**What you need to figure out:**
- Where in the Azure portal do you create a logical network for Azure Local?
- What parameters does it need (subnet, gateway, DNS, VLAN)?
- How do you verify the logical network was created correctly?

<details>
<summary>🔍 Hint 1 — Where to start</summary>

In the Azure Portal, navigate to your resource group and look at the Azure Local cluster resource (`localboxcluster`). Under **Settings** or **Resources**, look for networking-related options. Alternatively, search for "Logical Networks" in the portal search bar.

</details>

<details>
<summary>🔍 Hint 2 — Parameters</summary>

The logical network needs these settings:
- **Name:** something descriptive (e.g., `vm-network-200`)
- **VM switch name:** `ConvergedSwitch(oob-hci)`
- **Subnet:** 192.168.200.0/24
- **Gateway:** 192.168.200.1
- **IP allocation method:** Static
- **IP pool:** 192.168.200.10 – 192.168.200.252
- **VLAN ID:** 200
- **DNS Server:** 192.168.1.254 (the domain controller)

Using static IP allocation (with a defined pool) ensures VMs get predictable addresses and that DNS is properly configured on each VM.

</details>

<details>
<summary>⚠️ Spoiler: Full Solution</summary>

1. Azure Portal → your resource group → click on the `localboxcluster` resource
2. In the left menu, go to **Resources** → **Logical networks**
3. Click **+ Create**
4. Fill in:
   - **Name:** `vm-network-200`
   - **VM switch name:** `ConvergedSwitch(oob-hci)`
   - **IP address allocation method:** Static
   - Add a subnet with:
     - Address prefix: `192.168.200.0/24`
     - Gateway: `192.168.200.1`
     - VLAN: `200`
     - DNS servers: `192.168.1.254`
     - IP pool start: `192.168.200.10`
     - IP pool end: `192.168.200.252`
5. Click **Review + Create** → **Create**
6. Verify: the logical network should appear in your resource group within a minute

> **Note:** There is also a script `C:\LocalBox\Configure-VMLogicalNetwork.ps1` on LocalBox-Client that does the same thing via CLI, if you prefer to review the programmatic approach after completing the portal walkthrough.

</details>

---

## Challenge 2: Download a VM Image from Azure Marketplace

**Goal:** Before creating a VM, you need an OS image. Download a Windows or Linux image from Azure Marketplace to your Azure Local cluster.

**What you need to figure out:**
- Where in the Azure Portal can you manage VM images for Azure Local?
- How do you download a marketplace image to the local cluster?
- How long does it take, and how do you monitor progress?

> 💡 **Think about it:** Why can't Azure Local VMs just use Azure Marketplace images directly like regular Azure VMs? What's different about the compute infrastructure?

<details>
<summary>🔍 Hint</summary>

Navigate to your cluster resource → **VM Images** blade. The "Add VM image" dropdown has an "From Azure Marketplace" option.

Choose a smaller image (like Windows Server 2025 Core or Ubuntu Server) to reduce download time.

</details>

<details>
<summary>⚠️ Spoiler: Full Solution</summary>

1. Azure Portal → Your resource group → Click the `localboxcluster` resource
2. Left menu → **VM Images**
3. Click **Add VM image** → **From Azure Marketplace**
4. Select an image (e.g., "Windows Server 2025 Datacenter: Azure Edition - Smalldisk")
5. Give it a name, select the `jumpstart` custom location
6. Leave storage path as "Choose automatically"
7. Click **Review + Create** → **Create**

Monitor progress: go to your resource group → find the VM Image resource → check Properties for download status.

**Why can't Azure Local use images directly?** Because the cluster isn't in an Azure datacenter. The image needs to be physically downloaded to the cluster's local storage before VMs can use it. This is fundamentally different from Azure VMs, which can access marketplace images instantly from Microsoft's storage infrastructure.

</details>

---

## Challenge 3: Deploy a Virtual Machine

**Goal:** Deploy a virtual machine on your Azure Local cluster through the Azure Portal, connected to the logical network you created.

**Requirements:**
- Use the VM image you downloaded
- Connect it to the logical network from Challenge 1
- Configure it with 2 vCPUs and 4-8 GB RAM (the cluster has limited resources)
- Successfully connect to the VM

**What you need to figure out:**
- How to create the VM from the Azure Portal
- How to add a network interface and associate it with your logical network
- How to connect to the VM (remember: it's on a nested network, not directly accessible from the internet)

<details>
<summary>🔍 Hint 1 — Creating the VM</summary>

Cluster resource → **Virtual machines** blade → **Create virtual machine**.

Keep resources small! The LocalBox cluster has limited RAM. Use:
- 2 vCPUs
- 4096 MB memory (or 8192 if available)
- Standard security type

</details>

<details>
<summary>🔍 Hint 2 — Networking</summary>

On the Networking tab, click "Add network interface" and select the logical network you created in Challenge 1. Set allocation method to Automatic.

</details>

<details>
<summary>🔍 Hint 3 — Connecting to the VM</summary>

The VM is on the 192.168.200.0/24 subnet, which is NOT directly routable from your machine or even from LocalBox-Client. You need to "hop" through the management VM:

1. From LocalBox-Client: `mstsc /v:192.168.1.11` (connect to AzLMGMT)
2. From AzLMGMT: `mstsc /v:192.168.200.x` (connect to your new VM, replace x with its IP)

</details>

<details>
<summary>⚠️ Spoiler: Full Solution</summary>

**Create the VM:**
1. Azure Portal → Cluster resource → Virtual machines → Create virtual machine
2. Fill in:
   - Resource group: your LocalBox RG
   - Name: e.g., `test-vm-01`
   - Security type: Standard
   - Image: select the image you downloaded
   - vCPUs: 2
   - Memory: 4096 or 8192 MB
3. Click Next → Next to reach Networking
4. Click "Add network interface"
   - Name: `test-vm-01-nic`
   - Network: select your logical network
   - Allocation: Automatic
5. Review + Create → Create

**Connect to it:**
1. Wait for the VM to show as "Running" in the portal
2. Check its IP address in the VM resource's properties (will be in 192.168.200.x range)
3. From LocalBox-Client: `mstsc /v:192.168.1.11` (connect to AzLMGMT)
4. From AzLMGMT: `mstsc /v:192.168.200.x`

**Note:** The VM appears as an Azure resource managed through Arc, just like it would on real Azure Local hardware. You can see it in the portal, apply policies to it, and monitor it — even though it's running on your "on-prem" cluster.

</details>

---

## Deep Dive: IP Planning Matters

Before moving on, consider this real-world scenario:

> You have a 192.168.200.0/24 subnet with 254 usable IPs. You want to deploy:
> - 20 production VMs
> - An AKS cluster that needs 30 IPs (nodes + pods + services)
> - Room for future growth
>
> **Is this subnet big enough?** What if you also need static IPs for some services?

<details>
<summary>🔍 Think About It</summary>

In real Azure Local deployments, IP exhaustion is a common problem because:
1. AKS clusters need IPs for nodes, load balancers, and services
2. VMs each need at least one IP
3. Some IPs are reserved (gateway, broadcast)
4. You often need separate subnets/VLANs for different workloads

In LocalBox, the subnets are pre-sized for lab use. In production, careful IP planning is essential before deployment.

</details>

## Reflection Questions

1. **How does VM deployment on Azure Local compare to deploying an Azure VM?** What steps are similar? What's completely different?

2. **Why does Azure Local need VLAN-based network segmentation?** Could you use Azure-style VNets instead?

3. **If the Azure connection went offline, could you still manage VMs on the cluster?** What tools would you use?

## Next Exercise

➡️ [Exercise 3: AKS on Azure Local](./03-aks-on-azure-local.md)
