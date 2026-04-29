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
- An Entra ID group you're a member of (or ability to create one)

## Context

One of the most powerful features of Azure Local is running **AKS (Azure Kubernetes Service) enabled by Azure Arc**. This gives you a managed Kubernetes experience on your own hardware — Azure handles the cluster lifecycle (upgrades, scaling) while the workloads run locally.

The "enabled by Azure Arc" part means the cluster is registered with Azure and can be managed through the portal, CLI, and Azure APIs — just like a cloud AKS cluster, but running on-prem.

### How is this different from cloud AKS?

| Aspect | AKS (Cloud) | AKS on Azure Local |
|--------|-------------|---------------------|
| Infrastructure | Azure-managed | Your hardware/cluster |
| Networking | Azure VNet, CNI | Physical/VLAN networks |
| Node VMs | Azure VMs | Hyper-V VMs on Azure Local |
| Control plane | Azure-managed | Runs locally, connected via Arc |
| Cluster management | Azure portal/CLI | Azure portal/CLI (via Arc) |
| Data residency | Azure region | Your datacenter |

---

## Challenge 1: Prepare the AKS Prerequisites

**Goal:** Understand what's needed before deploying AKS and prepare the environment.

**What you need to figure out:**
1. What network will AKS use? (Hint: it's different from the VM network in Exercise 2)
2. What Azure Arc extension enables AKS? Is it already installed?
3. You need an Entra ID group for RBAC — do you have one or need to create one?

<details>
<summary>🔍 Hint 1 — Network</summary>

AKS uses a dedicated network: **10.10.0.0/24 on VLAN 110**. This is separate from the VM network (192.168.200.0/24 on VLAN 200). The separation prevents AKS internal traffic from interfering with VM traffic.

</details>

<details>
<summary>🔍 Hint 2 — Arc Extension</summary>

Go to the Azure Portal → Custom Location `jumpstart` → Arc-enabled services. You should see `hybridaksextension` already listed. This extension was deployed as part of the Azure Local cluster setup.

</details>

<details>
<summary>🔍 Hint 3 — Entra ID Group</summary>

AKS on Azure Local uses Azure RBAC for cluster access, gated by Entra ID group membership. Create a group in the Entra ID portal (portal.azure.com → Microsoft Entra ID → Groups → New group) and add yourself as a member. Copy the group's Object ID — you'll need it.

</details>

---

## Challenge 2: Deploy an AKS Cluster

**Goal:** Deploy an AKS workload cluster on your Azure Local instance.

**What you need to figure out:**
- Where is the deployment script on LocalBox-Client?
- What parameter needs to be configured before running it?
- How to monitor the deployment progress

<details>
<summary>🔍 Hint 1</summary>

On LocalBox-Client, look in `C:\LocalBox` for `Configure-AksWorkloadCluster.ps1`. Open it in VS Code before running it — there's a parameter you need to uncomment and set.

</details>

<details>
<summary>🔍 Hint 2</summary>

The script has a commented-out line (around line 6) for `$aadgroupID`. Uncomment it and paste in the Object ID of your Entra ID group.

</details>

<details>
<summary>⚠️ Spoiler: Full Solution</summary>

1. RDP into LocalBox-Client
2. Open `C:\LocalBox\Configure-AksWorkloadCluster.ps1` in VS Code
3. Find the commented line: `# $aadgroupID = "<your-entra-group-object-id>"`
4. Uncomment it and replace the placeholder with your group's Object ID
5. Save (Ctrl+S)
6. Click the Run button in VS Code (▶️)
7. Wait for completion — look for `"currentState": "Succeeded"`
8. Verify in Azure Portal: a new resource `localbox-aks` appears in your resource group

The script creates:
- A virtual network resource for AKS (mapping to the 10.10.0.0/24 subnet)
- An AKS cluster with Arc connectivity
- RBAC configuration tied to your Entra ID group

</details>

---

## Challenge 3: Connect to Your AKS Cluster

**Goal:** Get `kubectl` access to your AKS cluster running on Azure Local.

This is where it gets interesting. Unlike cloud AKS where you just run `az aks get-credentials`, AKS on Azure Local uses a **proxy connection through Azure Arc**.

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

## Challenge 4: Deploy a Workload

**Goal:** Deploy a simple web application to your AKS cluster and access it.

Deploy a basic nginx deployment with a service. Then figure out how to access it from LocalBox-Client.

<details>
<summary>🔍 Hint</summary>

```powershell
kubectl create deployment nginx --image=nginx --replicas=2
kubectl expose deployment nginx --port=80 --type=ClusterIP
kubectl get pods
kubectl get svc
```

Since there's no external load balancer in this lab, use `kubectl port-forward` to access the service:
```powershell
kubectl port-forward svc/nginx 8080:80
```

Then open `http://localhost:8080` in a browser on LocalBox-Client.

</details>

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
