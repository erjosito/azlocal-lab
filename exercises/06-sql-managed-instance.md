# Exercise 6: SQL Managed Instance on Azure Local

## What You'll Learn

By the end of this exercise, you will understand:

- What Azure Arc-enabled data services are and why they matter in hybrid environments
- Why SQL Managed Instance enabled by Azure Arc is a good fit for on-premises and edge scenarios
- How the Azure Arc data controller acts as the management plane for Arc-enabled data services
- How to deploy a data controller and a SQL Managed Instance on AKS running on Azure Local
- How to connect to the instance, run queries, and monitor it from Azure
- What scaling and high availability mean for Arc-enabled SQL Managed Instance

## Prerequisites

- Completed Exercises 0-3
- Exercise 3 completed **or** another working AKS cluster on Azure Local
- LocalBox deployment running and healthy
- Access to the Azure Portal and the `LocalBox-Client` VM
- Basic familiarity with Kubernetes and SQL Server concepts

> ⚠️ **Cluster sizing:** SQL Managed Instance requires at least **4 vCPUs and 16 GB RAM available** on your Kubernetes cluster (each node must have ≥ 8 GB RAM and 4 cores). If you deployed with only 2 `Standard_A4_v2` nodes (8 GB each = 16 GB total), system pods will consume enough that SQL MI cannot schedule.
>
> **To scale out your node pool** (from 2 → 3 nodes):
> - Azure Portal → your AKS cluster → **Node pools** → select the pool → **Scale node pool** → set count to 3
> - Or via CLI:
>   ```bash
>   az aksarc nodepool update --cluster-name localbox-aks -g azlocal2 --name nodepool1 --node-count 3
>   ```

## Context

Azure Arc-enabled data services bring Azure data platform capabilities to infrastructure that you own. Instead of moving every database into a public Azure region, you can run **SQL Managed Instance enabled by Azure Arc** on Kubernetes in your own datacenter while still using Azure for inventory, governance, monitoring, and lifecycle operations.

In the LocalBox lab, that Kubernetes platform is typically **AKS on Azure Local**. That means the stack looks like this:

```text
Azure Portal / Azure Resource Manager
        |
        v
Azure Arc-enabled Kubernetes
        |
        v
Azure Arc Data Controller (control plane on the cluster)
        |
        v
SQL Managed Instance pods + data storage on AKS on Azure Local
        |
        v
Azure Local compute, storage, and networking
```

This model is useful when you need:

- **Data sovereignty** or regulatory control
- **Low latency** to local applications or factory systems
- **Consistent operations** across cloud and on-premises
- **A modernization path** for SQL workloads without fully relocating them to Azure

References for this exercise:

- [Jumpstart LocalBox SQL MI walkthrough](https://preview.jumpstart.azure.com/azure_jumpstart_localbox/SQLMI)
- [What are Azure Arc-enabled data services?](https://learn.microsoft.com/en-us/azure/azure-arc/data/overview)
- [SQL Managed Instance enabled by Azure Arc overview](https://learn.microsoft.com/en-us/azure/azure-arc/data/managed-instance-overview)

---

## Challenge 1: Understand the Architecture

**Goal:** Build a mental model of where SQL Managed Instance actually runs and what Azure Arc contributes.

**Questions to answer:**

1. What are Azure Arc-enabled data services?
2. Why would you run SQL Managed Instance on-premises instead of in Azure SQL Managed Instance in a region?
3. What does the **data controller** do?
4. Why does Kubernetes sit underneath the service?

<details>
<summary>💡 Hint</summary>

Focus on the split between **control plane** and **data plane**:

- The database engine and data files run locally on Kubernetes.
- Azure provides inventory, management APIs, portal experience, policy, and monitoring integration.
- The data controller is the orchestrator for provisioning, updates, monitoring hooks, and lifecycle management.

</details>

<details>
<summary>🔓 Solution</summary>

**Azure Arc-enabled data services** are Azure data services that run on Kubernetes outside Azure regions. Today, SQL Managed Instance enabled by Azure Arc is the main service used in this model.

**Why run it on Azure Local?**

- Keep data near the workloads that use it
- Meet residency or disconnected-operation requirements
- Reuse existing datacenter investments
- Get cloud-style management without moving the workload fully to Azure

**What the data controller does:**

The data controller is the management brain running as a set of pods inside the Kubernetes cluster. It handles:

- Provisioning and deleting Arc-enabled data services
- Coordinating updates
- Exposing telemetry and inventory to Azure
- Managing operational workflows such as scaling and backup-related orchestration

**Why Kubernetes matters:**

Kubernetes provides the scheduling, storage abstraction, health model, and scaling foundation. Arc-enabled SQL MI is packaged as containers, so Kubernetes is what actually keeps the service running on your infrastructure.

**Key insight:** Azure Arc does not magically turn Azure Local into a public Azure region. Instead, it gives your local Kubernetes environment an Azure management surface.

</details>

---

## Challenge 2: Prepare the Platform

**Goal:** Verify that your Azure Local environment has everything required before you attempt to deploy SQL MI.

**What you need to figure out:**

- Do you already have an AKS on Azure Local cluster from Exercise 3?
- Is that cluster Arc-enabled and visible in Azure?
- Do you have a custom location available for Arc-enabled services?
- Will you use **directly connected** mode?

<details>
<summary>💡 Hint</summary>

Look for these Azure resources:

- Your **AKS cluster** on Azure Local
- The **Arc-enabled Kubernetes** resource that represents it
- A **custom location** (the Jumpstart lab often uses `jumpstart`)

If you do not yet have AKS, go back to [Exercise 3](./03-aks-on-azure-local.md) and deploy it first.

</details>

<details>
<summary>🔓 Solution</summary>

For a LocalBox deployment, the easiest path is:

1. Reuse the AKS cluster you deployed in Exercise 3
2. Confirm it appears in the Azure Portal as an Arc-enabled Kubernetes cluster
3. Confirm a **custom location** exists for the cluster
4. Use **directly connected mode** so Azure Portal, Azure Monitor, and Azure Resource Manager experiences work end to end

Why directly connected mode?

- It gives you the richest Azure integration
- Monitoring and management happen through familiar Azure interfaces
- It is the closest experience to a managed Azure service, while still running on-premises

If your lab is missing AKS, deploy it first. SQL MI enabled by Azure Arc runs **on Kubernetes**, not directly on the Azure Local hosts.

</details>

---

## Challenge 3: Deploy the Azure Arc Data Controller

**Goal:** Deploy the control plane that all Arc-enabled data services depend on.

The data controller is a prerequisite. Without it, there is nowhere for Azure Arc-enabled SQL MI to register and no service layer to orchestrate it.

**What you need to figure out:**

- Where in the Azure Portal do you create the data controller?
- Which Kubernetes cluster / custom location should you target?
- Which namespace should host the data services?
- What information will you need during the wizard?

<details>
<summary>💡 Hint</summary>

Start from one of these entry points:

- The **Arc-enabled Kubernetes** cluster resource
- The **Custom location** resource
- Search the portal for **Azure Arc data controllers**

You are looking for a wizard that targets your Arc-enabled Kubernetes cluster in **directly connected** mode.

</details>

<details>
<summary>🔓 Solution</summary>

A typical deployment flow is:

1. In the Azure Portal, open your Arc-enabled AKS cluster or custom location
2. Find the option to deploy **Azure Arc-enabled data services**
3. Choose **Create data controller**
4. Select your subscription, resource group, and custom location
5. Use **directly connected** mode
6. Choose or create a Kubernetes namespace such as `arc`
7. Use the recommended storage classes and defaults provided by the wizard for the lab
8. Review and create

After deployment, verify:

- A new **Azure Arc Data Controller** resource appears in Azure
- Pods are running in the selected namespace
- The controller reaches a healthy / ready state

Why this matters:

The data controller is what translates Azure operations into Kubernetes-native orchestration. Think of it as the bridge between Azure Resource Manager and the SQL MI pods running locally.

</details>

---

## Challenge 4: Create a SQL Managed Instance

**Goal:** Deploy your first Arc-enabled SQL Managed Instance on AKS on Azure Local.

**What you need to decide:**

- Instance name
- Admin credentials
- Service tier / sizing appropriate for a lab
- Storage size
- Whether you are optimizing for minimal lab footprint or more realistic HA capacity

<details>
<summary>💡 Hint</summary>

For a lab, start small and simple:

- Use a clear name such as `localbox-sqlmi`
- Pick the smallest supported sizing that fits your available capacity
- Use a strong SQL admin login and password
- Read every sizing choice as both a SQL decision **and** a Kubernetes capacity decision

</details>

<details>
<summary>🔓 Solution</summary>

From the Azure Portal:

1. Open the **Azure Arc Data Controller** resource
2. Choose **Create SQL Managed Instance**
3. Enter an instance name such as `localbox-sqlmi`
4. Configure SQL admin credentials
5. Select a lab-friendly compute and storage size
6. Review and create

During deployment, remember what is happening underneath:

- Azure creates a SQL MI resource in Azure Resource Manager
- The data controller creates the necessary Kubernetes resources and pods
- Kubernetes schedules those pods onto the AKS nodes running on Azure Local
- Persistent storage is attached through the Kubernetes storage layer

**Important concept:** when you size SQL MI enabled by Azure Arc, you are really allocating cluster resources. If the Kubernetes cluster is too small or oversubscribed, database deployment and HA options will be constrained.

</details>

---

## Challenge 5: Connect and Run Queries

**Goal:** Treat the new SQL Managed Instance like a real database platform, not just a deployed resource.

**Tasks:**

1. Find the connection endpoint in the Azure Portal
2. Connect using a SQL tool from `LocalBox-Client`
3. Run a few validation queries
4. Confirm that the instance behaves like SQL Server / SQL Managed Instance

<details>
<summary>💡 Hint</summary>

Possible tools:

- `sqlcmd`
- SQL Server Management Studio
- Azure Data Studio / VS Code with the MSSQL extension

Good first queries:

```sql
SELECT @@VERSION;
SELECT name FROM sys.databases;
SELECT SYSDATETIMEOFFSET() AS current_time;
```

</details>

<details>
<summary>🔓 Solution</summary>

1. Open your SQL Managed Instance resource in the Azure Portal
2. Find the connection details on the overview or connection strings area
3. From `LocalBox-Client`, connect with your preferred tool using the SQL admin credentials you created
4. Run:

```sql
SELECT @@VERSION;
SELECT name FROM sys.databases;
SELECT SERVERPROPERTY('Edition') AS edition;
SELECT SYSDATETIMEOFFSET() AS current_time;
```

What you are validating:

- The instance is reachable from a client
- Authentication works
- The SQL engine is running correctly
- You can now treat this as a platform for line-of-business databases running on-premises

**Why this matters:** a successful deployment is not the same as an operational service. Real validation means connecting, querying, and proving the database is usable.

</details>

---

## Challenge 6: Explore Monitoring, Scaling, and HA Concepts

**Goal:** Understand how this service is operated after deployment.

**Questions to answer:**

- What does Azure show you about the instance in the portal?
- What metrics or health views can you use to monitor it?
- How would you scale it if demand grows?
- What does high availability depend on in an Azure Local + Kubernetes design?

<details>
<summary>💡 Hint</summary>

Explore these areas:

- SQL Managed Instance resource → **Overview** and **Monitoring**
- Data controller resource → status and managed instances
- Kubernetes view → pods, namespace, and node placement

Think in layers:

1. SQL layer
2. Data controller layer
3. Kubernetes layer
4. Azure Local infrastructure layer

</details>

<details>
<summary>🔓 Solution</summary>

In Azure, you should be able to observe:

- The SQL MI resource state
- Basic inventory and monitoring integration
- The data controller managing the service
- Underlying Kubernetes health if you inspect the cluster directly

**Scaling concepts:**

- You can scale compute and storage within the limits of the Kubernetes cluster capacity
- Scaling is not only a database decision; it also depends on available CPU, memory, storage, and node count in AKS on Azure Local

**High availability concepts:**

- HA depends on both the SQL MI service design and the resiliency of the Kubernetes platform underneath it
- Kubernetes needs enough worker capacity to place replicas where required
- Azure Local storage and host resiliency still matter because the Kubernetes nodes ultimately run on that infrastructure

**Key operational idea:** If Azure Portal shows the resource as healthy but the Kubernetes layer is unhealthy, the database experience will still degrade. Hybrid operations always require thinking across multiple control planes.

</details>

---

## Reflection Questions

1. **What is the biggest operational trade-off between Azure SQL Managed Instance in Azure and SQL Managed Instance enabled by Azure Arc on Azure Local?**
2. **If a local factory application requires sub-10 ms latency to the database, why might Azure Local be a better fit than a regional PaaS database?**
3. **What happens to your management experience if Azure connectivity is interrupted but the AKS cluster and local storage remain healthy?**
4. **How would you justify the extra Kubernetes complexity to a team that only thinks in terms of VMs and SQL Servers?**

## Key Takeaways

- SQL Managed Instance enabled by Azure Arc brings Azure data services to your own Kubernetes platform
- On Azure Local, AKS provides the runtime foundation and Azure Arc provides the management plane
- The data controller is central: it orchestrates lifecycle, telemetry, and service management
- Deploying the service is only the start; connecting, validating, monitoring, and understanding HA are what make it operational
- Hybrid data platforms require you to think across Azure, Kubernetes, and local infrastructure at the same time

## Next Exercise

➡️ [Exercise 8: Azure SRE Agent for Azure Local Operations](./08-sre-agent.md)
