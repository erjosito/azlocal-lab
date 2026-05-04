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

| Collection | Priority | Rule | Source | Destination | Ports | Protocols | Notes |
|---|---:|---|---|---|---|---|---|
| AllowRequired | 200 | allow-dns | `*` | `*` | 53 | UDP, TCP | DNS resolution (8.8.8.8, root servers) |
| AllowRequired | 200 | allow-ntp | `*` | `*` | 123 | UDP | NTP time sync (time.windows.com) |
| AllowRequired | 200 | allow-smb-internal | `172.16.0.0/12, 10.0.0.0/8` | `10.0.0.0/8` | 445 | TCP | SMB to Azure storage private endpoints |
| AllowRequired | 200 | allow-quic-internal | `172.16.0.0/12, 10.0.0.0/8` | `10.0.0.0/8` | 443 | UDP | QUIC to Azure storage private endpoints |

## Discovered Endpoints

Observed from firewall application rule logs (May 2026) — all HTTPS from `172.16.1.4` (LocalBox-Client):

| FQDN | Hits | Purpose |
|------|------|---------|
| `us-v20.events.endpoint.security.microsoft.com` | 21 | Microsoft Defender for Endpoint |
| `edr-eus3.us.endpoint.security.microsoft.com` | 7 | Defender EDR |
| `gcs.prod.monitoring.core.windows.net` | 6 | Azure Monitor Guest Config |
| `westus-mdm.prod.hot.ingest.monitor.core.windows.net` | 6 | Azure Monitor MDM |
| `mobile.events.data.microsoft.com` | 6 | Microsoft telemetry |
| `mdav.us.endpoint.security.microsoft.com` | 5 | Defender Antivirus |
| `westeurope-gas.guestconfiguration.azure.com` | 2 | Azure Guest Configuration |
| `ecs.office.com` | 2 | Office config service |
| `client.wns.windows.com` | 2 | Windows Push Notifications |
| `v20.events.data.microsoft.com` | 2 | Telemetry |
| `v10.events.data.microsoft.com` | 1 | Telemetry |

Denied network traffic that required new rules:

| Dest IP | Port | Protocol | Hits | Resolution |
|---------|------|----------|------|------------|
| `8.8.8.8` | 53 | UDP | 3348 | → `allow-dns` rule |
| `192.203.230.10` | 53 | UDP | 254 | → `allow-dns` rule |
| `192.112.36.4` | 53 | UDP | 215 | → `allow-dns` rule |
| `10.71.x.x` | 445 | TCP | ~500 | → `allow-smb-internal` rule |
| `10.71.x.x` | 443 | UDP | ~390 | → `allow-quic-internal` rule |
| `20.101.57.9` | 123 | UDP | 16 | → `allow-ntp` rule |
| `104.40.149.189` | 123 | UDP | 16 | → `allow-ntp` rule |

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
