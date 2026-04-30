#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# deploy-arc-gateway.sh — Create or remove Azure Arc Gateway
#
# Creates an Azure Arc Gateway resource for the LocalBox lab and,
# optionally, configures the Arc agents on AzLHOST1 and AzLHOST2 to
# use it via the LocalBox-Client VM.
#####################################################################

RESOURCE_GROUP=""
LOCATION=""
GATEWAY_NAME="LocalBox-ArcGateway"
NESTED_ADMIN_PASSWORD="Microsoft123!"
CONFIGURE=false
REMOVE=false
CLIENT_VM_NAME="LocalBox-Client"
NESTED_NODES=("AzLHOST1" "AzLHOST2")
GATEWAY_CLI_MODE=""

usage() {
    echo "Usage: $0 --resource-group <name> [--location <region>] [--gateway-name <name>] [--configure] [--remove]"
    echo ""
    echo "Options:"
    echo "  --resource-group, -g        Resource group containing the LocalBox lab (required)"
    echo "  --location, -l              Azure region for the gateway resource (defaults to RG location)"
    echo "  --gateway-name              Name for the Arc Gateway resource (default: LocalBox-ArcGateway)"
    echo "  --nested-admin-password     Local administrator password on AzLHOST1/AzLHOST2 (default: Microsoft123!)"
    echo "  --configure                 Configure the Arc agents on both nested nodes to use the gateway"
    echo "  --remove                    Reset the Arc agents to direct mode and delete the gateway"
    exit 1
}

run_az() {
    local output
    if ! output=$(az "$@" 2>&1); then
        echo "ERROR: az $*" >&2
        echo "$output" >&2
        exit 1
    fi
    printf '%s' "$output"
}

ensure_arcgateway_extension() {
    if az arcgateway -h >/dev/null 2>&1; then
        return
    fi

    echo "Installing Azure CLI arcgateway extension..."
    az extension add -n arcgateway --allow-preview true --only-show-errors >/dev/null
}

get_gateway_cli_mode() {
    if az connectedmachine gateway -h >/dev/null 2>&1; then
        echo "connectedmachine"
        return
    fi

    ensure_arcgateway_extension
    echo "arcgateway"
}

get_gateway_json() {
    local name="$1"
    local rg="$2"

    if [[ "$GATEWAY_CLI_MODE" == "connectedmachine" ]]; then
        az connectedmachine gateway show --name "$name" --resource-group "$rg" -o json 2>/dev/null || true
    else
        az arcgateway show --name "$name" --resource-group "$rg" -o json 2>/dev/null || true
    fi
}

get_gateway_value() {
    local name="$1"
    local rg="$2"
    local query="$3"

    if [[ "$GATEWAY_CLI_MODE" == "connectedmachine" ]]; then
        az connectedmachine gateway show --name "$name" --resource-group "$rg" --query "$query" -o tsv 2>/dev/null || true
    else
        az arcgateway show --name "$name" --resource-group "$rg" --query "$query" -o tsv 2>/dev/null || true
    fi
}

create_gateway() {
    local name="$1"
    local rg="$2"
    local location="$3"

    if [[ "$GATEWAY_CLI_MODE" == "connectedmachine" ]]; then
        run_az connectedmachine gateway create \
            --name "$name" \
            --resource-group "$rg" \
            --location "$location" \
            --gateway-type public \
            --allowed-features '*' \
            --output none >/dev/null
    else
        run_az arcgateway create \
            --name "$name" \
            --resource-group "$rg" \
            --location "$location" \
            --gateway-type public \
            --allowed-features '*' \
            --output none >/dev/null
    fi
}

delete_gateway() {
    local name="$1"
    local rg="$2"

    if [[ "$GATEWAY_CLI_MODE" == "connectedmachine" ]]; then
        run_az connectedmachine gateway delete --name "$name" --resource-group "$rg" --yes --output none >/dev/null
    else
        run_az arcgateway delete --name "$name" --resource-group "$rg" --yes --output none >/dev/null
    fi
}

update_arcgateway_settings() {
    local gateway_resource_id="$1"
    local subscription_id
    subscription_id=$(run_az account show --query id -o tsv)

    ensure_arcgateway_extension

    for node in "${NESTED_NODES[@]}"; do
        echo "Updating Arc Gateway association for Azure resource '$node'..."
        run_az arcgateway settings update \
            --resource-group "$RESOURCE_GROUP" \
            --subscription "$subscription_id" \
            --base-provider Microsoft.HybridCompute \
            --base-resource-type machines \
            --base-resource-name "$node" \
            --gateway-resource-id "$gateway_resource_id" \
            --output none >/dev/null
    done
}

invoke_agent_configuration() {
    local connection_type="$1"
    local gateway_resource_id="$2"
    local run_command_script

    run_command_script=$(cat <<'EOF'
$nodes = @('__NODE1__', '__NODE2__')
$securePassword = ConvertTo-SecureString '__PASSWORD__' -AsPlainText -Force
$credential = [PSCredential]::new('Administrator', $securePassword)
$connectionType = '__CONNECTION_TYPE__'
$gatewayResourceId = '__GATEWAY_RESOURCE_ID__'

foreach ($node in $nodes) {
    Write-Output "=== Configuring $node ==="

    Invoke-Command -VMName $node -Credential $credential -ScriptBlock {
        param(
            [string]$ConnectionType,
            [string]$GatewayResourceId
        )

        azcmagent config set connection.type $ConnectionType | Out-Null

        if ($ConnectionType -eq 'gateway') {
            azcmagent config set connection.gateway-resource-id $GatewayResourceId | Out-Null
        }

        Restart-Service himds -Force
        Start-Sleep -Seconds 10
        azcmagent show
    } -ArgumentList $connectionType, $gatewayResourceId
}
EOF
)

    local escaped_password="${NESTED_ADMIN_PASSWORD//\'/\'\'}"
    local escaped_gateway_resource_id="${gateway_resource_id//\'/\'\'}"

    run_command_script=${run_command_script//__NODE1__/${NESTED_NODES[0]}}
    run_command_script=${run_command_script//__NODE2__/${NESTED_NODES[1]}}
    run_command_script=${run_command_script//__PASSWORD__/$escaped_password}
    run_command_script=${run_command_script//__CONNECTION_TYPE__/$connection_type}
    run_command_script=${run_command_script//__GATEWAY_RESOURCE_ID__/$escaped_gateway_resource_id}

    echo "Running remote configuration on '$CLIENT_VM_NAME'..."
    run_az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CLIENT_VM_NAME" \
        --command-id RunPowerShellScript \
        --scripts "$run_command_script" \
        --query "value[0].message" \
        -o tsv
}

show_manual_instructions() {
    local gateway_resource_id="$1"

    echo ""
    echo "Manual configuration steps"
    echo "-------------------------"
    echo "1. Associate the Arc-enabled server resources with the gateway:"
    for node in "${NESTED_NODES[@]}"; do
        echo "   az arcgateway settings update --resource-group $RESOURCE_GROUP --base-provider Microsoft.HybridCompute --base-resource-type machines --base-resource-name $node --gateway-resource-id $gateway_resource_id"
    done
    echo ""
    echo "2. On LocalBox-Client, run these commands on both nested nodes:"
    echo "   azcmagent config set connection.type gateway"
    echo "   azcmagent config set connection.gateway-resource-id $gateway_resource_id"
    echo "   Restart-Service himds"
    echo ""
    echo "3. Verify on each node:"
    echo "   azcmagent show"
    echo "   azcmagent check"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --resource-group|-g) RESOURCE_GROUP="$2"; shift 2 ;;
        --location|-l) LOCATION="$2"; shift 2 ;;
        --gateway-name) GATEWAY_NAME="$2"; shift 2 ;;
        --nested-admin-password) NESTED_ADMIN_PASSWORD="$2"; shift 2 ;;
        --configure) CONFIGURE=true; shift ;;
        --remove) REMOVE=true; shift ;;
        *) usage ;;
    esac
done

[[ -z "$RESOURCE_GROUP" ]] && usage

echo "============================================="
echo " Azure Arc Gateway for LocalBox"
echo "============================================="
echo " Resource Group : $RESOURCE_GROUP"
echo " Gateway Name   : $GATEWAY_NAME"
echo " Client VM      : $CLIENT_VM_NAME"
echo " Configure Now  : $CONFIGURE"
echo " Remove         : $REMOVE"
echo "============================================="
echo ""

RG_EXISTS=$(run_az group exists --name "$RESOURCE_GROUP")
if [[ "$RG_EXISTS" != "true" ]]; then
    echo "ERROR: Resource group '$RESOURCE_GROUP' does not exist." >&2
    exit 1
fi

if [[ -z "$LOCATION" ]]; then
    LOCATION=$(run_az group show --name "$RESOURCE_GROUP" --query location -o tsv)
fi

GATEWAY_CLI_MODE=$(get_gateway_cli_mode)
GATEWAY_JSON=$(get_gateway_json "$GATEWAY_NAME" "$RESOURCE_GROUP")

if [[ "$REMOVE" == true ]]; then
    echo "Switching Arc agents back to direct connectivity..."
    update_arcgateway_settings "null"
    invoke_agent_configuration "direct" ""

    if [[ -n "$GATEWAY_JSON" ]]; then
        GATEWAY_ID=$(get_gateway_value "$GATEWAY_NAME" "$RESOURCE_GROUP" id)
        echo "Deleting Arc Gateway '$GATEWAY_NAME'..."
        delete_gateway "$GATEWAY_NAME" "$RESOURCE_GROUP"
        echo "Waiting for Arc Gateway deletion to complete..."
        run_az resource wait --ids "$GATEWAY_ID" --deleted --interval 15 --timeout 900 --only-show-errors >/dev/null
        echo "Arc Gateway deleted."
    else
        echo "Arc Gateway '$GATEWAY_NAME' was not found. Agent configuration was still reset to direct mode."
    fi

    echo ""
    echo "Validation commands:"
    echo "  azcmagent show"
    echo "  azcmagent check"
    exit 0
fi

if [[ -z "$GATEWAY_JSON" ]]; then
    echo "Creating Arc Gateway '$GATEWAY_NAME' in '$LOCATION'..."
    create_gateway "$GATEWAY_NAME" "$RESOURCE_GROUP" "$LOCATION"
    GATEWAY_JSON=$(get_gateway_json "$GATEWAY_NAME" "$RESOURCE_GROUP")
    if [[ -z "$GATEWAY_JSON" ]]; then
        echo "ERROR: Arc Gateway '$GATEWAY_NAME' was created but could not be queried afterwards." >&2
        exit 1
    fi
else
    echo "Arc Gateway '$GATEWAY_NAME' already exists. Reusing it."
fi

GATEWAY_ID=$(get_gateway_value "$GATEWAY_NAME" "$RESOURCE_GROUP" id)
echo "Waiting for Arc Gateway provisioning to complete (this can take several minutes)..."
run_az resource wait --ids "$GATEWAY_ID" --custom "properties.provisioningState=='Succeeded'" --interval 30 --timeout 1800 --only-show-errors >/dev/null
GATEWAY_JSON=$(get_gateway_json "$GATEWAY_NAME" "$RESOURCE_GROUP")
GATEWAY_ENDPOINT=$(get_gateway_value "$GATEWAY_NAME" "$RESOURCE_GROUP" properties.gatewayEndpoint)

echo ""
echo "============================================="
echo " Arc Gateway Ready"
echo "============================================="
echo " Gateway Resource ID : $GATEWAY_ID"
if [[ -n "$GATEWAY_ENDPOINT" ]]; then
    echo " Gateway Endpoint    : $GATEWAY_ENDPOINT"
fi
echo " Location            : $LOCATION"
echo ""

if [[ "$CONFIGURE" == true ]]; then
    echo "Associating the Arc resources and configuring the agents to use the gateway..."
    update_arcgateway_settings "$GATEWAY_ID"
    invoke_agent_configuration "gateway" "$GATEWAY_ID"

    echo ""
    echo "Validation commands:"
    echo "  az arcgateway show --name $GATEWAY_NAME --resource-group $RESOURCE_GROUP"
    echo "  azcmagent show"
    echo "  azcmagent check"
else
    show_manual_instructions "$GATEWAY_ID"
fi

echo ""
echo "Next step: wait 15-30 minutes and compare Azure Firewall logs before and after enabling the gateway."
