# Exercise 7: Azure SRE Agent for Azure Local Operations

## What You'll Learn

By the end of this exercise, you will understand:

- What the Azure SRE Agent is and how it uses alerts, telemetry, and knowledge documents
- How to create a custom SRE Agent at [sre.azure.com](https://sre.azure.com)
- How to teach the agent about Azure Local by uploading a domain-specific knowledge base
- How to connect Azure Monitor alerts to the agent
- How to simulate an Azure Local incident and observe the agent's investigation
- How AI-assisted operations can help, but not replace, sound platform engineering and SRE practices

## Prerequisites

- Completed Exercises 3 and 4
- A working AKS on Azure Local cluster
- Access to Azure Monitor and the Azure Portal
- Access to [https://sre.azure.com](https://sre.azure.com)
- The knowledge base file created for this exercise: [`./sre-agent-knowledge/azure-local-operations.md`](./sre-agent-knowledge/azure-local-operations.md)

## Context

This exercise broadens the focus. Instead of learning another Azure Local feature directly, you will explore how an **Azure SRE Agent** can help operators respond faster when something breaks in a hybrid environment.

The idea is simple:

1. A workload runs on your Azure Local environment
2. Azure Monitor detects a failure or health regression
3. The Azure SRE Agent receives the alert
4. The agent investigates using telemetry plus uploaded knowledge documents
5. The agent produces recommendations for the human operator

That workflow is especially valuable for Azure Local because incidents often cross multiple layers:

- Azure control plane
- Arc integration
- Kubernetes
- VMs and local networking
- Storage and cluster infrastructure

This exercise follows the same spirit as the [`networking-sre-agent`](https://github.com/erjosito/networking-sre-agent) project:

- **Knowledge base files** explain the environment to the agent
- **Fault injection** creates realistic incidents
- **Monitoring + alerts** trigger automated investigation

---

## Scenario

In this scenario, you will run a small web workload on AKS on Azure Local. Then you will deliberately break it so that Azure Monitor raises an alert.

The recommended failure for this lab is a **pod failure / crash scenario** because it is easy to trigger and easy to reason about. If you prefer, you can extend the scenario later with a networking fault or resource exhaustion signal.

```text
User / Test VM
      |
      v
Sample web app on AKS on Azure Local
      |
      +--> Container Insights / Kubernetes logs
      +--> Optional synthetic connectivity checks
      |
      v
Azure Monitor alert rule
      |
      v
Azure SRE Agent
      |
      +--> Uses Azure telemetry
      +--> Uses uploaded Azure Local knowledge base
      |
      v
Findings + remediation recommendations
```

---

## Challenge 1: Understand the Azure SRE Agent Model

**Goal:** Understand what the agent does before you start configuring it.

**Questions to answer:**

1. What inputs does the SRE Agent rely on?
2. Why upload knowledge base files instead of relying only on raw telemetry?
3. Why is Azure Local a good use case for an SRE Agent?

<details>
<summary>💡 Hint</summary>

Think of the SRE Agent as combining three things:

- **Signals**: alerts, logs, metrics, topology
- **Context**: subscription resources and Azure data sources
- **Knowledge**: documents that explain how your environment is designed and how it fails

</details>

<details>
<summary>🔓 Solution</summary>

The Azure SRE Agent is not just a chatbot for operations. It works best when it has:

- A real operational signal, such as an Azure Monitor alert
- Access to the relevant Azure resources and telemetry
- A knowledge base that explains the environment, failure modes, and preferred troubleshooting steps

Why knowledge matters:

Telemetry can tell the agent **what** is happening, but the knowledge base helps it reason about **why** it matters in your specific environment and **what good remediation looks like**.

Why Azure Local is a strong use case:

Hybrid incidents are multi-layered. A simple application outage might be caused by a Kubernetes issue, a storage issue, an Arc connectivity problem, or a networking dependency. The agent becomes more useful when it understands those layers.

</details>

---

## Challenge 2: Prepare a Sample Workload and Alert Signal

**Goal:** Put something on AKS that can fail in an observable way.

If you still have the `nginx` deployment from Exercise 3, you can reuse it. Otherwise, create a simple deployment such as `localbox-store`.

**Tasks:**

1. Deploy a small web app to AKS
2. Validate that the pods are healthy
3. Enable or verify Container Insights / AKS monitoring
4. Create an Azure Monitor alert that detects pod failures or crash loops
5. **Optional but recommended:** create a synthetic connectivity check (for example, a Connection Monitor or availability test) so you can later trigger the agent with a network-style symptom too

<details>
<summary>💡 Hint</summary>

A minimal workload is enough. Example:

```powershell
kubectl create deployment localbox-store --image=nginx --replicas=2
kubectl expose deployment localbox-store --port=80 --type=ClusterIP
kubectl get pods
kubectl get svc
```

For alerting, the cleanest lab signal is usually a **log alert** or **Container Insights alert** that looks for failed or restarting pods.

If you want to mirror the networking-sre-agent pattern more closely, expose the service internally and add a **Connection Monitor** or other synthetic test from a VM that can reach the app.

</details>

<details>
<summary>🔓 Solution</summary>

A good minimal workflow is:

1. Deploy a test app:
   ```powershell
   kubectl create deployment localbox-store --image=nginx --replicas=2
   kubectl expose deployment localbox-store --port=80 --type=ClusterIP
   kubectl get pods -o wide
   ```
2. Confirm the pods are healthy and stable
3. **Create an alert rule** that detects pod failures:

   **Option A — Log-based alert (recommended for this lab):**

   Go to Azure Monitor → Alerts → + Create → Alert Rule:
   - **Scope**: select your AKS Arc-connected cluster resource (`localbox-aks`)
   - **Condition**: Custom log search
   - **KQL query**:
     ```kql
     KubePodInventory
     | where ClusterName == "localbox-aks"
     | where PodStatus in ("Failed", "Unknown") or ContainerStatusReason == "CrashLoopBackOff"
     | summarize FailedPods = dcount(PodUid) by bin(TimeGenerated, 5m)
     | where FailedPods > 0
     ```
   - **Alert logic**: Greater than 0, evaluation period 5 minutes, frequency 5 minutes
   - **Severity**: Sev 2 (Warning)
   - **Action Group**: create one (you'll connect it to the SRE Agent in Challenge 4)
   - **Alert rule name**: `AKS Pod Failures - localbox-aks`
   - ⚠️ **Auto-mitigation**: Make sure to enable **"Automatically resolve alerts"** (also called `autoMitigate`). If disabled, fired alerts remain in "Fired" state forever even after the problem is fixed, and the SRE Agent may keep re-investigating resolved issues.

   **Option B — Metric-based alert (simpler but less flexible):**

   - **Scope**: your AKS Arc cluster
   - **Signal**: `Pods in Failed state` (under Container Insights metrics)
   - **Threshold**: Static, Greater than 0
   - Same action group configuration

   > ℹ️ **Note:** Container Insights must be enabled on your AKS cluster for either option to work. If `KubePodInventory` shows no data, see the troubleshooting section below.

4. **Verify the alert rule is active**: Azure Monitor → Alerts → Alert rules → confirm your rule shows "Enabled"

5. Optionally expose the app through a path reachable from a test VM and create a **Connection Monitor** or availability test against it

**How to trigger the alert (for testing):**

You'll inject the actual fault in Challenge 5, but if you want to test the alert rule immediately:
```powershell
# Create a pod that immediately fails
kubectl run test-fail --image=nginx --command -- /bin/sh -c "exit 1"
# Wait 5-10 minutes for the alert to evaluate
# Then clean up
kubectl delete pod test-fail
```

### Troubleshooting: Alert Not Firing

If you have a pod in `CrashLoopBackOff` but no alert fires, work through these checks:

**1. Verify Container Insights data is flowing:**

Run this query in your Log Analytics workspace (Azure Monitor → Logs):

```kql
KubePodInventory
| where TimeGenerated > ago(30m)
| summarize count() by ClusterName
```

If this returns **zero results**, the `ama-logs` agent is not sending data.

**2. Check the `ClusterName` in your alert KQL:**

The `ClusterName` field in Container Insights may differ from the Arc resource name. Run:

```kql
KubePodInventory | distinct ClusterName | take 10
```

Then update your alert rule's KQL to match the actual value.

**3. Check if the `ama-logs` pods are running:**

```powershell
kubectl get pod -n kube-system | Select-String "ama"
```

If no `ama-logs` pods exist, or they are in `Pending`/`CrashLoopBackOff`, the extension deployed at the ARM level but failed inside the cluster.

**4. Known issue — Extension "Succeeded" but no pods (empty Helm release):**

In some cases, the `azuremonitor-containers` extension shows `provisioningState: Succeeded` in Azure, but deploys **empty Helm releases** with no actual DaemonSets or pods. You can detect this by checking:

```powershell
kubectl get all -n azuremonitor-containers
# If this shows no resources, the extension is broken

# Also check Helm release cycling (new releases every 5 minutes with no resources):
kubectl get secret -n azuremonitor-containers | Select-String "helm.release"
```

**Fix:** Delete and reinstall the extension:

```powershell
# Delete (may fail if DCR is orphaned — see note below)
az k8s-extension delete --name azuremonitor-containers `
  --cluster-name <your-cluster> --cluster-type connectedClusters `
  --resource-group <your-rg> --yes

# Reinstall with explicit workspace
az k8s-extension create --name azuremonitor-containers `
  --cluster-name <your-cluster> --cluster-type connectedClusters `
  --resource-group <your-rg> `
  --extension-type Microsoft.AzureMonitor.Containers `
  --configuration-settings `
    logAnalyticsWorkspaceResourceID="<full-workspace-resource-id>" `
    amalogs.useAADAuth="true"
```

> ⚠️ **If the delete fails with "ResourceNotFound" for a DCR:** The extension is looking for a Data Collection Rule with a different naming pattern than what actually exists. You may need to manually create a placeholder DCR with the expected name (check the error message), then retry the delete. This is a known ARM cleanup issue.

**5. Timing:** Log-based alerts evaluate every 5 minutes with a 5-minute lookback window. After injecting a fault, allow **10–15 minutes** before concluding the alert isn't working.

**6. Alerts fire but never auto-resolve (stay "Fired" forever):**

If you delete the failing pods but the alerts remain in "Fired" state, check whether **auto-mitigation** is enabled on the alert rule:

```powershell
az monitor scheduled-query show -g <rg> -n "<alert-rule-name>" --query autoMitigate
```

If it returns `false`, the alerts will never auto-resolve. Fix it:

```powershell
az monitor scheduled-query update -g <rg> -n "<alert-rule-name>" --auto-mitigate true
```

To manually close stale alerts, go to Azure Monitor → Alerts → select the fired alerts → Change State → Closed.

> 💡 **Why this matters:** If stale alerts accumulate, the SRE Agent may pick them up again and start investigations for problems that no longer exist. Always enable auto-mitigation for scheduled query rules used with the SRE Agent.

</details>

---

## Challenge 3: Create a Custom Azure SRE Agent

**Goal:** Create an agent that specializes in Azure Local operations instead of generic cloud troubleshooting.

**What you need to configure:**

- The subscription / data source the agent can inspect
- The custom knowledge base documents it can use
- A role description that tells the agent what kind of incidents it should focus on

<details>
<summary>💡 Hint</summary>

At [sre.azure.com](https://sre.azure.com):

1. Add your Azure subscription as a data source
2. Upload the markdown file from `exercises/sre-agent-knowledge/`
3. Create a custom agent with a clear operational role

A good agent name is something like **Azure Local Operations Expert**.

</details>

<details>
<summary>🔓 Solution</summary>

### Step 1 — Navigate to sre.azure.com

Open [https://sre.azure.com](https://sre.azure.com) and sign in with your Azure credentials. You'll land on the **SRE Agent Home** page.

### Step 2 — Create a new custom agent

1. Click **+ New Agent** (or **Create Agent** on the home page)
2. Fill in the basic information:
   - **Name**: `Azure Local Operations Expert`
   - **Description**: `Investigates Azure Local, Arc, AKS on Azure Local, and hybrid workload incidents. Understands nested virtualization, custom locations, Arc data services, and VLAN networking.`

### Step 3 — Configure Data Sources

The agent needs access to your Azure resources to pull telemetry during investigations:

1. In the agent configuration, go to **Data Sources**
2. Click **+ Add data source** → **Azure subscription**
3. Select the subscription containing your LocalBox resources
4. Grant the agent read access — it will use Azure Resource Graph, Azure Monitor logs, and metrics during investigations

> ℹ️ The agent uses your Azure RBAC permissions. It can only see resources you can see. No special elevated role is needed beyond what you already have for the lab.

### Step 4 — Upload the Knowledge Base

This is what makes the agent domain-specific rather than a generic troubleshooter:

1. Go to **Knowledge Base** in the agent settings
2. Click **+ Upload document**
3. Upload the file: `exercises/sre-agent-knowledge/azure-local-operations.md`
4. Give it a descriptive name like `Azure Local Operations Runbook`
5. Wait for ingestion to complete (usually < 1 minute)

The knowledge base tells the agent:
- How your environment is structured (layers, components)
- What failure modes are common and how they present
- What diagnostic commands to reference
- What remediation patterns are appropriate
- Specific quirks of the emulated LocalBox environment (memory constraints, custom locations, etc.)

### Step 5 — Create Subagents for Specialized Domains

The SRE Agent uses **subagents** to delegate specialized investigation tasks. Each subagent focuses on one domain and has its own instructions, tools, and skills. The main agent orchestrates and routes to the appropriate subagent based on the incident type.

Go to **Builder** → **Subagent builder** → **Create** → **Custom Agent**:

**Subagent 1 — Kubernetes Expert:**

| Field | Value |
|-------|-------|
| Name | `kubernetes_expert` |
| Instructions | `You are a Kubernetes specialist for AKS on Azure Local. Diagnose pod failures, scheduling issues, node pressure, and resource exhaustion. Check pod events, describe nodes, and inspect resource requests vs. allocatable capacity.` |
| Handoff description | `Handles Kubernetes pod, node, and workload troubleshooting` |
| Tools | `execute_kusto_query`, `azure_cli` |

**Subagent 2 — Infrastructure Expert:**

| Field | Value |
|-------|-------|
| Name | `infrastructure_expert` |
| Instructions | `You are an Azure Local infrastructure specialist. Diagnose cluster health, storage pool degradation, node connectivity, and Arc integration issues. Check cluster nodes, virtual disks, and Arc agent status.` |
| Handoff description | `Handles Azure Local cluster, storage, and Arc connectivity issues` |
| Tools | `execute_kusto_query`, `azure_cli` |

**Subagent 3 — Data Services Expert (optional):**

| Field | Value |
|-------|-------|
| Name | `database_expert` |
| Instructions | `You are an Arc-enabled data services specialist. Diagnose data controller deployment issues, SQL MI pod scheduling, custom location errors, and extension failures. Understand that controldb-0 needs 4 GB RAM and SQL MI needs 4 vCPUs + 16 GB. Know that the azure-arc-aks-hci template is required for AKS on Azure Local.` |
| Handoff description | `Handles Arc data services, SQL MI, and data controller issues` |
| Tools | `execute_kusto_query`, `azure_cli` |

> ℹ️ **Why subagents?** Without subagents, the main agent tries to be a generalist for everything. With subagents, it can route a "pod crash" alert to the Kubernetes expert and a "storage degraded" alert to the infrastructure expert — each with focused instructions and tools. This produces better investigations.

You can also define subagents as YAML for version control:

```yaml
name: kubernetes_expert
system_prompt: |
  You are a Kubernetes specialist for AKS on Azure Local.
  Diagnose pod failures, scheduling issues, node pressure,
  and resource exhaustion.
handoff_description: Handles Kubernetes pod, node, and workload troubleshooting
tools:
  - execute_kusto_query
  - azure_cli
enable_skills: true
```

### Step 6 — Configure the Agent Canvas

The **canvas** is where the agent displays its investigation workflow visually:

1. Go to **Canvas settings** (or **Investigation view**)
2. The canvas shows the agent's reasoning as a graph: trigger → evidence gathering → hypothesis → recommendation
3. Configure these canvas preferences:
   - **Auto-expand evidence nodes**: On (shows the actual log/metric snippets the agent found)
   - **Show resource topology**: On (displays which Azure resources the agent inspected)
   - **Investigation depth**: Medium (balances speed vs. thoroughness — you can increase to High for complex multi-layer issues)

### Step 7 — Test with a manual prompt

Before wiring up alerts, verify the agent works with a manual question:

1. Open the agent's **Chat / Investigate** interface
2. Type a test question like: `What is the current health of the AKS cluster localbox-aks in resource group azlocal2?`
3. The agent should:
   - Query Azure Resource Graph for the cluster
   - Check recent alerts or health signals
   - Reference the knowledge base if relevant
   - Return a structured finding

If it responds with relevant Azure Local context (not generic cloud advice), your knowledge base is working.

### Why be explicit with the role?

The better you define the agent's operating domain, the better its investigations become. You are effectively telling it:

- What resources matter
- What patterns are normal
- Which failure modes are likely
- Which troubleshooting sequences are preferred

</details>

---

## Challenge 4: Connect Azure Monitor Alerts to the Agent

**Goal:** Make the agent react to real incidents instead of manual prompting.

**Tasks:**

1. Create a **Response Plan** in sre.azure.com that matches your alert
2. Configure the plan's severity filter, keywords, and target custom agent
3. Set the appropriate autonomy level (Review vs Autonomous)
4. Verify that a fired alert triggers an automatic investigation

<details>
<summary>💡 Hint</summary>

The SRE Agent uses **Response Plans** to subscribe to Azure Monitor alerts directly — no webhook or Action Group configuration is needed. The agent monitors alerts at the subscription level and triggers investigations when an alert matches a response plan's filters.

The connection flow is:

```
Alert rule fires → Azure Monitor alert created → SRE Agent matches Response Plan → Agent starts investigation
```

You configure this entirely at sre.azure.com — no changes needed on the Azure Monitor side.

</details>

<details>
<summary>🔓 Solution</summary>

### Step 1 — Create a Response Plan

At [sre.azure.com](https://sre.azure.com), open your agent → **Response Plans** → **+ Create**:

| Field | Value |
|-------|-------|
| Name | `AKS Pod Failures` |
| Description | `Investigate Kubernetes pod failures and crash loops on Azure Local AKS clusters` |
| Severity | Sev 2, Sev 3 |
| Title contains (optional) | `Pod Failure` or leave blank to match all alerts from the subscription |
| Custom Agent | `kubernetes_expert` (or your main agent if no subagents) |
| Autonomy | **Review** (recommended for initial setup — you approve actions before execution) |
| Cooldown | 3 hours (prevents repeated investigations of the same alert) |

### Step 2 — How Response Plans work (no webhook needed)

Unlike traditional Action Group webhooks, the SRE Agent integrates at the **subscription level**:

- When you added your Azure subscription as a data source (Challenge 3, Step 3), the agent gained the ability to observe alerts fired in that subscription
- Response Plans define **which alerts** the agent should investigate and **how** (which custom agent, what autonomy level)
- When a matching alert fires, the agent automatically opens an investigation — no Action Group, no webhook, no manual trigger

This is simpler and more reliable than webhook-based integration because:
- No webhook URL to manage or rotate
- No Action Group configuration needed
- The agent sees the full alert context directly from Azure Monitor
- Matching is declarative (severity + keywords + service type)

### Step 3 — Delete the auto-generated quickstart plan (if present)

When you first create an agent, sre.azure.com may auto-generate a default "quickstart" response plan that catches all alerts. This can conflict with your targeted plan:

1. Go to **Response Plans**
2. If you see a generic plan you didn't create, delete it
3. Keep only your custom plan(s)

### Step 4 — Verify the Response Plan is active

1. **sre.azure.com** → your agent → **Response Plans** → status shows "Active"
2. Confirm the subscription data source is connected and healthy
3. Optionally fire a test alert (inject a fault — see Challenge 5) and check the **Investigations** tab to see if the agent picks it up automatically

### What happens when an alert fires

1. Azure Monitor evaluates your KQL query every 5 minutes
2. If the condition is met (pods in Failed state > 0), the alert transitions to **Fired**
3. The SRE Agent scans fired alerts against its Response Plans
4. Your `AKS Pod Failures` plan matches (severity + subscription)
5. The agent routes to the designated custom agent (`kubernetes_expert`)
6. The custom agent begins an automated investigation:
   - Queries Azure Resource Graph for cluster topology
   - Pulls recent logs from Log Analytics (KubePodInventory, ContainerLog)
   - Checks Container Insights metrics
   - Correlates with the uploaded knowledge base
   - Produces findings visible on the **canvas**
7. In **Review** mode: you see the findings and approve/reject recommended actions
8. In **Autonomous** mode: the agent would execute read-only diagnostics immediately

You can view all investigations at sre.azure.com → **Investigations**.

### Optional: Action Group webhook (alternative approach)

If you prefer explicit webhook-based triggering (useful if you want the agent to react to specific Action Groups rather than all subscription alerts), you can also:

1. Create an Action Group with a webhook receiver pointing to the agent's endpoint
2. Associate that Action Group with your alert rule

However, the Response Plan approach is simpler for most scenarios and is the recommended pattern.

</details>

---

## Challenge 5: Inject a Failure

**Goal:** Generate a realistic alert and let the agent investigate it.

The recommended lab fault is to make the application containers fail repeatedly.

**One simple option:** patch the deployment so the container exits immediately instead of running nginx.

<details>
<summary>💡 Hint</summary>

Before injecting the fault, note the healthy state:

```powershell
kubectl get deploy,pods
kubectl describe deployment localbox-store
```

Then introduce a bad command so the container exits on startup. After a short time, Kubernetes should show repeated restarts and Azure Monitor should detect the failure.

</details>

<details>
<summary>🔓 Solution</summary>

**Step 1 — Inject the fault:**

```powershell
# Get the container name
kubectl get deployment localbox-store -o jsonpath='{.spec.template.spec.containers[*].name}'
```

Patch the deployment so the container exits immediately on startup:

```powershell
kubectl patch deployment localbox-store --type merge -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","command":["/bin/sh","-c","echo broken && exit 1"]}]}}}}'
```

> ℹ️ Replace `nginx` with whatever container name the first command returned.

**Step 2 — Observe the failure locally:**

```powershell
kubectl get pods -w
# Wait ~30 seconds — you should see pods entering CrashLoopBackOff
kubectl describe pod <failing-pod-name>
kubectl logs <failing-pod-name> --previous
```

**Step 3 — Wait for the alert to fire:**

The alert rule evaluates every 5 minutes, so you may need to wait **5-10 minutes** after the pods start crash-looping.

To check alert status:
- Azure Portal → Monitor → Alerts → look for a "Fired" alert from your `AKS Pod Failures` rule
- Or: Azure Portal → your AKS cluster → Alerts blade

**Step 4 — Verify the SRE Agent received the alert:**

Go to [sre.azure.com](https://sre.azure.com) → your agent → Investigations. You should see a new investigation triggered by the fired alert.

> ⚠️ **If the alert doesn't fire:** Check that Container Insights is sending data. Run this KQL in Log Analytics:
> ```kql
> KubePodInventory
> | where ClusterName == "localbox-aks"
> | where TimeGenerated > ago(15m)
> | summarize count() by PodStatus
> ```
> If this returns no results, Container Insights may not be configured on your Arc-enabled cluster.

If you prefer a networking-style fault, you can simulate one by breaking service reachability or applying an overly restrictive NetworkPolicy. The important pattern is the same: **inject fault → alert fires → agent investigates**.

</details>

---

## Challenge 6: Observe the Agent's Investigation and Recover the Service

**Goal:** Evaluate whether the agent gives useful operational guidance.

**Questions to answer:**

- Did the agent correctly identify the affected resource and symptom?
- Did it use the uploaded Azure Local knowledge to reason about likely causes?
- Did its remediation guidance match what you would do manually?
- What evidence did it cite from Azure Monitor, AKS, or Arc resources?

<details>
<summary>💡 Hint</summary>

Compare the agent's output to what a human operator would check first:

- Pod status and restart count
- Recent changes to the deployment
- Cluster node health
- Resource constraints
- Related alerts and timelines

</details>

<details>
<summary>🔓 Solution</summary>

A strong investigation result should include some or all of these elements:

- The workload or namespace that is failing
- The alert signal that triggered the investigation
- Evidence that pods are restarting or not becoming ready
- A shortlist of likely causes, such as:
  - bad deployment change
  - bad image or startup command
  - resource exhaustion on the node
  - lost dependency or network path
- Concrete remediation guidance

To recover the demo fault, undo the deployment change:

```powershell
kubectl rollout undo deployment localbox-store
kubectl get pods
```

What you are really testing here is not whether the agent is perfect, but whether it helps you move from **alert** to **actionable investigation** faster than starting from scratch.

</details>

---

## Extension Ideas

If you want to push the scenario further, try one of these:

- **Networking incident**: make the service unreachable from a test VM and alert on failed connectivity
- **Resource exhaustion**: set an unrealistically low memory limit and watch for OOM kills
- **Arc integration incident**: disconnect or misconfigure an Arc extension and see how the agent reasons about telemetry gaps
- **Multi-signal incident**: combine a workload crash with node pressure or storage saturation

## Reflection Questions

1. **What parts of the investigation should remain human-driven even if the agent becomes very good?**
2. **How important is the knowledge base compared to raw logs and metrics?**
3. **Would you trust the same agent more in a standard Azure environment or in a hybrid Azure Local environment? Why?**
4. **If your company had 50 Azure Local clusters, how would you standardize the knowledge documents so the agent becomes consistently useful?**

## Key Takeaways

- The Azure SRE Agent is most valuable when it combines alerts, telemetry, and environment-specific knowledge
- Azure Local is a strong SRE Agent scenario because hybrid failures cross infrastructure, platform, and control-plane boundaries
- A good knowledge base makes the agent more than reactive; it makes it context-aware
- Fault injection is essential because you learn whether the monitoring and investigation flow actually works
- AI-assisted operations should accelerate human responders, not replace sound observability and runbooks

## Final Note

You have now gone from understanding Azure Local architecture, to running workloads, to monitoring them, and now to experimenting with AI-assisted operations. That end-to-end view is what makes hybrid platform engineering interesting: the technology only matters if you can operate it well.

## Next Exercise

➡️ [Exercise 8: Arc Gateway and Network Security](./08-arc-gateway.md)
