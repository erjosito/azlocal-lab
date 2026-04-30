# Azure Firewall Rules for LocalBox

## Architecture

```text
Nested workloads
      |
      v
   Vm-Router (NAT)
      |
      v
 LocalBox-Client (172.16.1.0/24)
      |
      | UDR: 0.0.0.0/0 -> Azure Firewall private IP
      v
 Azure Firewall (AzureFirewallSubnet 172.16.2.0/26)
      |
      v
 NAT Gateway / Internet egress
```

When the firewall route is applied, traffic from `LocalBox-Subnet` no longer goes directly to the subnet's default Internet path. It is forced through Azure Firewall first, including Azure management-plane traffic initiated from `LocalBox-Client`.

## Cost

- Approximate runtime cost: **~$30/day** while Azure Firewall Standard is provisioned and running.
- If the firewall is fully deallocated as part of the lab stop workflow, expected cost is **$0 while deallocated**.
- Always stop or remove the firewall when the lab is idle.

## Configured Rules

### Application Rules

| Collection | Priority | Rule | Source | Protocols | Targets | Notes |
|---|---:|---|---|---|---|---|
| AllowAll | 100 | permit-any | `*` | `Http:80`, `Https:443` | `*` | Baseline rule so HTTP/HTTPS egress works while you discover narrower requirements. |

### Network Rules

| Collection | Priority | Rule | Destination | Protocols | Notes |
|---|---:|---|---|---|---|
| AllowRequired | 200 | _TBD_ | _TBD_ | _TBD_ | Initially empty. Populate from denied traffic analysis. |

## Discovered Rules

_No discovered rules yet._

Use the monitoring scripts to identify denied destinations and add only the rules the lab actually needs.

## How to Add New Rules

1. Review recent denies:
   - PowerShell: `./scripts/monitor-firewall-logs.ps1 -ResourceGroup <rg> -Action rules -TimeRange 4h`
   - Bash: `./scripts/monitor-firewall-logs.sh --resource-group <rg> --action rules --time-range 4h`
2. Decide the rule type:
   - **Application rule** for FQDN-based HTTP/HTTPS-style traffic, including TLS on ports such as `443` or `8443`.
   - **Network rule** for IP/port-based traffic on non-web ports.
3. Add the rule to the firewall policy:
   - Update the `AllowRequired` collection in the firewall policy.
   - Keep collection priorities stable unless you have a specific reason to change evaluation order.
4. Re-run the log query and confirm the denied traffic disappears.
5. Record the approved rule in the **Discovered Rules** section above.

## Arc Gateway Comparison

_TBD — compare this firewall-based egress control pattern with Arc Gateway for Azure Local and Arc-enabled servers._
