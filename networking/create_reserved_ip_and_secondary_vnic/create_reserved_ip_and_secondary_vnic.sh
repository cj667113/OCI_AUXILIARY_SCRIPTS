#!/usr/bin/env bash
# Usage: ./create_reserved_ip_and_secondary_vnic.sh <subnet_ocid>

set -euo pipefail

SUBNET_ID="${1:-}"
if [[ -z "$SUBNET_ID" ]]; then
  echo "Usage: $0 <subnet_ocid>"
  exit 1
fi

PUBLIC_IP_POOL_ID="${2:-}"

# --- Fetch instance metadata ---
METADATA_URL="http://169.254.169.254/opc/v2/instance/"
echo "Fetching instance metadata..."
METADATA="$(curl -s -H "Authorization: Bearer Oracle" "$METADATA_URL")"

COMPARTMENT_ID="$(echo "$METADATA" | jq -r '.compartmentId')"
INSTANCE_ID="$(echo "$METADATA" | jq -r '.id')"
REGION="$(echo "$METADATA" | jq -r '.canonicalRegionName // .regionInfo.regionIdentifier // .region')"

if [[ -z "$COMPARTMENT_ID" || -z "$REGION" || "$COMPARTMENT_ID" == "null" ]]; then
  echo "❌ Failed to obtain metadata (compartment or region missing)"
  exit 1
fi

# Short, unique names (avoid truncation/compare issues)
INSTANCE_SUFFIX="$(echo "$INSTANCE_ID" | tail -c 9)"   # last 8 chars
VNIC_NAME="vnic-${INSTANCE_SUFFIX}"
PUBLIC_IP_NAME="ip-${INSTANCE_SUFFIX}"

echo "------------------------------------------"
echo "Compartment ID: $COMPARTMENT_ID"
echo "Region:         $REGION"
echo "Instance ID:    $INSTANCE_ID"
echo "VNIC Name:      $VNIC_NAME"
echo "Public IP Name: $PUBLIC_IP_NAME"
echo "Subnet ID:      $SUBNET_ID"
echo "------------------------------------------"
echo

# Create Reserved Public IP ---
echo "Creating Reserved Public IP..."
if [[ -n "$PUBLIC_IP_POOL_ID" ]]; then
  echo "→ Using Public IP Pool: $PUBLIC_IP_POOL_ID"
  PUBLIC_IP_JSON="$(oci network public-ip create \
    --compartment-id "$COMPARTMENT_ID" \
    --lifetime RESERVED \
    --display-name "$PUBLIC_IP_NAME" \
    --region "$REGION" \
    --auth instance_principal \
    --max-wait-seconds 60 \
    --public-ip-pool-id "$PUBLIC_IP_POOL_ID" \
    --output json)"
else
  PUBLIC_IP_JSON="$(oci network public-ip create \
    --compartment-id "$COMPARTMENT_ID" \
    --lifetime RESERVED \
    --display-name "$PUBLIC_IP_NAME" \
    --region "$REGION" \
    --auth instance_principal \
    --max-wait-seconds 60 \
    --output json)"
fi

PUBLIC_IP_OCID="$(echo "$PUBLIC_IP_JSON" | jq -r '.data.id')"
PUBLIC_IP="$(echo "$PUBLIC_IP_JSON" | jq -r '.data."ip-address"')"
echo "✅ Reserved IP created: $PUBLIC_IP ($PUBLIC_IP_OCID)"
echo

# Attach Secondary VNIC (NO ephemeral public IP) ---
echo "Attaching Secondary VNIC (no ephemeral public IP)..."
set +e
ATTACH_STDERR="$(oci compute instance attach-vnic \
  --instance-id "$INSTANCE_ID" \
  --subnet-id "$SUBNET_ID" \
  --vnic-display-name "$VNIC_NAME" \
  --assign-public-ip false \
  --region "$REGION" \
  --auth instance_principal 2>&1 >/dev/null)"
ATTACH_RC=$?
set -e

if [[ $ATTACH_RC -ne 0 ]]; then
  echo "❌ ERROR from attach-vnic:"
  echo "$ATTACH_STDERR"
  exit $ATTACH_RC
fi

# Wait up to 90s for the VNIC to appear on the instance ---
echo "Waiting for new VNIC to appear on the instance (up to 90s)..."
VNIC_ID=""
for i in {1..90}; do
  VNIC_ID="$(oci compute instance list-vnics \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --auth instance_principal \
    --output json \
    | jq -r --arg name "$VNIC_NAME" --arg subnet "$SUBNET_ID" \
      '.data[]? | select(."display-name"==$name and ."subnet-id"==$subnet) | .id' \
    | head -n1)"
  if [[ -n "$VNIC_ID" && "$VNIC_ID" != "null" ]]; then
    echo "✅ Found VNIC: $VNIC_ID"
    break
  fi
  echo "  → Not visible yet, waiting 1s..."
  sleep 1
done

if [[ -z "$VNIC_ID" || "$VNIC_ID" == "null" ]]; then
  echo "❌ Could not find the new VNIC after 90 seconds."
  echo "   Tip: check 'Attached VNICs' in the Console to confirm it exists and its display name."
  exit 1
fi
echo

# Confirm the attachment is ATTACHED ---
echo "Verifying VNIC attachment state..."
ATTACHMENT_ID="$(oci compute vnic-attachment list \
  --compartment-id "$COMPARTMENT_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$REGION" \
  --auth instance_principal \
  --output json \
  | jq -r --arg vnic "$VNIC_ID" '.data[]? | select(."vnic-id"==$vnic) | .id' | head -n1)"

if [[ -n "$ATTACHMENT_ID" && "$ATTACHMENT_ID" != "null" ]]; then
  for i in {1..90}; do
    STATE="$(oci compute vnic-attachment get \
      --vnic-attachment-id "$ATTACHMENT_ID" \
      --region "$REGION" \
      --auth instance_principal \
      --output json | jq -r '.data."lifecycle-state"')"
    echo "  → Attachment state: $STATE"
    [[ "$STATE" == "ATTACHED" ]] && break
    sleep 1
  done
else
  echo "  (Skipping attachment-state check; attachment id not found yet)"
fi
echo

# Get the VNIC's primary private IP OCID ---
echo "Locating primary private IP on the new VNIC..."
PRIVATE_IP_ID="$(oci network private-ip list \
  --vnic-id "$VNIC_ID" \
  --region "$REGION" \
  --auth instance_principal \
  --output json \
  | jq -r '(.data[]? | select(."is-primary"==true or ."isPrimary"==true) | .id) // (.data[0]?.id // empty)')"

if [[ -z "$PRIVATE_IP_ID" || "$PRIVATE_IP_ID" == "null" ]]; then
  echo "❌ Failed to locate the VNIC's primary private IP."
  exit 1
fi
echo "✅ Private IP ID: $PRIVATE_IP_ID"
echo

# Associate the RESERVED public IP to that PRIVATE IP ---
echo "Associating reserved public IP to the VNIC's private IP..."
oci network public-ip update \
  --public-ip-id "$PUBLIC_IP_OCID" \
  --private-ip-id "$PRIVATE_IP_ID" \
  --region "$REGION" \
  --auth instance_principal \
  --output json >/dev/null

# Verify association ---
ASSIGNED_TO="$(oci network public-ip get \
  --public-ip-id "$PUBLIC_IP_OCID" \
  --region "$REGION" \
  --auth instance_principal \
  --output json | jq -r '.data."assigned-entity-id" // .data."assignedEntityId" // empty')"

if [[ -z "$ASSIGNED_TO" || "$ASSIGNED_TO" != "$PRIVATE_IP_ID" ]]; then
  echo "⚠️  Association verification inconclusive. Public IP may take a moment to reflect assignment."
else
  echo "✅ Public IP is now assigned to private IP: $ASSIGNED_TO"
fi

echo
echo "✅ Reserved Public IP successfully assigned to the secondary VNIC!"
echo "------------------------------------------"
echo "VNIC Name:        $VNIC_NAME"
echo "VNIC ID:          $VNIC_ID"
echo "Private IP ID:    $PRIVATE_IP_ID"
echo "Public IP:        $PUBLIC_IP"
echo "Public IP OCID:   $PUBLIC_IP_OCID"
echo "Region:           $REGION"
echo "------------------------------------------"

echo
echo "Configuring Network Interfaces"
