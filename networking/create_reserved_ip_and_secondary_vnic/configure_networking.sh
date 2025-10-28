#!/usr/bin/env bash
MAX_RETRIES=120
SUCCESS=0

# Disable exit-on-error within the retry loop scope
set +e
for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
  echo "→ [Attempt $attempt/$MAX_RETRIES] Running oci-network-config -c..."

  OUTPUT="$(oci-network-config -c 2>&1)"
  RC=$?
  echo "↪️  oci-network-config exit code: $RC"
  echo "$OUTPUT"

  # Extract OS-level config table
  TABLE="$(awk '
    /Operating System level network configuration:/ {inblk=1; next}
    inblk && NF==0 {inblk=0}
    inblk
  ' <<<"$OUTPUT")"

  # Detect iface rows
  ROWS="$(awk 'NF && $8 ~ /^(ens|enp|eno|eth)/' <<<"$TABLE")"
  TOTAL_ROWS=$(printf "%s\n" "$ROWS" | sed '/^$/d' | wc -l)

  # Skip immediately if table not yet populated
  if (( TOTAL_ROWS == 0 )); then
    echo "⚙️  No OS-level interfaces yet. Retrying in 3s..."
    sleep 3
    continue
  fi

  NO_IP_COUNT="$(awk '$2=="-" {c++} END{print c+0}' <<<"$ROWS")"
  EXPECTED_MAP="$(awk '$2 != "-" {print $8, $2}' <<<"$ROWS")"

  MISSING_ON_OS=0
  while read -r IFACE IP; do
    [[ -z "$IFACE" || -z "$IP" ]] && continue
    OS_IPS="$(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)"
    if echo "$OS_IPS" | grep -qx "$IP"; then
      echo "  ✅ $IFACE has $IP"
    else
      echo "  ❌ $IFACE missing $IP (has: ${OS_IPS:-none})"
      ((MISSING_ON_OS++))
    fi
  done <<< "$EXPECTED_MAP"

  echo "→ Summary: total_rows=$TOTAL_ROWS, no_ip_rows=$NO_IP_COUNT, missing_on_os=$MISSING_ON_OS"

  if (( TOTAL_ROWS>0 && NO_IP_COUNT==0 && MISSING_ON_OS==0 )); then
    echo "✅ All network interfaces have their expected IPs at OS level."
    SUCCESS=1
    break
  fi

  echo "⚙️  Not ready yet (attempt $attempt). Waiting 1s..."
  sleep 1
done
set -e

if (( SUCCESS==0 )); then
  echo "❌ Network configuration incomplete after $MAX_RETRIES attempts."
  echo "Last OCI table snapshot:"
  echo "$TABLE"
  exit 1
fi

echo
echo "✅ Network Interfaces Configured and Verified!"
