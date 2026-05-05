# Exercise 3: AKS on Azure Local

## Learning Objectives

By the end of this exercise, you will understand:

- How AKS on Azure Local differs from AKS in the public cloud
- The role of Azure Arc in connecting on-premises Kubernetes to Azure
- How to deploy and connect to a Kubernetes cluster running on Azure Local
- The networking requirements for AKS on Azure Local

## Prerequisites

- Completed Exercises 0-2
- Understanding of logical networks (from Exercise 2)
- Basic familiarity with Kubernetes concepts (pods, deployments, services)
- Entra ID permissions to create a security group (or membership in an existing one)
- `kubectl` installed on LocalBox-Client (should already be present from the base deployment)

## Context

One of the most powerful features of Azure Local is running **AKS (Azure Kubernetes Service) enabled by Azure Arc**. This gives you a managed Kubernetes experience on your own hardware — Azure handles the cluster lifecycle (upgrades, scaling) while the workloads run locally.

The "enabled by Azure Arc" part means the cluster is registered with Azure and can be managed through the portal, CLI, and Azure APIs — just like a cloud AKS cluster, but running on-prem.

### How is this different from cloud AKS?

| Aspect | AKS (Cloud) | AKS on Azure Local |
|--------|-------------|---------------------|
| Infrastructure | Azure-managed | Your hardware/cluster |
| Networking | Azure VNet, CNI | Physical/VLAN networks |
| Node VMs | Azure VMs | Hyper-V VMs on Azure Local |
| Control plane | Azure-managed (invisible) | Runs locally as management VMs (consumes cluster resources) |
| Cluster management | Azure portal/CLI | Azure portal/CLI (via Arc) |
| Data residency | Azure region | Your datacenter |

---

## Challenge 1: Prepare the AKS Prerequisites

**Goal:** Understand what's needed before deploying AKS and prepare the environment.

AKS on Azure Local requires several things to be in place before you can create a cluster. Your job is to figure out what those are and set them up.

**What you need to figure out:**
1. What network will AKS use? Does it already exist, or do you need to create a logical network for it?
2. What Azure Arc extension enables AKS? Is it already installed on your cluster?
3. AKS on Azure Local uses Azure RBAC gated by Entra ID group membership — do you have a group, or do you need to create one?

<details>
<summary>🔍 Hint 1 — Network</summary>

AKS needs a **dedicated logical network** that is separate from the VM network you created in Exercise 2. In LocalBox, AKS uses:
- **Subnet:** 10.10.0.0/24
- **VLAN:** 110
- **Gateway:** 10.10.0.1
- **DNS:** 192.168.1.254 (the domain controller / Vm-Router)

You need to create this logical network before deploying the AKS cluster. Use the Azure portal just like you did in Exercise 2:

1. Go to your Azure Local cluster resource → **Logical networks** → **+ Create**
2. Name it something descriptive (e.g., `aks-network`)
3. Use **Static** IP allocation
4. Configure the subnet: `10.10.0.0/24`, gateway `10.10.0.1`, DNS server `192.168.1.254`
5. Add an IP pool (e.g., `10.10.0.10` to `10.10.0.200`) for Kubernetes nodes and services
6. Set the VLAN ID to **110**

> ⚠️ **Important:** Double-check all values (especially DNS and gateway) before creating. These settings **cannot be changed after creation** — a mistake means deleting and recreating the logical network.

</details>

<details>
<summary>🔍 Hint 2 — Arc Extension</summary>

Go to the Azure Portal → your Azure Local cluster → **Extensions**. You should see `hybridaksextension` (or `aksarc`) already listed. This extension was deployed automatically as part of the Azure Local cluster setup — you don't need to install it manually.

You can also check from the Custom Location resource: navigate to `jumpstart-cl` → **Enabled resource types** and confirm that Kubernetes-related resource types are available.

</details>

<details>
<summary>🔍 Hint 3 — Entra ID Group</summary>

AKS on Azure Local uses Azure RBAC for cluster access, gated by Entra ID group membership. You need a security group with yourself as a member:

1. Go to [portal.azure.com](https://portal.azure.com) → **Microsoft Entra ID** → **Groups** → **New group**
2. Group type: **Security**
3. Name it (e.g., `AKS Admins`)
4. Add yourself as a **Member**
5. Create the group and copy its **Object ID** — you'll need this when creating the cluster

> **Note:** If your tenant doesn't allow you to create groups, ask your administrator to create one and add you.

</details>

---

## Challenge 2: Deploy an AKS Cluster

**Goal:** Deploy an AKS workload cluster on your Azure Local instance using the Azure portal.

Now that you have the prerequisites in place (logical network, Entra ID group, Arc extension), create the AKS cluster from the Azure portal.

**What you need to figure out:**
- Where in the portal do you create an AKS cluster on Azure Local? (Hint: it's not the regular AKS service)
- What settings are required? (network, node count, node VM size, RBAC group)
- How long does deployment take and how to monitor it?

<details>
<summary>🔍 Hint 1 — Where to create the cluster</summary>

There are two paths:

- **From the Azure Local cluster resource:** Go to your cluster → **Virtual machines and AKS** → **AKS clusters** tab → **+ Create AKS cluster**
- **From the Kubernetes services page:** Go to **Kubernetes services** in the portal → **+ Create** → Select **Azure Kubernetes Service Arc** (not the regular AKS)

Both paths lead to the same creation wizard.

</details>

<details>
<summary>🔍 Hint 2 — Key settings</summary>

In the creation wizard:

- **Basics:**
  - Select your subscription and resource group (`azlocal2`)
  - Cluster name (e.g., `aks-localbox`)
  - Custom location: `jumpstart-cl`
  - Kubernetes version: pick the latest available

- **Node pools:**
  - The default node pool will ask for VM size — start small (e.g., `Standard_A4_v2`, 4 vCPUs, 8 GB)
  - Node count: 1-2 (this is a lab, conserve resources)

- **Networking:**
  - Select the logical network you created in Challenge 1 (e.g., `aks-network`)
  - Leave the pod and service CIDRs at defaults unless they conflict

- **Access:**
  - Authentication: **Microsoft Entra ID with Kubernetes RBAC** (recommended)
  - Admin Group Object IDs: paste the Object ID of the Entra ID group you created

  > **Authentication options explained:**
  > - **Microsoft Entra ID with Kubernetes RBAC** — cluster access is gated by Entra ID group membership. Users authenticate via `az login` and access is controlled through Azure RBAC. This is the enterprise-grade option and integrates with the rest of your Azure identity management.
  > - **Local accounts with Kubernetes RBAC** — uses a certificate-based kubeconfig file. Simpler for quick testing, but bypasses Entra ID entirely (no SSO, no conditional access, no audit trail in Entra).
  >
  > For this exercise, use **Entra ID** so you experience the full Azure-integrated authentication flow. See [AKS Arc access control documentation](https://learn.microsoft.com/azure/aks/aksarc/aks-entra-id-rbac) for details.

</details>

<details>
<summary>⚠️ Spoiler: Full Solution</summary>

1. **Create the logical network** (if not done already):
   - Azure portal → your Azure Local cluster → Logical networks → + Create
   - Name: `aks-network`
   - Static IP allocation
   - Address prefix: `10.10.0.0/24`
   - Gateway: `10.10.0.1`
   - DNS: `192.168.1.254`
   - IP pool: `10.10.0.10` – `10.10.0.200`
   - VLAN: `110`
   - ⚠️ Verify all values before clicking Create — DNS and gateway cannot be changed later!
   - Review + Create

2. **Create the Entra ID group** (if not done already):
   - portal.azure.com → Microsoft Entra ID → Groups → New group
   - Type: Security, Name: `AKS Admins`
   - Add yourself as member → Create
   - Copy the Object ID

3. **Create the AKS cluster:**
   - Azure portal → Kubernetes services → + Create → **Azure Kubernetes Service Arc**
   - Subscription: your subscription
   - Resource group: `azlocal2`
   - Cluster name: `aks-localbox`
   - Custom location: `jumpstart-cl`
   - Kubernetes version: latest available (e.g., 1.28.x or 1.29.x)
   - Node pool: `Standard_A4_v2`, node count: **3** (use 3 nodes if you plan to do Exercise 6 — SQL MI)

   > 💡 **Sizing tip:** If you only plan to run basic workloads (Challenges 4-5), 2 nodes are enough. If you plan to deploy **SQL Managed Instance** (Exercise 6), consider using a larger VM size with **16 GB RAM per node** (e.g., `Standard_D4s_v3`). In the emulated LocalBox environment, `Standard_A4_v2` nodes may only get ~2.5 GB allocatable memory each, which is not enough for the data controller's `controldb` pod (requires 4 GB on a single node).
   - Networking: select `aks-network`
   - Access: Microsoft Entra ID + Kubernetes RBAC
   - Admin Group Object IDs: paste your group's Object ID
   - Review + Create

4. **Monitor deployment:**
   - The deployment takes 15-30 minutes
   - Watch progress in Deployments (resource group → Deployments)
   - When complete, the cluster appears as a **Kubernetes - Azure Arc** resource

> **Alternative — Script method:** If you prefer CLI, LocalBox-Client has `C:\LocalBox\Configure-AksWorkloadCluster.ps1`. Edit the `$aadgroupID` variable (around line 6) with your group's Object ID, then run it in VS Code. The script automates all the steps above.

</details>

---

## Challenge 3: Connect to Your AKS Cluster

**Goal:** Get `kubectl` access to your AKS cluster running on Azure Local.

This is where it gets interesting. Unlike cloud AKS where you just run `az aks get-credentials`, AKS on Azure Local uses a **proxy connection through Azure Arc**. You don't need direct network connectivity to the Kubernetes API server — the connection is tunneled through Azure.

> **Where to run commands:** You can run `az` and `kubectl` from **any machine with Azure CLI and internet access** — your local laptop, LocalBox-Client, or any other workstation. The Arc proxy (`az connectedk8s proxy`) establishes a tunnel through Azure, so you don't need direct network connectivity to the AKS control plane network (10.10.0.0/24). This is one of the key benefits of Arc-enabled Kubernetes — management works from anywhere with Azure connectivity, not just from machines inside the datacenter.
>
> LocalBox-Client already has Azure CLI and kubectl pre-installed, so it's the easiest option for this lab. If running from your own machine, ensure you have `kubectl` installed (`az aks install-cli`).

**What you need to figure out:**
- How to authenticate (which Azure CLI identity to use?)
- How to establish the proxy connection
- How to verify the cluster is operational

<details>
<summary>🔍 Hint 1 — Authentication</summary>

You need to log in with a user account that's a member of the Entra ID group you configured. From LocalBox-Client's VS Code terminal:

```powershell
az logout
az login --use-device-code --tenant $env:tenantId
```

Use `--use-device-code` so you can authenticate in a browser on your local machine (useful if Conditional Access policies require a compliant device).

</details>

<details>
<summary>🔍 Hint 2 — Proxy Connection</summary>

Arc-enabled Kubernetes uses a proxy to tunnel kubectl traffic through Azure:

```powershell
az connectedk8s proxy -n localbox-aks -g $env:resourceGroup
```

This runs in the foreground. Open a **second terminal** (click `+` in VS Code) to run kubectl commands.

</details>

<details>
<summary>⚠️ Spoiler: Full Solution</summary>

1. On LocalBox-Client, open VS Code terminal
2. Authenticate:
   ```powershell
   az logout
   az login --use-device-code --tenant $env:tenantId
   ```
3. Start the proxy (keep this running):
   ```powershell
   az connectedk8s proxy -n localbox-aks -g $env:resourceGroup
   ```
4. Open a new terminal tab (`+` button)
5. Test kubectl:
   ```powershell
   kubectl get nodes
   kubectl get namespaces
   kubectl get pods -A
   ```

You should see the AKS nodes and system pods running. The cluster is fully operational!

</details>

---

## Challenge 4: Deploy a Workload with an External Load Balancer

**Goal:** Deploy a web application and expose it externally using a LoadBalancer service — just like you would in the cloud.

In cloud AKS, creating a `Service` of type `LoadBalancer` automatically provisions an Azure Load Balancer with a public IP. But on-premises there's no cloud infrastructure to allocate IPs. How do you get the same experience on Azure Local?

**What you need to figure out:**
- What component provides LoadBalancer functionality on-prem?
- How do you install and configure it on your AKS cluster?
- What IP range should it use? (Think about which network your AKS nodes are on)

> ⚠️ **Do NOT install MetalLB via the Azure Portal (Arc Extensions).** The Arc extension for MetalLB may fail with a service principal error (`Resource '' does not exist`) in lab/emulated environments. Instead, install MetalLB directly using its upstream Kubernetes manifests as shown below — the functionality is identical.

<details>
<summary>🔍 Hint 1 — The component you need</summary>

**MetalLB** is the standard solution for bare-metal/on-prem LoadBalancer services. It assigns real IPs from a pool you define and announces them via L2 (ARP) or BGP so they're reachable on the local network.

You need to:
1. Install MetalLB on your cluster
2. Configure an IP address pool (from the VLAN 110 subnet: `10.10.0.x`)
3. Create an L2 advertisement so the IPs are reachable

</details>

<details>
<summary>🔍 Hint 2 — Installation</summary>

Install MetalLB using its official manifests:

```powershell
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
```

Wait for the pods to be ready:
```powershell
kubectl get pods -n metallb-system -w
```

</details>

<details>
<summary>🔍 Hint 3 — Configuration</summary>

Create a file `metallb-config.yaml` with an IP pool from VLAN 110 (pick IPs not used by other resources — the AKS control plane uses 10.10.0.5 and nodes get DHCP addresses from this range too, so use a small range at the high end):

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: aks-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.10.0.100-10.10.0.120
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advert
  namespace: metallb-system
spec: {}
```

Apply it:
```powershell
kubectl apply -f metallb-config.yaml
```

</details>

<details>
<summary>⚠️ Spoiler: Full Solution</summary>

1. **Install MetalLB:**
   ```powershell
   kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
   kubectl wait --namespace metallb-system --for=condition=ready pod --selector=app=metallb --timeout=120s
   ```

2. **Configure IP pool** — save as `metallb-config.yaml`:
   ```yaml
   apiVersion: metallb.io/v1beta1
   kind: IPAddressPool
   metadata:
     name: aks-pool
     namespace: metallb-system
   spec:
     addresses:
     - 10.10.0.100-10.10.0.120
   ---
   apiVersion: metallb.io/v1beta1
   kind: L2Advertisement
   metadata:
     name: l2-advert
     namespace: metallb-system
   spec: {}
   ```
   ```powershell
   kubectl apply -f metallb-config.yaml
   ```

3. **Deploy nginx and expose via LoadBalancer:**
   ```powershell
   kubectl create deployment nginx --image=nginx --replicas=2
   kubectl expose deployment nginx --port=80 --type=LoadBalancer
   ```

4. **Verify it gets an external IP:**
   ```powershell
   kubectl get svc nginx -w
   ```
   Wait until `EXTERNAL-IP` shows an address like `10.10.0.100` (no longer `<pending>`).

5. **Test access from LocalBox-Client:**
   Open a browser or use `curl http://10.10.0.100` — you should see the nginx welcome page.

> **Note:** If you can't reach the IP from LocalBox-Client, it may be a routing issue — traffic from LocalBox-Client (192.168.1.x) to 10.10.0.x needs to go through the VM-Router. Verify the route exists: `route print` on LocalBox-Client should show 10.10.0.0/24 via 192.168.1.1.

</details>

> **💡 Key takeaway:** On-prem Kubernetes requires you to bring your own LoadBalancer implementation. MetalLB fills this gap by managing IP allocation and L2/BGP advertisement. This is one of the fundamental differences between cloud-managed and on-prem Kubernetes — in the cloud this is invisible infrastructure, on-prem you own it.

**Bonus — Cross-VLAN connectivity test:** If you still have the Linux VM from Exercise 2 running (on VLAN 200, subnet 10.20.0.x), try reaching the nginx LoadBalancer IP from it:

```bash
curl http://10.10.0.100
```

If this works, it proves that the VM-Router is correctly routing traffic between VLAN 200 (your VMs) and VLAN 110 (AKS). If it doesn't, revisit the VM-Router routing configuration — this is a common real-world troubleshooting scenario in segmented on-prem networks.

---

## Challenge 5: Explore Arc-Enabled Kubernetes in the Portal

**Goal:** Discover what Azure management features are available for your on-prem Kubernetes cluster through the Azure Portal.

Go to the `localbox-aks` resource in the portal and explore every blade.

**Questions to answer:**
- Can you see the Kubernetes workloads (pods, deployments) in the portal?
- What monitoring is available?
- Can you deploy workloads from the portal?
- What GitOps features are available?

<details>
<summary>⚠️ Spoiler: What to Look For</summary>

In the Azure Portal, your Arc-enabled AKS cluster shows:

- **Kubernetes resources** → Workloads: See pods, deployments, replica sets directly in the portal
- **Kubernetes resources** → Services: See services and ingresses
- **Settings** → Extensions: Azure Arc extensions installed on the cluster
- **Settings** → GitOps: Deploy configurations from Git repositories
- **Settings** → Policies: Apply Azure Policy to enforce Kubernetes configurations
- **Monitoring** → Insights: Container monitoring (if Container Insights is enabled)

This is the "single pane of glass" promise: manage cloud AKS and on-prem AKS from the same portal.

</details>

## Reflection Questions

1. **What's the value of running Kubernetes on-prem vs. just using cloud AKS?** Think about data sovereignty, latency, disconnected scenarios, and cost.

2. **The proxy connection (`az connectedk8s proxy`) tunnels through Azure Arc. What are the security implications?** Who can access the cluster? What if Azure connectivity is lost?

3. **How would GitOps change the way you deploy to this cluster?** Instead of `kubectl apply`, what would the workflow look like?

4. **Could you run the same container workloads on both cloud AKS and AKS on Azure Local?** What would you need to ensure portability?

## Cleanup

If you're done with the AKS exercises, clean up:
```powershell
kubectl delete deployment nginx
kubectl delete svc nginx
```

## Next Exercise

➡️ [Exercise 4: Monitoring & Observability](./04-monitoring-observability.md)
