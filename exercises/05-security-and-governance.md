# Exercise 5: Security & Governance

## Learning Objectives

By the end of this exercise, you will understand:

- How Azure Policy extends governance to hybrid and on-premises resources
- The role of Microsoft Defender for Cloud in securing Azure Local
- RBAC models for Azure Local cluster management
- How to audit and enforce compliance across hybrid infrastructure

## Prerequisites

- Completed Exercises 0-1
- LocalBox cluster operational
- Basic understanding of Azure Policy concepts (assignments, definitions, compliance)

## Context

One of the biggest operational challenges with hybrid infrastructure is maintaining consistent security and governance. When you have resources in Azure AND on-premises, how do you ensure the same security standards apply everywhere?

Azure Arc solves this by making on-premises resources (servers, Kubernetes clusters) visible to Azure governance tools. This means Azure Policy, Microsoft Defender for Cloud, and Azure RBAC all work the same way, regardless of where the resource runs.

---

## Challenge 1: Audit Arc-Enabled Resources with Azure Policy

**Goal:** Discover what Azure Policy assignments already apply to your Arc-enabled resources, and then create a new policy that audits a specific configuration.

**What you need to figure out:**
- Are there any policy assignments already applied to your resource group or subscription?
- What built-in policies exist specifically for Arc-enabled servers?
- How do you assign a policy and check compliance?

<details>
<summary>🔍 Hint 1 — Finding Existing Policies</summary>

Azure Portal → **Policy** → **Compliance**. Filter by your resource group. You may see some inherited policies from the subscription level.

Also check: Resource group → one of the Arc-enabled servers → **Policies** blade.

</details>

<details>
<summary>🔍 Hint 2 — Arc-Specific Policies</summary>

In Azure Policy → **Definitions**, search for:
- "Arc" to find Arc-specific policies
- "Guest Configuration" to find policies that audit OS-level settings
- "Azure Local" for cluster-specific policies

Try assigning one of these built-in policies:
- *"Audit Windows machines that have extra accounts in the Administrators group"*
- *"Azure Local servers should meet Secured-core requirements"*

</details>

<details>
<summary>⚠️ Spoiler: Assigning a Policy</summary>

1. Azure Portal → **Policy** → **Assignments** → **Assign Policy**
2. **Scope**: Select your resource group
3. **Policy definition**: Search for "Azure Local" or "Arc" and pick one, e.g.:
   - *"Azure Local servers should meet Secured-core requirements"*
   - Or a Guest Configuration policy like *"Audit Windows machines that do not have the specified Windows PowerShell execution policy"*
4. **Parameters**: Configure as needed (some policies require parameters)
5. **Remediation**: Check "Create a remediation task" if the policy supports it
6. **Review + create**

Wait 15-30 minutes for the compliance scan, then check the Compliance blade.

**Key insight:** The same policy engine that enforces standards on Azure VMs can audit and enforce standards on your on-prem servers through Arc. No separate governance tooling needed.

</details>

---

## Challenge 2: Explore Microsoft Defender for Cloud

**Goal:** Understand how Microsoft Defender for Cloud provides security posture management for your hybrid environment.

**Questions to answer:**
- Is Defender for Cloud enabled for your subscription?
- What security recommendations does it have for your Azure Local resources?
- What is your "Secure Score" and what affects it?
- Are there specific recommendations for the Arc-enabled servers?

<details>
<summary>🔍 Hint</summary>

Azure Portal → **Microsoft Defender for Cloud** → **Overview**

Check these sections:
- **Security posture** — Your Secure Score
- **Recommendations** — Filter by resource type to find Arc-specific ones
- **Regulatory compliance** — What standards are being evaluated
- **Inventory** — See all resources including Arc-enabled ones

</details>

<details>
<summary>⚠️ Spoiler: What to Look For</summary>

In Defender for Cloud, you'll likely see recommendations like:

For **Arc-enabled servers**:
- Install endpoint protection
- Enable vulnerability assessment
- Apply system updates
- Configure secure communication protocols

For the **Azure Local cluster**:
- Network security recommendations
- Identity and access recommendations

For the **AKS cluster** (if deployed):
- Kubernetes cluster security recommendations
- Container image vulnerability scanning

The key value: **one dashboard showing security posture across cloud, on-prem servers, and Kubernetes clusters**. Without Arc, you'd need separate tools for each.

</details>

---

## Challenge 3: Understand RBAC for Azure Local

**Goal:** Map out who can do what on your Azure Local cluster using Azure RBAC.

**Questions to answer:**
- What Azure RBAC roles are assigned on the resource group?
- What built-in roles exist specifically for Azure Local?
- How does local (Windows) authentication relate to Azure RBAC?
- If someone has "Contributor" on the resource group, can they manage VMs on the cluster?

<details>
<summary>🔍 Hint</summary>

Check RBAC assignments:
- Resource group → **Access control (IAM)** → **Role assignments**

Search for Azure Local-specific roles in:
- **Access control (IAM)** → **Roles** → Search for "Azure Local" or "HCI"

Think about the two layers of identity:
1. **Azure RBAC** — Controls who can manage Azure resources (create VMs, view cluster)
2. **Local AD** — Controls who can log into the cluster nodes (administrator@jumpstart.local)

</details>

<details>
<summary>⚠️ Spoiler: RBAC Details</summary>

**Azure RBAC roles relevant to Azure Local:**
- **Owner/Contributor** on the resource group — Can manage all resources, including deploying VMs and AKS
- **Azure Local VM Contributor** — Can manage VMs on the cluster
- **Azure Local VM Reader** — Can view but not modify VMs
- **Key Vault Administrator** — Needed for cluster deployment (manages secrets)
- **Storage Account Contributor** — Needed for cluster deployment

**Two identity layers:**
1. **Azure RBAC**: Controls Azure Portal/CLI operations. Someone with Contributor can create VMs through the portal.
2. **Local AD (jumpstart.local)**: Controls OS-level access. Even with Azure Contributor, you still need AD credentials to RDP into cluster nodes.

This dual-identity model is a key architectural difference from pure-cloud Azure, where RBAC is the single identity layer.

</details>

---

## Challenge 4: Create a Custom Policy Initiative

**Goal:** Create a policy initiative (a group of policies) that defines your organization's minimum security baseline for hybrid servers.

Build an initiative that includes at least 3 of these requirements:
- All servers must have Azure Monitor Agent installed
- All servers must have endpoint protection
- Windows machines must have a specific password policy
- All servers must be connected to Azure Arc (for unregistered machines)

<details>
<summary>🔍 Hint</summary>

Azure Portal → **Policy** → **Definitions** → **+ Initiative definition**

1. Set the scope to your subscription
2. Name it "Hybrid Server Security Baseline"
3. Add built-in policy definitions:
   - Search for "Azure Monitor Agent" → Add relevant definition
   - Search for "Endpoint protection" → Add relevant definition
   - Search for "Password" under Guest Configuration → Add relevant definition
4. Save and assign to your resource group

</details>

---

## Deep Dive: The Governance Hierarchy

Understanding how Azure governance applies to hybrid resources:

```
Management Group
└── Subscription
    ├── Azure Policy (inherited by all resources)
    ├── Microsoft Defender for Cloud (subscription-wide)
    └── Resource Group
        ├── Azure RBAC (who can manage what)
        ├── Azure Local Cluster
        │   ├── Azure Policy (cluster-specific)
        │   ├── Arc-enabled servers (AzLHOST1, AzLHOST2)
        │   │   ├── Guest Configuration policies (OS-level audits)
        │   │   ├── Azure Monitor Agent (telemetry)
        │   │   └── Defender for Servers (threat protection)
        │   ├── VMs on Azure Local
        │   │   └── Same governance as Arc-enabled servers
        │   └── AKS on Azure Local
        │       ├── Azure Policy for Kubernetes
        │       └── Defender for Containers
        └── Azure VMs, Storage, etc.
            └── Standard Azure governance
```

**The key insight:** Governance flows down from the management group through to the most deeply nested on-prem resource. A policy set at the subscription level can audit a VM running on a Hyper-V host on an Azure Local cluster in your branch office.

## Reflection Questions

1. **If you were designing a governance strategy for a company with 10 Azure Local clusters across different countries, how would you structure your policies?** Think about management groups, regional requirements, and common baselines.

2. **What's the compliance gap between what Azure Policy can audit and what it can enforce on Arc-enabled resources?** (Hint: think about the difference between "audit" and "deny" effects)

3. **How would you handle a scenario where local regulatory requirements prevent certain telemetry from leaving the country?** Can you still use Azure governance tools?

## Next Exercise

➡️ [Exercise 6: Challenge — Hybrid Operations](./06-challenge-operations.md)
