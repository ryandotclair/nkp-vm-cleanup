#!/bin/bash
set -uo pipefail

# NKP / Nutanix cleanup: PVC volume groups + optional VM delete. Use --discover for read-only inventory
# (same K8s category + PVC rules as honey-badger Infrastructure-report.sh).
# Categories: KubernetesClusterName / kubernetes_cluster_name on metadata or spec.
# Discover CP vs worker: per cluster, min hyphen-segment count in VM name = control plane; longer = worker.

_PRE_NUTANIX_USER="${NUTANIX_USER-}"
_PRE_NUTANIX_PASSWORD="${NUTANIX_PASSWORD-}"
_PRE_NUTANIX_ENDPOINT="${NUTANIX_ENDPOINT-}"

RED='\033[0;31m'
NC='\033[0m'
error() { echo -e "${RED}ERROR:${NC} $1" >&2; }

# "Step N: ..." lines only when --debug (keeps default output minimal).
step_echo() { [ "$DEBUG_DETACH" = true ] && echo "$1"; }

usage() {
    cat << EOF
Usage:
  $0 --discover [--debug]
  $0 --cluster <name> [--detach-only | --vms] [--debug]
  $0 --volumes <file> [--debug]

  --discover             Read-only: print clusters / controllers / workers / PVCs.

Only discovers powered off VMs (safety mechanism). All destructive actions will prompt for confirmation before proceeding.

Use Cases:
  # Dettach and Delete VGs in one run:
  $0 --cluster <name>

  # Dettach VGs only (outputs volumes.list.tmp for later delete):
  $0 --cluster <name> --detach-only
  
  # Delete VGs (requires volumes.list.tmp from previous step):
  $0 --volumes volumes.list.tmp

  # Delete VMs:
  $0 --cluster <name> --vms

  # Inventory report (no cluster filter; not destructive):
  $0 --discover

Prism Central credentials (required). 3 Options, in order of precedence:

  1) Export before running:
       export NUTANIX_ENDPOINT=https://<pc-host>:9440
       export NUTANIX_USER=<user>
       export NUTANIX_PASSWORD='<password>'

  2) Add exports to env.vars next to this script (same directory), defining the three variables above.

  3) CLI overrides: --pc <url>  --user <name>  --password <secret>
     (--pc may be https://fqdn_or_IP:9440 or fqdn_or_IP:9440)

Other:
  --debug                Show \"Step N: ...\" labels; API / detach debugging (see mode).
  -h, --help             Shows this help and exit.

Requires: jq, curl.

EOF
    exit 1
}

CLUSTER_NAME_ARG=""
VOLUMES_FILE=""
DETACH_ONLY=false
DELETE_VMS_ONLY=false
DISCOVER_ONLY=false
DEBUG_DETACH=false
OPT_PC=""
OPT_USER=""
OPT_PASS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --cluster)
            if [ $# -lt 2 ]; then
                error "--cluster requires a value"
                usage
            fi
            CLUSTER_NAME_ARG="$2"
            shift 2
            ;;
        --volumes)
            if [ $# -lt 2 ]; then
                error "--volumes requires a file path"
                usage
            fi
            VOLUMES_FILE="$2"
            shift 2
            ;;
        --detach-only)
            DETACH_ONLY=true
            shift
            ;;
        --vms)
            DELETE_VMS_ONLY=true
            shift
            ;;
        --discover)
            DISCOVER_ONLY=true
            shift
            ;;
        --debug)
            DEBUG_DETACH=true
            shift
            ;;
        --pc)
            if [ $# -lt 2 ]; then
                error "--pc requires a value"
                usage
            fi
            OPT_PC="$2"
            shift 2
            ;;
        --user)
            if [ $# -lt 2 ]; then
                error "--user requires a value"
                usage
            fi
            OPT_USER="$2"
            shift 2
            ;;
        --password)
            if [ $# -lt 2 ]; then
                error "--password requires a value"
                usage
            fi
            OPT_PASS="$2"
            shift 2
            ;;
        -h|--help) usage ;;
        *)
            error "Unknown option: $1"
            usage
            ;;
    esac
done

if [ "$DISCOVER_ONLY" = true ]; then
    if [ -n "$VOLUMES_FILE" ] || [ -n "$CLUSTER_NAME_ARG" ] || [ "$DETACH_ONLY" = true ] || [ "$DELETE_VMS_ONLY" = true ]; then
        error "--discover cannot be combined with --cluster, --volumes, --detach-only, or --vms"
        exit 1
    fi
fi

if [ "$DELETE_VMS_ONLY" = true ]; then
    if [ -n "$VOLUMES_FILE" ]; then
        error "--vms cannot be used with --volumes"
        exit 1
    fi
    if [ "$DETACH_ONLY" = true ]; then
        error "--vms cannot be used with --detach-only"
        exit 1
    fi
    if [ -z "$CLUSTER_NAME_ARG" ]; then
        error "--vms requires --cluster <cluster-name>"
        exit 1
    fi
fi

# Validate: need either --discover, --cluster, or --volumes
if [ "$DISCOVER_ONLY" = true ]; then
    CLUSTER_NAME=""
elif [ -n "$VOLUMES_FILE" ]; then
    if [ ! -f "$VOLUMES_FILE" ]; then
        error "Volumes file not found: $VOLUMES_FILE"
        exit 1
    fi
    CLUSTER_NAME="${CLUSTER_NAME_ARG:-from file}"
elif [ -z "$CLUSTER_NAME_ARG" ]; then
    error "One of --discover, --cluster, or --volumes is required (see -h / --help)"
    exit 1
else
    CLUSTER_NAME="$CLUSTER_NAME_ARG"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_VARS_FILE="${SCRIPT_DIR}/env.vars"
if [ -f "$ENV_VARS_FILE" ]; then
    # shellcheck source=/dev/null
    source "$ENV_VARS_FILE"
fi

# Pre-exported env wins over env.vars
[ -n "$_PRE_NUTANIX_USER" ] && NUTANIX_USER="$_PRE_NUTANIX_USER"
[ -n "$_PRE_NUTANIX_PASSWORD" ] && NUTANIX_PASSWORD="$_PRE_NUTANIX_PASSWORD"
[ -n "$_PRE_NUTANIX_ENDPOINT" ] && NUTANIX_ENDPOINT="$_PRE_NUTANIX_ENDPOINT"

# CLI overrides everything
[ -n "$OPT_PC" ] && NUTANIX_ENDPOINT="$OPT_PC"
[ -n "$OPT_USER" ] && NUTANIX_USER="$OPT_USER"
[ -n "$OPT_PASS" ] && NUTANIX_PASSWORD="$OPT_PASS"

NUTANIX_USER="${NUTANIX_USER:-admin}"

CRED_ERR=""
[ -z "${NUTANIX_ENDPOINT:-}" ] && CRED_ERR="${CRED_ERR} NUTANIX_ENDPOINT is empty (export it, use env.vars next to script, or --pc)."$'\n'
[ -z "${NUTANIX_PASSWORD:-}" ] && CRED_ERR="${CRED_ERR} NUTANIX_PASSWORD is empty (export it, use env.vars, or --password)."$'\n'
if [ -n "$CRED_ERR" ]; then
    error "Missing Prism Central credentials:"
    printf '%s' "$CRED_ERR" >&2
    exit 1
fi

# API behavior: timeout (seconds), retries for delete (transient errors), delay between VG deletes (seconds)
CURL_TIMEOUT="${CURL_TIMEOUT:-90}"
DELETE_RETRIES="${DELETE_RETRIES:-3}"
DELETE_RETRY_DELAYS="2 5 10"
DELAY_BETWEEN_VGS="${DELAY_BETWEEN_VGS:-3}"
# Wait after detach before attempting delete (PC may need time to complete detach task)
DETACH_WAIT_SECONDS="${DETACH_WAIT_SECONDS:-30}"
# v3 list API page size (max 500 per Nutanix docs); script pages with offset until all entities are fetched
LIST_PAGE_SIZE="${LIST_PAGE_SIZE:-500}"

command -v jq &>/dev/null || { error "jq is required"; exit 1; }

# Parse endpoint URL - extract IP and port
if [[ "$NUTANIX_ENDPOINT" =~ ^https?://([^:/]+)(:([0-9]+))? ]]; then
    PC_IP="${BASH_REMATCH[1]}"
    PC_PORT="${BASH_REMATCH[3]:-9440}"
elif [[ "$NUTANIX_ENDPOINT" =~ ^([^:/]+)(:([0-9]+))? ]]; then
    PC_IP="${BASH_REMATCH[1]}"
    PC_PORT="${BASH_REMATCH[3]:-9440}"
else
    error "Could not parse NUTANIX_ENDPOINT: $NUTANIX_ENDPOINT"
    exit 1
fi

PC_BASE_URL="https://${PC_IP}:${PC_PORT}"

echo "Connecting to Prism Central: $PC_BASE_URL"
echo "User: $NUTANIX_USER"
if [ "$DISCOVER_ONLY" = true ]; then
    echo "Mode: Infrastructure report (--discover, read-only)"
elif [ -n "$CLUSTER_NAME" ]; then
    echo "Cluster filter: $CLUSTER_NAME"
fi
if [ "$DELETE_VMS_ONLY" = true ]; then
    echo "Mode: DELETE VMs only (powered-off VMs matching cluster categories)"
elif [ "$DETACH_ONLY" = true ]; then
    echo "Mode: DETACH ONLY (no VG deletion; run without --detach-only to delete VGs, then --cluster <name> --vms to delete the powered-off VMs)"
fi
if [ "$DEBUG_DETACH" = true ]; then
    if [ "$DISCOVER_ONLY" = true ]; then
        echo "Debug: --discover — VM list stats and API request/response details on stderr."
    elif [ "$DELETE_VMS_ONLY" = true ]; then
        echo "Debug: curl timeout ${CURL_TIMEOUT}s per API request."
    else
        echo "Debug: Volume-group workflow settings — curl timeout ${CURL_TIMEOUT}s; up to ${DELETE_RETRIES} delete retries on transient errors; ${DELAY_BETWEEN_VGS}s between VGs; ${DETACH_WAIT_SECONDS}s wait after detach before delete."
        echo "Debug: Printing detach API response snippets during storage steps."
    fi
fi
echo ""

# Print detach API response for debugging (when --debug is set)
debug_detach_response() {
    local label=$1
    local body=$2
    [ "$DEBUG_DETACH" != true ] && return
    echo "    [DEBUG] $label response:"
    if [ -z "$body" ]; then
        echo "      (empty body)"
    else
        local out
        out=$(echo "$body" | jq -c . 2>/dev/null || echo "$body")
        echo "${out:0:1200}"
        [ ${#out} -gt 1200 ] && echo "... (truncated)"
    fi
    echo "    [DEBUG] ---"
}

# Generate a UUID for request ID
generate_request_id() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        # Fallback: generate a simple UUID-like string
        cat /dev/urandom 2>/dev/null | tr -dc 'a-f0-9' | fold -w 8 | head -n 1 | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/' || echo "fallback-$(date +%s)-$$"
    fi
}

# Function to make API calls to Prism Central
api_call() {
    local method=$1
    local endpoint=$2
    local data=${3:-}
    local request_id=${4:-}
    
    # Generate request ID if not provided (required for volume-group DELETE and POST actions)
    if [ -z "$request_id" ]; then
        request_id=$(generate_request_id)
    fi
    
    if [ "$method" = "POST" ]; then
        if [ -n "$data" ]; then
            # POST with data (like detach action) - requires NTNX-Request-Id
            curl -k -s --max-time "$CURL_TIMEOUT" \
                -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                -H "NTNX-Request-Id: ${request_id}" \
                -X POST \
                -d "$data" \
                "${PC_BASE_URL}${endpoint}"
        else
            # POST without data (like list API)
            curl -k -s --max-time "$CURL_TIMEOUT" \
                -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                -X POST \
                "${PC_BASE_URL}${endpoint}"
        fi
    elif [ "$method" = "DELETE" ]; then
        # DELETE requires NTNX-Request-Id
        curl -k -s --max-time "$CURL_TIMEOUT" \
            -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
            -H "Accept: application/json" \
            -H "NTNX-Request-Id: ${request_id}" \
            -X DELETE \
            "${PC_BASE_URL}${endpoint}"
    elif [ "$method" = "PUT" ]; then
        # PUT with body (e.g. VM update)
        curl -k -s --max-time "$CURL_TIMEOUT" \
            -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -X PUT \
            -d "$data" \
            "${PC_BASE_URL}${endpoint}"
    elif [ "$method" = "GET" ]; then
        curl -k -s --max-time "$CURL_TIMEOUT" \
            -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
            -H "Accept: application/json" \
            -X GET \
            "${PC_BASE_URL}${endpoint}"
    fi
}

# Prism Central v3 POST .../list: repeat offset + length (LIST_PAGE_SIZE) until all entities are returned.
# Arg: kind vm | volume_group. Prints one JSON object { entities: [...], metadata: { total_matches } }.
api_v3_list_all_entities() {
    local listKind="${1:?}"
    local endpoint
    case "$listKind" in
        vm) endpoint="/api/nutanix/v3/vms/list" ;;
        volume_group) endpoint="/api/nutanix/v3/volume_groups/list" ;;
        *) error "api_v3_list_all_entities: invalid kind '$listKind'"; return 1 ;;
    esac
    local pageSize="${LIST_PAGE_SIZE:-500}"
    # Nutanix v3 list typically caps length at 500 per request
    if [ "$pageSize" -gt 500 ] 2>/dev/null; then
        pageSize=500
    fi
    if [ "$pageSize" -lt 1 ] 2>/dev/null; then
        pageSize=500
    fi
    local offset=0
    # Use temporary files instead of in-memory arrays for large datasets
    local merged_file page_file next_file
    merged_file=$(mktemp) || return 1
    page_file="${merged_file}.page"
    next_file="${merged_file}.next"
    trap 'rm -f "$merged_file" "$page_file" "$next_file"' RETURN
    echo '[]' > "$merged_file"
    local resp
    local pages=0
    local first_page_tm
    first_page_tm="null"

    while true; do
        local payload
        payload=$(jq -n \
            --arg kind "$listKind" \
            --argjson length "$pageSize" \
            --argjson o "$offset" \
            '{kind: $kind, length: $length, offset: $o}')
        resp=$(api_call "POST" "$endpoint" "$payload")
        if ! echo "$resp" | jq -e '.' >/dev/null 2>&1; then
            error "Invalid JSON from ${endpoint} at offset ${offset}"
            echo "$resp" >&2
            return 1
        fi
        pages=$((pages + 1))
        if [ "$pages" -eq 1 ]; then
            first_page_tm=$(echo "$resp" | jq -c '.metadata.total_matches // null')
        fi
        local count
        count=$(echo "$resp" | jq '.entities | length // 0')
        echo "$resp" | jq '[.entities[]?]' > "$page_file" || return 1
        jq -s '.[0] + .[1]' "$merged_file" "$page_file" > "$next_file" && mv "$next_file" "$merged_file" || return 1
        offset=$((offset + count))
        if [ "$count" -eq 0 ]; then
            break
        fi
        if [ "$count" -lt "$pageSize" ]; then
            break
        fi
        if echo "$first_page_tm" | jq -e 'type == "number"' >/dev/null 2>&1; then
            local tot
            tot=$(echo "$first_page_tm" | jq -r '.')
            if [ "$offset" -ge "$tot" ] 2>/dev/null; then
                break
            fi
        fi
    done

    if [ "$DEBUG_DETACH" = true ]; then
        local merged_len
        merged_len=$(jq 'length' "$merged_file")
        echo "DEBUG: ${listKind} list: ${pages} HTTP page(s), merged_entities=${merged_len}, PC total_matches=${first_page_tm}" >&2
    fi

    jq -c --argjson tf "$first_page_tm" '{entities: ., metadata: {total_matches: (if $tf != null then $tf else length end)}}' "$merged_file"
}

# Read-only report: VMs with any K8s cluster category, pvc-* VGs from disk_list (aligned with Infrastructure-report.sh).
run_infrastructure_report() {
    local VM_LIST_RESPONSE VG_LIST_RESPONSE K8S_VMS SORTED_VMS UNIQUE_CLUSTERS
    local TEMP_PVC_MAP TEMP_CLUSTER_CONTROLLERS TEMP_CLUSTER_WORKERS TEMP_CLUSTER_LIST TEMP_VM_NF TEMP_CLUSTER_MIN
    local TOTAL_MATCHES ENTITIES_COUNT VM_COUNT CONTROLLER_COUNT WORKER_COUNT TOTAL_PVCS CLUSTER_COUNT
    local CLUSTER_NAME CURRENT_CLUSTER FIRST_CLUSTER CLUSTER_CONTROLLERS CLUSTER_WORKERS
    local vm_json VM_UUID VM_NAME VM_VG_UUIDS vg_uuid PVC_NAME VM_PVCS pvc_name
    local nf min_segs worker_count worker_idx
    local VM_CPU VM_MEMORY_MIB VM_MEMORY_GB

    step_echo "Step 1: Fetching VMs with Kubernetes cluster names..."
    VM_LIST_RESPONSE=$(api_v3_list_all_entities vm) || exit 1

    if ! echo "$VM_LIST_RESPONSE" | jq -e '.' >/dev/null 2>&1; then
        error "Invalid JSON response from VM list API"
        echo "Response: $VM_LIST_RESPONSE" >&2
        exit 1
    fi

    if [ "$DEBUG_DETACH" = true ]; then
        TOTAL_MATCHES=$(echo "$VM_LIST_RESPONSE" | jq -r '.metadata.total_matches // 0' 2>/dev/null || echo "0")
        ENTITIES_COUNT=$(echo "$VM_LIST_RESPONSE" | jq -r '.entities | length // 0' 2>/dev/null || echo "0")
        echo "DEBUG: VM list — total_matches=$TOTAL_MATCHES entities_merged=$ENTITIES_COUNT (paged, LIST_PAGE_SIZE=${LIST_PAGE_SIZE})" >&2
        echo "DEBUG: VM list merged response (JSON):" >&2
        echo "$VM_LIST_RESPONSE" | jq '.' >&2 2>/dev/null || echo "$VM_LIST_RESPONSE" >&2
        echo "" >&2
    fi

    # Same inclusion rules as discover_powered_off_k8s_cluster_vms (any of four category keys non-empty).
    K8S_VMS=$(echo "$VM_LIST_RESPONSE" | jq -c '
        .entities[]? |
        select(
            ((.metadata.categories.KubernetesClusterName // "") != "") or
            ((.metadata.categories.kubernetes_cluster_name // "") != "") or
            ((.spec.categories.KubernetesClusterName // "") != "") or
            ((.spec.categories.kubernetes_cluster_name // "") != "")
        )
    ')

    if [ -z "$K8S_VMS" ]; then
        echo "No VMs with Kubernetes cluster names found."
        if [ "$DEBUG_DETACH" = true ]; then
            echo "DEBUG: No entities matched metadata/spec KubernetesClusterName or kubernetes_cluster_name." >&2
        fi
        exit 0
    fi

    step_echo "Step 2: Fetching volume groups and building VM → PVC mapping (disk_list + pvc- prefix)..."
    VG_LIST_RESPONSE=$(api_v3_list_all_entities volume_group) || exit 1
    if [ "$DEBUG_DETACH" = true ]; then
        echo "DEBUG: Volume group list response (JSON):" >&2
        echo "$VG_LIST_RESPONSE" | jq '.' >&2 2>/dev/null || echo "$VG_LIST_RESPONSE" >&2
        echo "" >&2
    fi

    TEMP_PVC_MAP=$(mktemp)
    TOTAL_PVCS=0
    VM_COUNT=0
    step_echo "  Processing VMs to extract volume group references..."
    while IFS= read -r vm_json; do
        [ -z "$vm_json" ] || [ "$vm_json" = "null" ] && continue
        if ! echo "$vm_json" | jq -e '.' >/dev/null 2>&1; then
            continue
        fi
        VM_COUNT=$((VM_COUNT + 1))
        VM_UUID=$(echo "$vm_json" | jq -r '.metadata.uuid // empty' 2>/dev/null)
        [ -z "$VM_UUID" ] || [ "$VM_UUID" = "null" ] && continue
        VM_VG_UUIDS=$(echo "$vm_json" | jq -r '.spec.resources.disk_list[]? // .status.resources.disk_list[]? // empty | select(.device_properties.device_type == "VOLUME_GROUP") | .volume_group_reference.uuid // empty' 2>/dev/null | grep -v '^$' | grep -v '^null$')
        if [ -n "$VM_VG_UUIDS" ]; then
            while IFS= read -r vg_uuid; do
                [ -z "$vg_uuid" ] || [ "$vg_uuid" = "null" ] && continue
                PVC_NAME=$(echo "$VG_LIST_RESPONSE" | jq -r --arg uuid "$vg_uuid" '.entities[]? | select(.metadata.uuid == $uuid and ((.spec.name // .status.name // "") | startswith("pvc-"))) | .spec.name // .status.name // ""' 2>/dev/null)
                if [ -n "$PVC_NAME" ] && [ "$PVC_NAME" != "null" ]; then
                    echo "$VM_UUID|$PVC_NAME" >> "$TEMP_PVC_MAP"
                    TOTAL_PVCS=$((TOTAL_PVCS + 1))
                fi
            done <<< "$VM_VG_UUIDS"
        fi
    done <<< "$K8S_VMS"

    step_echo "  Processed $VM_COUNT VM(s), found $TOTAL_PVCS PVC attachment(s)"
    echo ""

    SORTED_VMS=$(echo "$K8S_VMS" | jq -s -c '
        def effective_k8s_cluster:
            first([
                .metadata.categories.KubernetesClusterName,
                .metadata.categories.kubernetes_cluster_name,
                .spec.categories.KubernetesClusterName,
                .spec.categories.kubernetes_cluster_name
            ][]? | select(. != null and . != "")
            ) // "zzz-unknown";
        if length > 0 then
            sort_by(effective_k8s_cluster, (.spec.name // .status.name // "zzz-unknown")) | .[]
        else
            empty
        end
    ' 2>/dev/null)

    if [ -z "$SORTED_VMS" ]; then
        echo "No VMs found after sorting."
        rm -f "$TEMP_PVC_MAP"
        exit 0
    fi

    TEMP_CLUSTER_CONTROLLERS=$(mktemp)
    TEMP_CLUSTER_WORKERS=$(mktemp)
    TEMP_CLUSTER_LIST=$(mktemp)
    TEMP_VM_NF=$(mktemp)
    TEMP_CLUSTER_MIN=$(mktemp)
    # Expand paths now: EXIT runs after function returns, so locals are unset (set -u would fail with '...' trap).
    trap "rm -f '${TEMP_PVC_MAP}' '${TEMP_CLUSTER_CONTROLLERS}' '${TEMP_CLUSTER_WORKERS}' '${TEMP_CLUSTER_LIST}' '${TEMP_VM_NF}' '${TEMP_CLUSTER_MIN}'" EXIT

    # Pass 1: cluster list + per-VM hyphen segment count (NF) per cluster. Cluster names may contain '-';
    # CP VMs are the shortest names *within each cluster* (min NF), workers are strictly longer.
    CURRENT_CLUSTER=""
    while IFS= read -r vm_json; do
        [ -z "$vm_json" ] || [ "$vm_json" = "null" ] && continue
        if ! echo "$vm_json" | jq -e '.' >/dev/null 2>&1; then
            continue
        fi
        CLUSTER_NAME=$(echo "$vm_json" | jq -r 'first([.metadata.categories.KubernetesClusterName, .metadata.categories.kubernetes_cluster_name, .spec.categories.KubernetesClusterName, .spec.categories.kubernetes_cluster_name][]? | select(. != null and . != "")) // "unknown"' 2>/dev/null || echo "unknown")
        VM_NAME=$(echo "$vm_json" | jq -r '.spec.name // .status.name // "unknown"' 2>/dev/null || echo "unknown")
        if [ "$CLUSTER_NAME" != "$CURRENT_CLUSTER" ]; then
            if [ -n "$CURRENT_CLUSTER" ]; then
                echo "$CURRENT_CLUSTER" >> "$TEMP_CLUSTER_LIST"
            fi
            CURRENT_CLUSTER="$CLUSTER_NAME"
        fi
        nf=$(printf '%s' "$VM_NAME" | awk -F'-' '{print NF}')
        printf '%s\t%s\n' "$CLUSTER_NAME" "$nf" >> "$TEMP_VM_NF"
    done <<< "$SORTED_VMS"

    awk -F'\t' '
        {
            c = $1
            n = $2 + 0
            if (!(c in min) || n < min[c]) min[c] = n
        }
        END {
            for (c in min) printf "%s\t%d\n", c, min[c]
        }
    ' "$TEMP_VM_NF" > "$TEMP_CLUSTER_MIN"

    CONTROLLER_COUNT=0
    WORKER_COUNT=0
    while IFS= read -r vm_json; do
        [ -z "$vm_json" ] || [ "$vm_json" = "null" ] && continue
        if ! echo "$vm_json" | jq -e '.' >/dev/null 2>&1; then
            continue
        fi
        CLUSTER_NAME=$(echo "$vm_json" | jq -r 'first([.metadata.categories.KubernetesClusterName, .metadata.categories.kubernetes_cluster_name, .spec.categories.KubernetesClusterName, .spec.categories.kubernetes_cluster_name][]? | select(. != null and . != "")) // "unknown"' 2>/dev/null || echo "unknown")
        VM_NAME=$(echo "$vm_json" | jq -r '.spec.name // .status.name // "unknown"' 2>/dev/null || echo "unknown")
        nf=$(printf '%s' "$VM_NAME" | awk -F'-' '{print NF}')
        min_segs=$(awk -F'\t' -v cl="$CLUSTER_NAME" '$1 == cl { print $2 + 0; exit }' "$TEMP_CLUSTER_MIN")
        [ -z "$min_segs" ] && min_segs="$nf"
        if [ "$nf" -gt "$min_segs" ]; then
            echo "${CLUSTER_NAME}|${vm_json}" >> "$TEMP_CLUSTER_WORKERS"
            WORKER_COUNT=$((WORKER_COUNT + 1))
        else
            echo "${CLUSTER_NAME}|${vm_json}" >> "$TEMP_CLUSTER_CONTROLLERS"
            CONTROLLER_COUNT=$((CONTROLLER_COUNT + 1))
        fi
    done <<< "$SORTED_VMS"

    if [ -n "$CURRENT_CLUSTER" ]; then
        echo "$CURRENT_CLUSTER" >> "$TEMP_CLUSTER_LIST"
    fi

    UNIQUE_CLUSTERS=$(sort -u "$TEMP_CLUSTER_LIST" 2>/dev/null)

    FIRST_CLUSTER=true
    while IFS= read -r CLUSTER_NAME; do
        [ -z "$CLUSTER_NAME" ] && continue
        if [ "$FIRST_CLUSTER" != true ]; then
            echo ""
        fi
        echo "$CLUSTER_NAME"
        FIRST_CLUSTER=false

        echo "|_Controller Nodes"
        CLUSTER_CONTROLLERS=$(grep "^${CLUSTER_NAME}|" "$TEMP_CLUSTER_CONTROLLERS" 2>/dev/null | cut -d'|' -f2-)
        if [ -n "$CLUSTER_CONTROLLERS" ]; then
            while IFS= read -r vm_json; do
                [ -z "$vm_json" ] || [ "$vm_json" = "null" ] && continue
                VM_UUID=$(echo "$vm_json" | jq -r '.metadata.uuid // empty' 2>/dev/null || echo "")
                VM_NAME=$(echo "$vm_json" | jq -r '.spec.name // .status.name // "unknown"' 2>/dev/null || echo "unknown")
                VM_CPU=$(echo "$vm_json" | jq -r '.spec.resources.num_sockets // 0' 2>/dev/null || echo "0")
                VM_MEMORY_MIB=$(echo "$vm_json" | jq -r '.spec.resources.memory_size_mib // 0' 2>/dev/null || echo "0")
                VM_MEMORY_GB=$(echo "$VM_MEMORY_MIB" | awk '{printf "%.2f", $1/1024}')
                echo "|  |_$VM_NAME (vCPU: $VM_CPU | Memory: $VM_MEMORY_GB GB)"
                VM_PVCS=$(grep "^${VM_UUID}|" "$TEMP_PVC_MAP" | cut -d'|' -f2 | sort)
                if [ -n "$VM_PVCS" ]; then
                    while IFS= read -r pvc_name; do
                        [ -n "$pvc_name" ] && echo "|  |  |_$pvc_name"
                    done <<< "$VM_PVCS"
                fi
            done <<< "$CLUSTER_CONTROLLERS"
        else
            echo "|   |_(none found)"
        fi

        echo "|_Worker Nodes"
        CLUSTER_WORKERS=$(grep "^${CLUSTER_NAME}|" "$TEMP_CLUSTER_WORKERS" 2>/dev/null | cut -d'|' -f2-)
        if [ -n "$CLUSTER_WORKERS" ]; then
            worker_count=$(awk -F'|' -v cl="$CLUSTER_NAME" '$1 == cl { c++ } END { print c + 0 }' "$TEMP_CLUSTER_WORKERS")
            worker_idx=0
            while IFS= read -r vm_json; do
                [ -z "$vm_json" ] || [ "$vm_json" = "null" ] && continue
                VM_UUID=$(echo "$vm_json" | jq -r '.metadata.uuid // empty' 2>/dev/null || echo "")
                VM_NAME=$(echo "$vm_json" | jq -r '.spec.name // .status.name // "unknown"' 2>/dev/null || echo "unknown")
                VM_CPU=$(echo "$vm_json" | jq -r '.spec.resources.num_sockets // 0' 2>/dev/null || echo "0")
                VM_MEMORY_MIB=$(echo "$vm_json" | jq -r '.spec.resources.memory_size_mib // 0' 2>/dev/null || echo "0")
                VM_MEMORY_GB=$(echo "$VM_MEMORY_MIB" | awk '{printf "%.2f", $1/1024}')
                worker_idx=$((worker_idx + 1))
                echo "   |_$VM_NAME (vCPU: $VM_CPU | Memory: $VM_MEMORY_GB GB)"
                VM_PVCS=$(grep "^${VM_UUID}|" "$TEMP_PVC_MAP" | cut -d'|' -f2 | sort)
                if [ -n "$VM_PVCS" ]; then
                    while IFS= read -r pvc_name; do
                        if [ -n "$pvc_name" ]; then
                            if [ "$worker_idx" -eq "$worker_count" ]; then
                                echo "      |_$pvc_name"
                            else
                                echo "   |  |_$pvc_name"
                            fi
                        fi
                    done <<< "$VM_PVCS"
                fi
            done <<< "$CLUSTER_WORKERS"
        else
            echo "   |_(none found)"
        fi
    done <<< "$UNIQUE_CLUSTERS"

    echo ""
    echo "=========================================="
    CLUSTER_COUNT=$(echo "$K8S_VMS" | jq -s '[.[] | first([.metadata.categories.KubernetesClusterName, .metadata.categories.kubernetes_cluster_name, .spec.categories.KubernetesClusterName, .spec.categories.kubernetes_cluster_name][]? | select(. != null and . != ""))] | unique | length' 2>/dev/null || echo "0")
    VM_COUNT=$(echo "$K8S_VMS" | jq -s 'length' 2>/dev/null || echo "0")
    echo "Summary:"
    echo "  Clusters: $CLUSTER_COUNT"
    echo "  Total VMs: $VM_COUNT"
    echo "  Controller nodes: $CONTROLLER_COUNT"
    echo "  Worker nodes: $WORKER_COUNT"
    echo "  PVCs attached to these VMs: $TOTAL_PVCS"
    echo "=========================================="
}

if [ "$DISCOVER_ONLY" = true ]; then
    run_infrastructure_report
    exit 0
fi

# API: POST /api/nutanix/v3/vms/list (paged); filter OFF + KubernetesClusterName / kubernetes_cluster_name on metadata/spec.categories.
# Sets globals: VM_LIST_RESPONSE, POWERED_OFF_VMS (one JSON object per line), POWERED_OFF_VM_UUIDS, POWERED_OFF_COUNT
discover_powered_off_k8s_cluster_vms() {
    local clusterName="${1:?}"
    step_echo "Step 1: Finding powered-off VMs in cluster '$clusterName'..."
    VM_LIST_RESPONSE=$(api_v3_list_all_entities vm) || exit 1
    POWERED_OFF_VMS=$(echo "$VM_LIST_RESPONSE" | jq -c --arg cluster "$clusterName" '
        .entities[]? |
        select(.status.resources.power_state == "OFF") |
        select(
            ((.metadata.categories.KubernetesClusterName // "") == $cluster) or
            ((.metadata.categories.kubernetes_cluster_name // "") == $cluster) or
            ((.spec.categories.KubernetesClusterName // "") == $cluster) or
            ((.spec.categories.kubernetes_cluster_name // "") == $cluster)
        )
    ')
    POWERED_OFF_VM_UUIDS=$(printf '%s\n' "$POWERED_OFF_VMS" | while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        echo "$_line" | jq -r '.metadata.uuid // empty' 2>/dev/null
    done | grep -v '^$' | grep -v '^null$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # grep -c exits 1 when count is 0; do not use "|| echo 0" or $() captures "0\n0" and breaks [ -eq ].
    POWERED_OFF_COUNT=$(printf '%s\n' "$POWERED_OFF_VM_UUIDS" | grep -ce '[^[:space:]]' || true)
    POWERED_OFF_COUNT=${POWERED_OFF_COUNT:-0}
}

lookup_vm_name_from_powered_off_stream() {
    local targetUuid="${1:?}"
    while IFS= read -r vm_json; do
        [ -z "$vm_json" ] && continue
        local u
        u=$(echo "$vm_json" | jq -r '.metadata.uuid // empty' 2>/dev/null)
        [ "$u" = "$targetUuid" ] || continue
        echo "$vm_json" | jq -r '.spec.name // .status.name // "unknown"' 2>/dev/null
        return 0
    done <<< "$POWERED_OFF_VMS"
    echo "unknown"
}

# --- Delete powered-off VMs only (--cluster + --vms) ---
if [ "$DELETE_VMS_ONLY" = true ]; then
    discover_powered_off_k8s_cluster_vms "$CLUSTER_NAME"
    if [ "$POWERED_OFF_COUNT" -eq 0 ]; then
        echo "No powered-off VMs found in cluster '$CLUSTER_NAME'."
        exit 0
    fi
    echo "Found $POWERED_OFF_COUNT powered-off VM(s) in cluster '$CLUSTER_NAME':"
    echo ""
    while IFS= read -r vm_json; do
        [ -z "$vm_json" ] || [ "$vm_json" = "null" ] && continue
        VM_UUID=$(echo "$vm_json" | jq -r '.metadata.uuid // empty')
        VM_NAME=$(echo "$vm_json" | jq -r '.spec.name // .status.name // "unknown"')
        [ -n "$VM_UUID" ] && echo "  - $VM_NAME (UUID: $VM_UUID)"
    done <<< "$POWERED_OFF_VMS"
    echo ""
    read -p "Delete these $POWERED_OFF_COUNT VM(s) via DELETE /api/nutanix/v3/vms/{uuid}? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Cancelled."
        exit 0
    fi
    echo ""
    echo "Deleting VMs..."
    DELETED_COUNT=0
    FAILED_COUNT=0
    while IFS= read -r vm_uuid; do
        [ -z "$vm_uuid" ] || [ "$vm_uuid" = "null" ] && continue
        VM_NAME=$(lookup_vm_name_from_powered_off_stream "$vm_uuid")
        if [ -z "$VM_NAME" ] || [ "$VM_NAME" = "unknown" ]; then
            VM_NAME="$vm_uuid"
        fi
        echo "  Deleting VM: $VM_NAME ($vm_uuid)..."
        RESPONSE=$(api_call "DELETE" "/api/nutanix/v3/vms/${vm_uuid}" 2>/dev/null)
        if echo "$RESPONSE" | jq -e '.metadata.uuid' >/dev/null 2>&1; then
            echo "    ✓ Delete accepted"
            DELETED_COUNT=$((DELETED_COUNT + 1))
        elif ! echo "$RESPONSE" | jq -e '.message_list' >/dev/null 2>&1 && [ -n "$RESPONSE" ]; then
            echo "    ✓ Delete accepted (202)"
            DELETED_COUNT=$((DELETED_COUNT + 1))
        elif [ -z "$RESPONSE" ]; then
            echo "    ✓ Delete accepted"
            DELETED_COUNT=$((DELETED_COUNT + 1))
        else
            ERR=$(echo "$RESPONSE" | jq -r '.message_list[0].message // .message // "unknown"' 2>/dev/null)
            echo "    ✗ Failed: $ERR"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    done <<< "$POWERED_OFF_VM_UUIDS"
    echo ""
    echo "=========================================="
    echo "Summary:"
    echo "  Delete accepted: $DELETED_COUNT"
    echo "  Failed:          $FAILED_COUNT"
    echo "=========================================="
    echo ""
    echo "Note: VM delete is asynchronous (often 202). Check Prism Central tasks for completion."
    exit 0
fi

# Step 1 & 2: Either discover VGs from cluster VMs, or load from --volumes file
if [ -n "$VOLUMES_FILE" ]; then
    echo "Loading volume group list from: $VOLUMES_FILE"
    VGS_TO_DELETE=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if echo "$line" | jq -e '.uuid and .name' >/dev/null 2>&1; then
            if [ -z "$VGS_TO_DELETE" ]; then
                VGS_TO_DELETE="$line"
            else
                VGS_TO_DELETE="$VGS_TO_DELETE"$'\n'"$line"
            fi
        fi
    done < "$VOLUMES_FILE"
    VG_COUNT=$(echo "$VGS_TO_DELETE" | jq -s 'length' 2>/dev/null || echo "0")
    if [ "$VG_COUNT" -eq 0 ]; then
        echo "ERROR: No valid volume group entries (uuid, name) found in $VOLUMES_FILE" >&2
        exit 1
    fi
    echo "  Loaded $VG_COUNT volume group(s)"
    echo ""
    echo "Fetching current volume group state from Prism Central (for attachment check)..."
    VG_LIST_RESPONSE=$(api_v3_list_all_entities volume_group) || exit 1
    echo ""
else
# Step 1: same VM discovery as --vms mode (discover_powered_off_k8s_cluster_vms)
discover_powered_off_k8s_cluster_vms "$CLUSTER_NAME"

if [ "$POWERED_OFF_COUNT" -eq 0 ]; then
    echo "No powered-off VMs found in cluster '$CLUSTER_NAME'."
    exit 0
fi

echo "Found $POWERED_OFF_COUNT powered-off VM(s) in cluster '$CLUSTER_NAME'"
echo ""

# Step 2: Get all volume groups and find PVCs attached to powered-off VMs using direct match
step_echo "Step 2: Finding volume groups (PVCs) attached to powered-off VMs..."
echo "  Note: This will find PVCs attached to powered-off VMs in cluster '$CLUSTER_NAME'"
echo "  Using direct match from VM disk_list (more reliable than reverse lookup)"
echo ""
VG_LIST_RESPONSE=$(api_v3_list_all_entities volume_group) || exit 1

# Use direct match approach: Extract volume group UUIDs from powered-off VMs' disk_list
# and match them to PVCs in the LIST response
VGS_TO_DELETE=""
MATCHED=0

echo "  Extracting volume group references from powered-off VMs..."
while IFS= read -r vm_json; do
    if [ -z "$vm_json" ] || [ "$vm_json" = "null" ] || [ "$vm_json" = "" ]; then
        continue
    fi
    
    # Validate JSON
    if ! echo "$vm_json" | jq -e '.' >/dev/null 2>&1; then
        continue
    fi
    
    VM_UUID=$(echo "$vm_json" | jq -r '.metadata.uuid // empty' 2>/dev/null)
    VM_NAME=$(echo "$vm_json" | jq -r '.spec.name // .status.name // "unknown"' 2>/dev/null)
    
    if [ -z "$VM_UUID" ] || [ "$VM_UUID" = "null" ]; then
        continue
    fi
    
    # Extract volume group UUIDs from VM disk_list
    VM_VG_UUIDS=$(echo "$vm_json" | jq -r '.spec.resources.disk_list[]? // .status.resources.disk_list[]? // empty | select(.device_properties.device_type == "VOLUME_GROUP") | .volume_group_reference.uuid // empty' 2>/dev/null | grep -v '^$' | grep -v '^null$')
        
    # For each volume group UUID, check if it's a PVC and store for deletion
    if [ -n "$VM_VG_UUIDS" ]; then
        while IFS= read -r vg_uuid; do
            if [ -z "$vg_uuid" ] || [ "$vg_uuid" = "null" ]; then
                    continue
                fi
            
            # Check if this volume group UUID is a PVC (name starts with "pvc-") in the LIST response
            PVC_INFO=$(echo "$VG_LIST_RESPONSE" | jq -c --arg uuid "$vg_uuid" '.entities[]? | select(.metadata.uuid == $uuid and ((.spec.name // .status.name // "") | startswith("pvc-"))) | {uuid: .metadata.uuid, name: (.spec.name // .status.name)}' 2>/dev/null)
            
            if [ -n "$PVC_INFO" ] && [ "$PVC_INFO" != "null" ]; then
                PVC_UUID=$(echo "$PVC_INFO" | jq -r '.uuid // empty')
                PVC_NAME=$(echo "$PVC_INFO" | jq -r '.name // empty')
                
                if [ -n "$PVC_UUID" ] && [ -n "$PVC_NAME" ]; then
                    # Check if we've already added this PVC (avoid duplicates)
                    if ! echo "$VGS_TO_DELETE" | jq -s -e --arg uuid "$PVC_UUID" '.[] | select(.uuid == $uuid)' >/dev/null 2>&1; then
            MATCHED=$((MATCHED + 1))
                        MATCH_ENTRY=$(jq -n --arg uuid "$PVC_UUID" --arg name "$PVC_NAME" --arg vm "$VM_UUID" --arg vm_name "$VM_NAME" '{uuid: $uuid, name: $name, attached_vm: $vm, attached_vm_name: $vm_name}')
            if [ -z "$VGS_TO_DELETE" ]; then
                VGS_TO_DELETE="$MATCH_ENTRY"
            else
                VGS_TO_DELETE="$VGS_TO_DELETE"$'\n'"$MATCH_ENTRY"
            fi
        fi
    fi
            fi
        done <<< "$VM_VG_UUIDS"
    fi
done <<< "$POWERED_OFF_VMS"

VG_COUNT=$(echo "$VGS_TO_DELETE" | jq -s 'length' || echo "0")
echo "  Found $VG_COUNT PVC(s) attached to powered-off VMs"
echo ""

if [ "$VG_COUNT" -eq 0 ]; then
    echo "No volume groups found attached to powered-off VMs in cluster '$CLUSTER_NAME'."
    echo ""
    echo "  Possible reasons:"
    echo "    1. PVCs are attached to VMs in a different cluster (not '$CLUSTER_NAME')"
    echo "    2. PVCs are attached to VMs that are powered ON"
    echo "    3. No PVCs exist for this cluster"
    echo ""
    echo "  Tip: Check the debug output above to see which clusters the attached VMs belong to."
    echo "  You may need to run this script with a different --cluster value (e.g., 'konnkp', 'kon-hoihoi', 'mgmt-cluster')."
    exit 0
fi

fi
# end of "discover from cluster" branch

echo "Found $VG_COUNT volume group(s) to process:"
if echo "$VGS_TO_DELETE" | jq -s -e '.[0].attached_vm_name' >/dev/null 2>&1; then
    echo "$VGS_TO_DELETE" | jq -s -r '.[] | "  - \(.name) (UUID: \(.uuid), VM: \(.attached_vm_name // .attached_vm))"'
else
echo "$VGS_TO_DELETE" | jq -s -r '.[] | "  - \(.name) (UUID: \(.uuid), VM: \(.attached_vm))"'
fi
echo ""

# Step 3: Confirm before deletion or detach-only
if [ "$DETACH_ONLY" = true ]; then
    read -p "Do you want to DETACH (only) these $VG_COUNT volume group(s) from their VMs? (yes/no): " CONFIRM
else
    read -p "Do you want to delete these $VG_COUNT volume group(s)? (yes/no): " CONFIRM
fi
if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

# Step 4: Detach and (unless --detach-only) delete volume groups
echo ""
if [ "$DETACH_ONLY" = true ]; then
    step_echo "Step 4: Detaching VMs from volume groups (no deletion)..."
    # Write volume list for later delete run (--volumes volumes.list.tmp)
    VOLUMES_LIST_TMP="volumes.list.tmp"
    echo "$VGS_TO_DELETE" | jq -c -s '.[] | {uuid, name, attached_vm, attached_vm_name}' 2>/dev/null > "$VOLUMES_LIST_TMP"
    echo "  Wrote $VG_COUNT volume group(s) to $VOLUMES_LIST_TMP"
    echo ""
else
    step_echo "Step 4: Detaching VMs and deleting volume groups..."
fi
DELETED_COUNT=0
DETACHED_COUNT=0
FAILED_COUNT=0

# Process each volume group
while IFS= read -r vg_info; do
    if [ -z "$vg_info" ]; then
        continue
    fi
    
    vg_uuid=$(echo "$vg_info" | jq -r '.uuid')
    vg_name=$(echo "$vg_info" | jq -r '.name')
    
    if [ -z "$vg_uuid" ] || [ "$vg_uuid" = "null" ]; then
        echo "  ✗ Skipping invalid volume group entry"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi
    
    echo "Processing: $vg_name (UUID: $vg_uuid)..."
    
    # Step 4a: Get attachment info from LIST response (already have it, no need for individual GET)
    PVC_FROM_LIST=$(echo "$VG_LIST_RESPONSE" | jq -c --arg uuid "$vg_uuid" '.entities[]? | select(.metadata.uuid == $uuid)')
    
    # Extract attachments from LIST response
    ATTACHED_VM_UUIDS=$(echo "$PVC_FROM_LIST" | jq -r '.status.resources.attachment_list[]?.vm_reference.uuid // empty' 2>/dev/null | grep -v '^$' | grep -v '^null$')
    
    # Step 4b: Detach all VMs from the volume group (if any attachments found)
    if [ -n "$ATTACHED_VM_UUIDS" ]; then
        ATTACHMENT_COUNT=$(echo "$ATTACHED_VM_UUIDS" | wc -l | tr -d ' ')
        echo "  Found $ATTACHMENT_COUNT VM attachment(s) in LIST response"
        echo "  Detaching volume group from VM(s)..."
        
        DETACH_SUCCESS=false
        while IFS= read -r vm_uuid; do
            if [ -z "$vm_uuid" ] || [ "$vm_uuid" = "null" ]; then
                continue
            fi
            DETACH_PAYLOAD=$(jq -n \
                --arg vm_uuid "$vm_uuid" \
                '{extId: $vm_uuid, "$objectType": "volumes.v4.config.VmAttachment", "$reserved": {"$fv": "v4.r1"}, "$unknownFields": {}}')
            DETACH_RESPONSE=$(api_call "POST" "/api/volumes/v4.1/config/volume-groups/${vg_uuid}/\$actions/detach-vm" "$DETACH_PAYLOAD" 2>/dev/null)
            debug_detach_response "detach-vm" "$DETACH_RESPONSE"
            if echo "$DETACH_RESPONSE" | jq -e '.error or (.status == 404 or .status == 400)' >/dev/null 2>&1; then
                ERR_DETACH=$(echo "$DETACH_RESPONSE" | jq -r '.message // .data.error[0].message // .error // empty' 2>/dev/null)
                [ -z "$ERR_DETACH" ] && ERR_DETACH=$(echo "$DETACH_RESPONSE" | jq -c . 2>/dev/null | head -c 400)
                echo "    ⚠ Detach VM $vm_uuid failed: ${ERR_DETACH:-error response}"
            elif echo "$DETACH_RESPONSE" | jq -e '.data.extId or .data' >/dev/null 2>&1; then
                echo "    ✓ Detached VM: $vm_uuid"
                DETACH_SUCCESS=true
            elif ! echo "$DETACH_RESPONSE" | jq -e '.message_list or .error' >/dev/null 2>&1 && [ -n "$DETACH_RESPONSE" ]; then
                echo "    ✓ Detached VM: $vm_uuid (accepted)"
                DETACH_SUCCESS=true
            elif [ -z "$DETACH_RESPONSE" ]; then
                echo "    ✓ Detached VM: $vm_uuid (accepted)"
                DETACH_SUCCESS=true
            else
                ERR_DETACH=$(echo "$DETACH_RESPONSE" | jq -r '.message // .data.error[0].message // empty' 2>/dev/null)
                [ -z "$ERR_DETACH" ] && ERR_DETACH=$(echo "$DETACH_RESPONSE" | jq -c . 2>/dev/null | head -c 400)
                echo "    ⚠ Detach VM $vm_uuid failed: ${ERR_DETACH:-unexpected response}"
            fi
        done <<< "$ATTACHED_VM_UUIDS"
        
        if [ "$DETACH_SUCCESS" = true ]; then
            [ "$DETACH_ONLY" = true ] && DETACHED_COUNT=$((DETACHED_COUNT + 1))
            if [ "$DETACH_ONLY" != true ]; then
                echo "  Waiting ${DETACH_WAIT_SECONDS} seconds for detach to complete..."
                sleep "$DETACH_WAIT_SECONDS"
            fi
        fi
    else
        echo "  No attachments found in LIST response (already detached), skipping detach step"
        [ "$DETACH_ONLY" = true ] && DETACHED_COUNT=$((DETACHED_COUNT + 1))
    fi

    if [ "$DETACH_ONLY" = true ]; then
        echo "  (Skipping delete in --detach-only mode)"
        if [ -n "$ATTACHED_VM_UUIDS" ] && [ "$DETACH_SUCCESS" != true ]; then
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
        if [ "$DELAY_BETWEEN_VGS" -gt 0 ]; then
            sleep "$DELAY_BETWEEN_VGS"
        fi
        echo ""
        continue
    fi
    
    # Step 4c: Delete the volume group (with retries for transient failures)
    echo "  Deleting volume group..."

    RETRY_NUM=0
    for RETRY_DELAY in $DELETE_RETRY_DELAYS; do
        [ "$RETRY_NUM" -gt 0 ] && echo "  Retry $RETRY_NUM/$DELETE_RETRIES in ${RETRY_DELAY}s (transient errors may succeed on retry)..."
        [ "$RETRY_NUM" -gt 0 ] && sleep "$RETRY_DELAY"

        DELETE_RESPONSE=$(api_call "DELETE" "/api/volumes/v4.1/config/volume-groups/${vg_uuid}" 2>/dev/null)

        if echo "$DELETE_RESPONSE" | jq -e '.data.extId' >/dev/null 2>&1; then
            DELETE_TASK_ID=$(echo "$DELETE_RESPONSE" | jq -r '.data.extId')
            echo "  ✓ Delete request accepted (task ID: $DELETE_TASK_ID)"
            DELETED_COUNT=$((DELETED_COUNT + 1))
            break
        fi

        ERROR_MSG=$(echo "$DELETE_RESPONSE" | jq -r '.data.error[0].message // .message // empty' 2>/dev/null)

        if [ -n "$ERROR_MSG" ]; then
            if echo "$ERROR_MSG" | grep -qi "RPC request\|timeout\|connection\|temporarily\|unavailable"; then
                RETRY_NUM=$((RETRY_NUM + 1))
                if [ "$RETRY_NUM" -lt "$DELETE_RETRIES" ]; then
                    echo "  ⚠ Retryable error: $ERROR_MSG"
                    continue
                fi
            fi
            echo "  ✗ Failed to delete: $ERROR_MSG"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            break
        fi

        echo "  ✗ Failed to delete (unexpected response)"
        echo "$DELETE_RESPONSE" | jq . 2>/dev/null | head -8
        FAILED_COUNT=$((FAILED_COUNT + 1))
        break
    done

    # Throttle: delay between volume groups to avoid overwhelming Prism Central
    if [ "$DELAY_BETWEEN_VGS" -gt 0 ]; then
        sleep "$DELAY_BETWEEN_VGS"
    fi
    echo ""
done < <(echo "$VGS_TO_DELETE" | jq -c -s '.[]')

echo "=========================================="
if [ "$DETACH_ONLY" = true ]; then
    echo "Detach-only Summary:"
    echo "  Detached (or had no attachments): $DETACHED_COUNT"
    echo "  Failed: $FAILED_COUNT"
    echo "=========================================="
    echo ""
    echo "Next steps:"
    echo "  1. Confirm volume groups show no VM attachments."
    echo "  2. Delete the volume groups using the written list:"
    echo "       $0 --volumes volumes.list.tmp"
    echo "  3. Then delete the VMs (if same cluster):"
    echo "       $0 --cluster $CLUSTER_NAME --vms"
else
    echo "Deletion Summary:"
    echo "  Successfully deleted: $DELETED_COUNT"
    echo "  Failed: $FAILED_COUNT"
    echo "=========================================="
    echo ""
    if [ "$CLUSTER_NAME" != "from file" ]; then
        echo "To delete the VMs (after VGs are gone), run: $0 --cluster $CLUSTER_NAME --vms"
    fi
fi
