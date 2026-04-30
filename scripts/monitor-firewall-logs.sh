#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# monitor-firewall-logs.sh — Query Azure Firewall logs for LocalBox
#
# Uses az monitor log-analytics query against the resource-specific
# Azure Firewall tables in the Log Analytics workspace in the lab RG.
#
# Usage examples:
#   ./scripts/monitor-firewall-logs.sh --resource-group azlocal2
#   ./scripts/monitor-firewall-logs.sh --resource-group azlocal2 --action denied --time-range 4h
#   ./scripts/monitor-firewall-logs.sh --resource-group azlocal2 --action rules --time-range 1d
#####################################################################

RESOURCE_GROUP=""
TIME_RANGE="1h"
ACTION="summary"

usage() {
    echo "Usage: $0 --resource-group <name> [--time-range <1h|30m|1d>] [--action summary|denied|rules]"
    exit 1
}

az_text() {
    az "$@" --only-show-errors
}

print_table() {
    local title="$1"
    local json_input="$2"

    echo ""
    echo "$title"
    printf '%s' "$json_input" | python3 -c 'import sys, json
result = json.load(sys.stdin)
tables = result.get("tables") or []
if not tables or not tables[0].get("rows"):
    print("No results found.")
    raise SystemExit(0)

table = tables[0]
headers = [column["name"] for column in table.get("columns", [])]
rows = [["" if value is None else str(value) for value in row] for row in table.get("rows", [])]
widths = [len(header) for header in headers]
for row in rows:
    for index, value in enumerate(row):
        widths[index] = max(widths[index], len(value))
fmt = "  " + "  ".join("{:<" + str(width) + "}" for width in widths)
print(fmt.format(*headers))
print("  " + "  ".join("-" * width for width in widths))
for row in rows:
    print(fmt.format(*row))'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group|-g) RESOURCE_GROUP="$2"; shift 2 ;;
        --time-range|-t) TIME_RANGE="$2"; shift 2 ;;
        --action) ACTION="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -z "$RESOURCE_GROUP" ]] && usage
[[ ! "$TIME_RANGE" =~ ^[0-9]+[mhd]$ ]] && usage
[[ "$ACTION" != "summary" && "$ACTION" != "denied" && "$ACTION" != "rules" ]] && usage

WORKSPACE_INFO=$(az_text monitor log-analytics workspace list -g "$RESOURCE_GROUP" -o json | python3 -c 'import sys, json
items = json.load(sys.stdin)
match = next((w for w in items if "Workspace" in w.get("name", "")), None)
if match:
    print("{}\t{}".format(match["name"], match["customerId"]))')

if [[ -z "$WORKSPACE_INFO" ]]; then
    echo "ERROR: No Log Analytics workspace matching '*Workspace*' was found in resource group '$RESOURCE_GROUP'."
    exit 1
fi

IFS=$'\t' read -r WORKSPACE_NAME WORKSPACE_ID <<< "$WORKSPACE_INFO"

cat <<EOF
=============================================
 Azure Firewall Log Monitor
=============================================
 Resource Group : ${RESOURCE_GROUP}
 Workspace      : ${WORKSPACE_NAME}
 Time Range     : ${TIME_RANGE}
 Action         : ${ACTION}
=============================================
EOF

case "$ACTION" in
    summary)
        SUMMARY_QUERY=$(cat <<EOF
union isfuzzy=true
(
    AZFWApplicationRule
    | where TimeGenerated > ago(${TIME_RANGE})
    | summarize Hits=count() by Category="ApplicationRule", Action
),
(
    AZFWNetworkRule
    | where TimeGenerated > ago(${TIME_RANGE})
    | summarize Hits=count() by Category="NetworkRule", Action
)
| order by Category asc, Hits desc
EOF
)
        FQDN_QUERY=$(cat <<EOF
AZFWApplicationRule
| where TimeGenerated > ago(${TIME_RANGE})
| where isnotempty(Fqdn)
| summarize Hits=count() by Fqdn
| top 10 by Hits desc
EOF
)
        print_table "Allow/Deny Summary" "$(az_text monitor log-analytics query -w "$WORKSPACE_ID" --analytics-query "$SUMMARY_QUERY" -o json)"
        print_table "Top 10 FQDNs" "$(az_text monitor log-analytics query -w "$WORKSPACE_ID" --analytics-query "$FQDN_QUERY" -o json)"
        ;;
    denied)
        DENIED_QUERY=$(cat <<EOF
union isfuzzy=true
(
    AZFWApplicationRule
    | where TimeGenerated > ago(${TIME_RANGE})
    | where Action == "Deny"
    | extend Destination=Fqdn, Port=tostring(case(Protocol == "Http", 80, Protocol == "Https", 443, "n/a")), Protocol=tostring(Protocol)
    | summarize Hits=count() by Category="ApplicationRule", Destination, Port, Protocol
),
(
    AZFWNetworkRule
    | where TimeGenerated > ago(${TIME_RANGE})
    | where Action == "Deny"
    | extend Destination=tostring(DestinationIp), Port=tostring(DestinationPort), Protocol=tostring(Protocol)
    | summarize Hits=count() by Category="NetworkRule", Destination, Port, Protocol
)
| order by Hits desc
EOF
)
        print_table "Denied Traffic" "$(az_text monitor log-analytics query -w "$WORKSPACE_ID" --analytics-query "$DENIED_QUERY" -o json)"
        ;;
    rules)
        RULES_QUERY=$(cat <<EOF
union isfuzzy=true
(
    AZFWApplicationRule
    | where TimeGenerated > ago(${TIME_RANGE})
    | where Action == "Deny"
    | where isnotempty(Fqdn)
    | summarize Hits=count() by RuleType="ApplicationRule", Destination=Fqdn, Ports="80,443", Protocols="Http,Https"
    | extend SuggestedRule=strcat("Application rule: permit ", Destination, " on Http:80,Https:443")
),
(
    AZFWNetworkRule
    | where TimeGenerated > ago(${TIME_RANGE})
    | where Action == "Deny"
    | extend Port=tostring(DestinationPort), Destination=tostring(DestinationIp), Protocols=tostring(Protocol)
    | extend RuleType=iff(toint(DestinationPort) in (80, 443, 8443), "ApplicationRule", "NetworkRule")
    | summarize Hits=count() by RuleType, Destination, Ports=Port, Protocols
    | extend SuggestedRule=case(
        RuleType == "ApplicationRule", strcat("Application rule candidate: map ", Destination, ":", Ports, " to the required FQDN and add it to AllowRequired."),
        strcat("Network rule candidate: permit ", Protocols, " to ", Destination, ":", Ports)
    )
)
| order by Hits desc
EOF
)
        print_table "Suggested Rules From Denied Traffic" "$(az_text monitor log-analytics query -w "$WORKSPACE_ID" --analytics-query "$RULES_QUERY" -o json)"
        ;;
esac
