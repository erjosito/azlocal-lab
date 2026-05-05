# Exercise 9 (Optional): Challenge — Hybrid Operations

## Overview

This is an **optional open challenge**. Unlike previous exercises, you'll receive minimal guidance. The goal is to apply everything you've learned across the earlier exercises to solve realistic operational scenarios.

Each scenario is independent — pick the ones that interest you or try them all.

---

## Scenario A: "The Monday Morning Dashboard"

### The Situation

Your manager asks you to build a single dashboard that shows the health of your entire hybrid environment at a glance. She wants to open it every Monday morning and immediately know:

- Are all Azure Local nodes healthy and connected?
- Are there any VMs or AKS pods in trouble?
- Is storage running low?
- Were there any security incidents over the weekend?

### Your Challenge

Build an Azure Dashboard or Workbook that answers all four questions using data from your LocalBox environment. It should work without clicking into individual resources.

### Success Criteria

- [ ] Dashboard loads in the Azure Portal
- [ ] Shows cluster node status (online/offline)
- [ ] Shows VM health summary
- [ ] Shows storage utilization
- [ ] Shows recent security alerts or warnings
- [ ] Can be shared with your team via a URL

<details>
<summary>🔍 Approach Hint</summary>

You have several options:
1. **Azure Dashboard** — Pin tiles from various resources to a shared dashboard
2. **Azure Workbook** — Build a custom workbook with KQL queries
3. **Azure Monitor Insights** — Start from the built-in Insights workbook and customize

The Workbook approach gives you the most flexibility. Start with the cluster Insights workbook as a base and add sections for VMs, AKS, and security.

Key KQL tables to query:
- `Perf` — Performance counters
- `Event` — Windows event logs
- `SecurityEvent` — Security audit events
- `ContainerInsights` — AKS metrics (if enabled)

</details>

---

## Scenario B: "The New Branch Office"

### The Situation

Your company is opening a new branch office that needs:
- 5 Windows Server VMs for line-of-business applications
- A 3-node AKS cluster for containerized microservices
- All resources must comply with corporate security policies
- Monitoring must be centralized with the existing Azure Monitor setup

### Your Challenge

Write a **deployment plan** (not code, a plan) that describes:
1. What Azure Local networking configuration is needed (subnets, VLANs, IP ranges)?
2. How many IPs do you need and how would you allocate them?
3. What VM images and sizes would you use?
4. What policies would you pre-assign before deploying any workloads?
5. What monitoring configuration is needed?

Then implement as much of it as you can in your LocalBox environment.

### Success Criteria

- [ ] Written deployment plan with IP addressing scheme
- [ ] At least 2 VMs deployed following your plan
- [ ] At least 1 policy assigned proactively
- [ ] Monitoring configured for new resources

<details>
<summary>🔍 Approach Hint</summary>

**IP Planning example:**
- VM subnet: 192.168.200.0/24 (254 usable IPs)
  - Static IPs for servers: .10-.50
  - DHCP range for workstations: .100-.200
  - Reserved: .1 (gateway), .254 (DNS)
- AKS subnet: 10.10.0.0/24
  - Node IPs: .10-.20
  - Service IPs: handled by AKS CNI

**Policy-first approach:** Assign policies BEFORE deploying VMs, so any non-compliant deployments are caught immediately. This is the "shift left" governance model.

</details>

---

## Scenario C: "The Disconnected Cluster"

### The Situation

Your Azure Local cluster has lost connectivity to Azure (simulated: imagine the internet connection at your branch office went down). Users report they can't manage VMs through the Azure Portal.

### Your Challenge

Investigate and answer:
1. **What still works?** Can existing VMs keep running? Can users access their applications?
2. **What breaks?** What management operations are unavailable?
3. **How would you manage the cluster during the outage?** What local tools exist?
4. **When connectivity is restored, what happens?** Does everything auto-recover?

> ⚠️ **Don't actually disconnect anything!** This is a thought exercise combined with documentation research.

### Success Criteria

- [ ] Written analysis of which features work offline vs. online
- [ ] Identified at least 2 local management tools that work without Azure
- [ ] Described the recovery process when connectivity returns

<details>
<summary>🔍 Approach Hint</summary>

Research these topics:
- Azure Local disconnected operation capabilities
- Windows Admin Center for local management
- Failover Cluster Manager
- Azure Arc agent reconnection behavior

Key insight: Azure Local is designed for **resilient operation**. The data plane (running workloads) is independent of the management plane (Azure connectivity). This is a fundamental architectural decision.

Things that keep working:
- Running VMs continue running
- Storage Spaces Direct continues replicating
- Cluster failover still works
- Local Hyper-V management works

Things that stop:
- Azure Portal management
- New VM deployments through Arc
- Policy evaluation and compliance reporting
- Monitoring data ingestion to Azure

</details>

---

## Scenario D: "Cost Optimization Review"

### The Situation

The finance team is asking why the Azure Local lab costs so much. They want you to:
1. Provide a detailed cost breakdown
2. Identify specific cost reduction opportunities
3. Implement at least one optimization

### Your Challenge

1. Run the cost estimation script: `./scripts/estimate-cost.sh`
2. Check actual costs in Azure Portal (Cost Management)
3. Identify the top 3 cost drivers
4. Implement at least one cost reduction (without breaking the lab)

### Success Criteria

- [ ] Cost breakdown documented
- [ ] Top 3 cost drivers identified
- [ ] At least one optimization implemented
- [ ] Estimated savings calculated

<details>
<summary>🔍 Approach Hint</summary>

Common cost optimizations for LocalBox:
1. **Spot pricing** — Redeploy with `enableAzureSpotPricing = true` (risk: eviction)
2. **Auto-shutdown** — Use `./scripts/stop-environment.sh` on a schedule
3. **Right-size Log Analytics** — Reduce data retention period
4. **Reserved Instances** — If keeping the lab long-term, RI saves 30-60%
5. **Region optimization** — Some regions are cheaper than others

Check actual spend:
- Azure Portal → **Cost Management** → **Cost analysis** → Filter by resource group
- Group by "Resource" to see which resources cost the most

The E32s_v6 VM is almost always the biggest cost driver (80%+ of total).

</details>

---

## Scenario E: "Upgrade and Patch"

### The Situation

A new Azure Local update has been released with critical security fixes. You need to evaluate whether to apply it and understand the update process.

### Your Challenge

1. Check if updates are available for your Azure Local cluster
2. Understand the update process (what happens during an update?)
3. If updates are available, evaluate whether to apply them
4. Document the rollback plan if something goes wrong

### Success Criteria

- [ ] Checked current version and available updates
- [ ] Documented the update process and what to expect
- [ ] Made and documented a go/no-go decision
- [ ] Documented the rollback strategy

<details>
<summary>🔍 Approach Hint</summary>

Navigate to: Cluster resource → **Settings** → **Updates**

Key things to check:
- Current version vs. available version
- Update release notes (what's fixed/changed)
- Whether the update requires a reboot
- Estimated update duration

Azure Local updates are **cluster-aware**: they update one node at a time, migrating workloads to the other node first. This means **zero downtime for workloads** in a properly configured cluster.

Resources:
- [Azure Local update overview](https://learn.microsoft.com/azure/azure-local/update/about-updates-23h2)
- Cluster → Updates blade in the portal

</details>

---

## Final Reflection

You've now explored the core operational capabilities of Azure Local through hands-on exercises. Take a step back and think about:

1. **When would you recommend Azure Local over pure cloud?** What workloads and requirements make it the right choice?

2. **What surprised you most about the Azure Local management experience?** Was it more or less integrated with Azure than you expected?

3. **If you had to design a hybrid architecture for a retail company with 100 stores, how would Azure Local fit in?** Think about what runs centrally in Azure vs. locally in each store.

4. **What would you want to learn next?** Here are some directions:
   - Azure Local stretched clusters (multi-site)
   - Azure Stack Edge (edge computing)
   - Azure Arc-enabled data services (SQL Managed Instance on-prem)
   - GitOps for hybrid Kubernetes management

## Next Exercise

➡️ [Exercise 7: SQL Managed Instance on Azure Local](./07-sql-managed-instance.md)

---

## Cleanup

When you're done with the entire lab:

```bash
./scripts/cleanup.sh --resource-group <your-resource-group>
```

This permanently deletes all resources. Make sure you've saved any work or notes first!
