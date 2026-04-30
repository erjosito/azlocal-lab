# Exercise 8: Azure SRE Agent for Azure Local Operations

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

This is the **last exercise** in the lab, and it deliberately broadens the focus. Instead of learning another Azure Local feature directly, you will explore how an **Azure SRE Agent** can help operators respond faster when something breaks in a hybrid environment.

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
3. In Azure Monitor, create an alert rule for your AKS on Azure Local cluster
4. Use a signal that indicates workload failure, for example:
   - Pod restarts increasing
   - `CrashLoopBackOff` entries in Container Insights / logs
   - A custom log query that detects unhealthy containers
5. Optionally expose the app through a path reachable from a test VM and create a **Connection Monitor** or availability test against it

Why this design works:

- The workload is simple enough that any failure is easy to interpret
- The signal is operationally meaningful
- You can trigger the agent from both **platform signals** (pod crashes) and **experience signals** (connectivity tests)
- The same pattern applies later to real applications, not just lab demos

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

A strong configuration looks like this:

- **Name**: Azure Local Operations Expert
- **Description**: Investigates Azure Local, Arc, AKS on Azure Local, and hybrid workload incidents
- **Data source**: Your Azure subscription that contains the LocalBox resources
- **Knowledge base files**: Upload `azure-local-operations.md`

Why be explicit with the role?

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

1. Create or reuse an Azure Monitor **Action Group**
2. Connect the Action Group to the SRE Agent integration in `sre.azure.com`
3. Associate that Action Group with your AKS workload alert rule
4. Verify that a fired alert will be visible to the agent

<details>
<summary>💡 Hint</summary>

This should mirror the operational pattern from the networking-sre-agent project:

- Monitoring detects the issue
- Azure Monitor raises an alert
- The alert triggers the SRE Agent
- The agent begins investigation with telemetry + knowledge base context

</details>

<details>
<summary>🔓 Solution</summary>

A typical setup sequence is:

1. In Azure Monitor, create an **Action Group** for SRE investigations
2. In `sre.azure.com`, enable the Azure Monitor alert integration for your custom agent
3. Link the Action Group to that integration
4. Edit your AKS alert rule so it sends fired alerts to the Action Group

Once complete, the end-to-end flow becomes automatic. The SRE Agent no longer waits for you to describe the incident. It is triggered by the same Azure Monitor pipeline your operations team would use in production.

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

Example failure injection:

```powershell
kubectl get deployment localbox-store -o jsonpath='{.spec.template.spec.containers[*].name}'
kubectl patch deployment localbox-store --type merge -p '{"spec":{"template":{"spec":{"containers":[{"name":"<container-name>","command":["/bin/sh","-c","echo broken && exit 1"]}]}}}}'
```

Replace `<container-name>` with the value returned by the first command.

Then observe:

```powershell
kubectl get pods -w
kubectl describe pod <failing-pod-name>
kubectl logs <failing-pod-name> --previous
```

What should happen:

- Pods enter a failed / restarting state
- Your Azure Monitor rule fires
- The SRE Agent receives the alert and begins its investigation

If you prefer a networking-style fault, you can later simulate one by breaking service reachability or applying an overly restrictive NetworkPolicy. The important pattern is the same: **inject fault → alert fires → agent investigates**.

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

You have now gone from understanding Azure Local architecture, to running workloads, to monitoring them, and finally to experimenting with AI-assisted operations. That end-to-end view is what makes hybrid platform engineering interesting: the technology only matters if you can operate it well.

## Next Exercise

➡️ [Exercise 9: Arc Gateway and Network Security](./09-arc-gateway.md)
