#!/usr/bin/env bash
set -euo pipefail

# Strip Windows \r from az CLI output (needed when WSL calls the Windows az binary)
az() { command az "$@" | tr -d '\r'; }

# =============================================================================
# deploy-mext-e2e.sh
#
# End-to-end script to provision an Azure Resource Group, Fabric Capacity,
# Workspace, and Lakehouse, then download the MEXT education CSV, upload it
# to OneLake, deploy a notebook, and load data into a Delta table.
#
# Prerequisites:
#   - Azure CLI installed (az --version)
#   - Logged in (az login)
#   - Python 3 available
#   - curl available
#
# Usage:
#   1. Edit config/variables.md
#   2. chmod +x deploy-mext-e2e.sh
#   3. ./deploy-mext-e2e.sh
# =============================================================================

# ─── CONFIGURATION ───────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VARS_FILE="$SCRIPT_DIR/config/variables.md"

if [[ -f "$VARS_FILE" ]]; then
  _vars=$(python3 - "$VARS_FILE" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
blocks = re.findall(r'```bash\n(.*?)```', content, re.DOTALL)
for block in blocks:
    for line in block.splitlines():
        line = line.strip()
        if re.match(r'^[A-Z_]+=', line) and not line.startswith('#'):
            print(line)
PYEOF
)
  eval "$_vars" 2>/dev/null || true
fi

# ── Override / set defaults ──
RESOURCE_GROUP="${RESOURCE_GROUP:-FabricCapacityWestUS3}"
LOCATION="${LOCATION:-westus3}"
SKU="${SKU:-F4}"
CAPACITY_NAME="${CAPACITY_NAME:-westus3f4skillsflearning}"
WORKSPACE_NAME="${WORKSPACE_NAME:-MextSkillsF4Learning}"
LAKEHOUSE_NAME="${LAKEHOUSE_NAME:-MextLearningLH}"

# Data source
CSV_URL="${CSV_URL:-https://www.mext.go.jp/content/20201221-mxt_syogai03-000010378_2.csv}"
CSV_FILENAME="${CSV_FILENAME:-mext_education_content.csv}"
ONELAKE_DATA_PATH="${ONELAKE_DATA_PATH:-Files/mext}"

# Delta table
DELTA_SCHEMA="${DELTA_SCHEMA:-mext}"
DELTA_TABLE="${DELTA_TABLE:-education_content}"

# Local paths
DATA_DIR="$SCRIPT_DIR/data"
NOTEBOOK_DIR="$SCRIPT_DIR/notebooks"
NOTEBOOK_NAME="${NOTEBOOK_NAME:-LoadMextEducationData}"

# ─── HELPER FUNCTIONS ────────────────────────────────────────────────────────

log()  { echo ""; echo "=== $1 ==="; }
info() { echo "  → $1"; }
fail() { echo "  ✗ FAILED: $1"; exit 1; }
ok()   { echo "  ✓ $1"; }

TMPDIR="$SCRIPT_DIR/.tmp"
mkdir -p "$TMPDIR"

poll_job() {
  local ws_id=$1 item_id=$2 job_id=$3 label=$4 max_polls=${5:-60} interval=${6:-15}
  info "Polling $label (job $job_id)..."
  for i in $(seq 1 "$max_polls"); do
    STATUS=$(az rest --resource "https://api.fabric.microsoft.com" \
      --url "https://api.fabric.microsoft.com/v1/workspaces/$ws_id/items/$item_id/jobs/instances/$job_id" \
      --query "status" --output tsv 2>&1)
    echo "    [$i] $STATUS"
    case "$STATUS" in
      Completed) ok "$label completed"; return 0 ;;
      Failed|Cancelled) fail "$label ended with status: $STATUS" ;;
    esac
    sleep "$interval"
  done
  fail "$label timed out after $((max_polls * interval)) seconds"
}

submit_notebook_job() {
  local ws_id=$1 nb_id=$2
  az rest --method post \
    --resource "https://api.fabric.microsoft.com" \
    --url "https://api.fabric.microsoft.com/v1/workspaces/$ws_id/items/$nb_id/jobs/instances?jobType=RunNotebook" \
    --body '{}' \
    --verbose 2>&1 | grep "'Location'" | grep -oE '[0-9a-f-]{36}' | tail -1
}

# ─── STEP 0: PREFLIGHT ──────────────────────────────────────────────────────

log "Step 0 — Preflight checks"

az account show > /dev/null 2>&1 || fail "Not logged in. Run 'az login' first."
SUBSCRIPTION_ID=$(az account show --query id --output tsv)
ADMIN_EMAIL=$(az account show --query user.name --output tsv)
ok "Logged in as $ADMIN_EMAIL (subscription: $SUBSCRIPTION_ID)"

[[ -d "$NOTEBOOK_DIR" ]] || fail "Notebook directory not found: $NOTEBOOK_DIR"
[[ -f "$NOTEBOOK_DIR/$NOTEBOOK_NAME.ipynb" ]] || fail "$NOTEBOOK_NAME.ipynb not found"
ok "Notebook found: $NOTEBOOK_NAME.ipynb"

# ─── STEP 1: DOWNLOAD CSV ───────────────────────────────────────────────────

log "Step 1 — Download MEXT education CSV"

mkdir -p "$DATA_DIR"
CSV_PATH="$DATA_DIR/$CSV_FILENAME"

if [[ -f "$CSV_PATH" ]]; then
  ok "CSV already exists: $CSV_PATH ($(wc -c < "$CSV_PATH" | tr -d ' ') bytes)"
else
  info "Downloading from $CSV_URL ..."
  curl -sL "$CSV_URL" -o "$CSV_PATH" || fail "Could not download CSV"
  ok "Downloaded CSV ($(wc -c < "$CSV_PATH" | tr -d ' ') bytes, Shift-JIS encoded)"
  info "Note: The notebook handles Shift-JIS decoding and data cleaning at runtime"
fi

# ─── STEP 2: CREATE RESOURCE GROUP ──────────────────────────────────────────

log "Step 2 — Create Resource Group ($RESOURCE_GROUP in $LOCATION)"

EXISTING_RG=$(az group show --name "$RESOURCE_GROUP" --query "name" --output tsv 2>/dev/null || echo "")
if [[ -n "$EXISTING_RG" ]]; then
  ok "Resource Group already exists, skipping creation"
else
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
  ok "Resource Group created"
fi

# ─── STEP 3: CREATE FABRIC CAPACITY ─────────────────────────────────────────

log "Step 3 — Create Fabric Capacity ($CAPACITY_NAME, $SKU in $LOCATION)"

EXISTING_STATE=$(az rest \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Fabric/capacities/$CAPACITY_NAME?api-version=2023-11-01" \
  --query "properties.state" --output tsv 2>/dev/null || echo "")

if [[ -n "$EXISTING_STATE" ]]; then
  ok "Capacity already exists (state: $EXISTING_STATE)"
  if [[ "$EXISTING_STATE" == "Paused" ]]; then
    info "Resuming paused capacity..."
    az rest --method post \
      --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Fabric/capacities/$CAPACITY_NAME/resume?api-version=2023-11-01" \
      > /dev/null 2>&1 || fail "Could not resume capacity"
  fi
else
  az rest --method put \
    --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Fabric/capacities/$CAPACITY_NAME?api-version=2023-11-01" \
    --body "{
      \"location\": \"$LOCATION\",
      \"sku\": {\"name\": \"$SKU\", \"tier\": \"Fabric\"},
      \"properties\": {
        \"administration\": {
          \"members\": [\"$ADMIN_EMAIL\"]
        }
      }
    }" > /dev/null 2>&1 || fail "Could not create capacity"
fi

info "Waiting for capacity to be ready..."
for i in {1..30}; do
  STATE=$(az rest \
    --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Fabric/capacities/$CAPACITY_NAME?api-version=2023-11-01" \
    --query "properties.state" --output tsv 2>&1)
  echo "    [$i] $STATE"
  [[ "$STATE" == "Active" ]] && break
  sleep 10
done
[[ "$STATE" == "Active" ]] || fail "Capacity not active: $STATE"

FABRIC_CAPACITY_ID=$(az rest \
  --resource "https://api.fabric.microsoft.com" \
  --url "https://api.fabric.microsoft.com/v1/capacities" \
  --query "value[?displayName=='$CAPACITY_NAME'].id | [0]" --output tsv)

ok "Capacity ID: $FABRIC_CAPACITY_ID"

# ─── STEP 4: CREATE WORKSPACE ───────────────────────────────────────────────

log "Step 4 — Create Workspace ($WORKSPACE_NAME)"

WS_ID=$(az rest --resource "https://api.fabric.microsoft.com" \
  --url "https://api.fabric.microsoft.com/v1/workspaces" \
  --query "value[?displayName=='$WORKSPACE_NAME'].id | [0]" --output tsv 2>/dev/null || echo "")

if [[ -n "$WS_ID" ]]; then
  ok "Workspace already exists: $WS_ID"
else
  WS_ID=$(az rest --method post \
    --resource "https://api.fabric.microsoft.com" \
    --url "https://api.fabric.microsoft.com/v1/workspaces" \
    --body "{\"displayName\": \"$WORKSPACE_NAME\", \"capacityId\": \"$FABRIC_CAPACITY_ID\"}" \
    --query "id" --output tsv)
  ok "Workspace created: $WS_ID"

  info "Verifying capacity assignment..."
  for i in {1..10}; do
    PROGRESS=$(az rest --resource "https://api.fabric.microsoft.com" \
      --url "https://api.fabric.microsoft.com/v1/workspaces/$WS_ID" \
      --query "capacityAssignmentProgress" --output tsv)
    [[ "$PROGRESS" == "Completed" ]] && break
    sleep 5
  done
  [[ "$PROGRESS" == "Completed" ]] || fail "Capacity assignment not completed: $PROGRESS"
  ok "Capacity assignment completed"
fi

# ─── STEP 5: CREATE LAKEHOUSE ───────────────────────────────────────────────

log "Step 5 — Create Lakehouse ($LAKEHOUSE_NAME)"

LH_ID=$(az rest --resource "https://api.fabric.microsoft.com" \
  --url "https://api.fabric.microsoft.com/v1/workspaces/$WS_ID/items" \
  --query "value[?displayName=='$LAKEHOUSE_NAME' && type=='Lakehouse'].id | [0]" --output tsv 2>/dev/null || echo "")

if [[ -n "$LH_ID" ]]; then
  ok "Lakehouse already exists: $LH_ID"
else
  LH_ID=$(az rest --method post \
    --resource "https://api.fabric.microsoft.com" \
    --url "https://api.fabric.microsoft.com/v1/workspaces/$WS_ID/items" \
    --body "{\"displayName\": \"$LAKEHOUSE_NAME\", \"type\": \"Lakehouse\", \"creationPayload\": {\"enableSchemas\": true}}" \
    --query "id" --output tsv)
  ok "Lakehouse created: $LH_ID"
fi

# ─── STEP 6: UPLOAD CSV TO ONELAKE ──────────────────────────────────────────

log "Step 6 — Upload CSV to OneLake (blob endpoint)"

STORAGE_TOKEN=$(az account get-access-token \
  --resource "https://storage.azure.com" \
  --query accessToken --output tsv)

HEAD_CODE=$(curl -s -o /dev/null -w "%{http_code}" -I \
  -H "Authorization: Bearer $STORAGE_TOKEN" \
  -H "x-ms-version: 2023-01-03" \
  "https://onelake.blob.fabric.microsoft.com/$WS_ID/$LH_ID/$ONELAKE_DATA_PATH/$CSV_FILENAME")

if [[ "$HEAD_CODE" == "200" ]]; then
  ok "CSV already uploaded, skipping"
else
  info "Uploading $CSV_FILENAME ..."
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    -H "Authorization: Bearer $STORAGE_TOKEN" \
    -H "x-ms-version: 2023-01-03" \
    -H "x-ms-blob-type: BlockBlob" \
    --data-binary @"$CSV_PATH" \
    "https://onelake.blob.fabric.microsoft.com/$WS_ID/$LH_ID/$ONELAKE_DATA_PATH/$CSV_FILENAME")

  [[ "$HTTP_CODE" == "201" ]] || fail "Upload failed with HTTP $HTTP_CODE"
  ok "CSV uploaded successfully"
fi

# ─── STEP 7: PREPARE AND DEPLOY NOTEBOOK ────────────────────────────────────

log "Step 7 — Prepare and deploy notebook with lakehouse binding"

python3 << PYEOF
import json, base64, uuid, os

ws_id = "$WS_ID"
lh_id = "$LH_ID"
lh_name = "$LAKEHOUSE_NAME"
nb_dir = "$NOTEBOOK_DIR"
tmpdir = "$TMPDIR"
nb_name = "$NOTEBOOK_NAME"

# Load notebook
with open(os.path.join(nb_dir, f'{nb_name}.ipynb'), 'r') as f:
    nb = json.load(f)

# Inject lakehouse binding
nb['metadata']['dependencies'] = {
    "lakehouse": {
        "default_lakehouse": lh_id,
        "default_lakehouse_name": lh_name,
        "default_lakehouse_workspace_id": ws_id,
        "known_lakehouses": [{"id": lh_id}]
    }
}

# Build deploy body
nb_b64 = base64.b64encode(json.dumps(nb).encode()).decode()
deploy_body = {
    "displayName": nb_name,
    "type": "Notebook",
    "definition": {
        "format": "ipynb",
        "parts": [
            {"path": "artifact.content.ipynb", "payload": nb_b64, "payloadType": "InlineBase64"}
        ]
    }
}
with open(f'{tmpdir}/{nb_name}_deploy_body.json', 'w') as f:
    json.dump(deploy_body, f)

# Build updateDefinition body (for lakehouse binding after create)
platform = {
    "metadata": {"type": "SparkNotebook", "displayName": nb_name},
    "config": {"version": "2.0", "logicalId": str(uuid.uuid4())}
}
platform_b64 = base64.b64encode(json.dumps(platform).encode()).decode()
update_body = {
    "definition": {
        "format": "ipynb",
        "parts": [
            {"path": "artifact.content.ipynb", "payload": nb_b64, "payloadType": "InlineBase64"},
            {"path": ".platform", "payload": platform_b64, "payloadType": "InlineBase64"}
        ]
    }
}
with open(f'{tmpdir}/{nb_name}_update_body.json', 'w') as f:
    json.dump(update_body, f)

print(f"  ✓ {nb_name} deploy and update bodies ready")
PYEOF

deploy_or_update_notebook() {
  local name=$1
  local nb_id
  nb_id=$(az rest --resource "https://api.fabric.microsoft.com" \
    --url "https://api.fabric.microsoft.com/v1/workspaces/$WS_ID/notebooks" \
    --query "value[?displayName=='$name'].id | [0]" --output tsv 2>/dev/null || echo "")

  if [[ -n "$nb_id" ]]; then
    info "$name already exists, updating definition..." >&2
    az rest --method post \
      --resource "https://api.fabric.microsoft.com" \
      --url "https://api.fabric.microsoft.com/v1/workspaces/$WS_ID/notebooks/$nb_id/updateDefinition" \
      --body "$(cat $TMPDIR/${name}_update_body.json)" > /dev/null 2>&1
    ok "$name updated: $nb_id" >&2
  else
    info "Deploying $name..." >&2
    az rest --method post \
      --resource "https://api.fabric.microsoft.com" \
      --url "https://api.fabric.microsoft.com/v1/workspaces/$WS_ID/items" \
      --body "$(cat $TMPDIR/${name}_deploy_body.json)" > /dev/null 2>&1

    for i in {1..10}; do
      nb_id=$(az rest --resource "https://api.fabric.microsoft.com" \
        --url "https://api.fabric.microsoft.com/v1/workspaces/$WS_ID/notebooks" \
        --query "value[?displayName=='$name'].id | [0]" --output tsv 2>/dev/null || echo "")
      [[ -n "$nb_id" ]] && break
      sleep 5
    done
    [[ -n "$nb_id" ]] || { echo "  ✗ FAILED: Could not retrieve ID for $name after deployment" >&2; exit 1; }
    ok "$name deployed: $nb_id" >&2

    info "Binding $name to lakehouse..." >&2
    az rest --method post \
      --resource "https://api.fabric.microsoft.com" \
      --url "https://api.fabric.microsoft.com/v1/workspaces/$WS_ID/notebooks/$nb_id/updateDefinition" \
      --body "$(cat $TMPDIR/${name}_update_body.json)" > /dev/null 2>&1
    ok "$name bound to lakehouse" >&2
  fi
  echo "$nb_id"
}

LOAD_NB_ID=$(deploy_or_update_notebook "$NOTEBOOK_NAME")

# ─── STEP 8: RUN NOTEBOOK ───────────────────────────────────────────────────

log "Step 8 — Run $NOTEBOOK_NAME notebook"

LOAD_JOB_ID=$(submit_notebook_job "$WS_ID" "$LOAD_NB_ID")
[[ -n "$LOAD_JOB_ID" ]] || fail "Could not submit notebook job"
poll_job "$WS_ID" "$LOAD_NB_ID" "$LOAD_JOB_ID" "$NOTEBOOK_NAME" 60 15

# ─── STEP 9: VERIFY ─────────────────────────────────────────────────────────

log "Step 9 — Verify Delta table"

STORAGE_TOKEN=$(az account get-access-token \
  --resource "https://storage.azure.com" \
  --query accessToken --output tsv)

TABLE_CHECK=$(curl -s -H "Authorization: Bearer $STORAGE_TOKEN" \
  -H "x-ms-version: 2023-01-03" \
  "https://onelake.blob.fabric.microsoft.com/$WS_ID/$LH_ID/Tables?restype=container&comp=list&prefix=$DELTA_SCHEMA&maxresults=5")

if echo "$TABLE_CHECK" | grep -q "$DELTA_TABLE"; then
  ok "Delta table $DELTA_SCHEMA.$DELTA_TABLE exists"
else
  fail "Delta table not found"
fi

# ─── SUMMARY ─────────────────────────────────────────────────────────────────

log "DEPLOYMENT COMPLETE"
echo ""
echo "  Capacity:  $CAPACITY_NAME  ($FABRIC_CAPACITY_ID)"
echo "  Workspace: $WORKSPACE_NAME ($WS_ID)"
echo "  Lakehouse: $LAKEHOUSE_NAME ($LH_ID)"
echo "  Notebook:  $NOTEBOOK_NAME ($LOAD_NB_ID)"
echo "  Table:     $DELTA_SCHEMA.$DELTA_TABLE"
echo ""
echo "  To query in Fabric SQL:"
echo "    SELECT 教材_教科等 AS subject, COUNT(*) AS count"
echo "    FROM [$LAKEHOUSE_NAME].[$DELTA_SCHEMA].[$DELTA_TABLE]"
echo "    GROUP BY 教材_教科等"
echo "    ORDER BY count DESC"
echo ""

# Clean up temp files
rm -f "$TMPDIR"/*_deploy_body.json "$TMPDIR"/*_update_body.json
