#!/bin/bash

GRPC_ADDRESS="http://localhost:5555"
TXS_DIR="$(pwd)/txs"

echo "========================================"
echo "       Robinhood's Multi Send"
echo "========================================"
echo

# -----------------------
# Prompt sender pubkey
# -----------------------
read -rp $'📤 Sender pubkey:\n> ' sender
[[ -z "$sender" ]] && { echo "❌ Sender pubkey cannot be empty."; exit 1; }

# -----------------------
# Collect recipients & gifts
# -----------------------
recipients=()
gifts=()
while true; do
  read -rp $'\n📥 Recipient pubkey (leave blank to finish):\n> ' recipient
  [[ -z "$recipient" ]] && break

  while true; do
    read -rp $'🎁 Gift amount:\n> ' gift
    [[ "$gift" =~ ^[1-9][0-9]*$ ]] && break
    echo "❌ Gift must be a positive integer greater than 0."
  done

  recipients+=("$recipient")
  gifts+=("$gift")
done
[[ ${#recipients[@]} -eq 0 ]] && { echo "❌ Must specify at least one recipient."; exit 1; }

# -----------------------
# Prompt fee
# -----------------------
while true; do
  read -rp $'💸 Fee amount (in assets):\n> ' fee
  [[ "$fee" =~ ^[1-9][0-9]*$ ]] && break
  echo "❌ Fee must be a positive integer greater than 0."
done

# -----------------------
# Export notes CSV
# -----------------------
csvfile="notes-${sender}.csv"
echo "📂 Exporting notes CSV..."
if ! nockchain-wallet --grpc-address "$GRPC_ADDRESS" list-notes-by-pubkey-csv "$sender" >/dev/null 2>&1; then
  echo "❌ Failed to export notes CSV. Check wallet and connection."; exit 1
fi

echo -n "⏳ Waiting for notes file ($csvfile)... "
timeout=15
while [ ! -f "$csvfile" ]; do
  sleep 1
  ((timeout--))
  [[ $timeout -le 0 ]] && { echo "❌ Timeout waiting for notes file."; exit 1; }
done
echo "Found!"

# -----------------------
# Parse CSV assets
# -----------------------
notes=()
declare -A note_assets
while IFS=',' read -r name_first name_last assets _ _; do
  [[ "$name_first" == "name_first" ]] && continue
  name_first=$(echo "$name_first" | xargs)
  name_last=$(echo "$name_last" | xargs)
  assets=$((assets))
  [[ -z "$name_first" || -z "$assets" ]] && continue
  note_full="$name_first $name_last"
  notes+=("$note_full")
  note_assets["$note_full"]=$assets
done < "$csvfile"

# -----------------------
# Pick the largest note
# -----------------------
largest_note=""
largest_assets=0
for n in "${notes[@]}"; do
  if (( note_assets[$n] > largest_assets )); then
    largest_assets=${note_assets[$n]}
    largest_note=$n
  fi
done

# -----------------------
# Check if the largest note covers all gifts + fee
# -----------------------
gift_total=0
for g in "${gifts[@]}"; do gift_total=$((gift_total + g)); done
total=$((gift_total + fee))

if (( largest_assets < total )); then
  echo "❌ Largest note does not cover all gifts + fee. Aborting."
  exit 1
fi

# -----------------------
# Build --names, --recipients, --gifts
# -----------------------
names_array=()
recipients_array=()
gifts_arg=""

for i in "${!recipients[@]}"; do
  names_array+=("[$largest_note]")
  recipients_array+=("[1 ${recipients[i]}]")
  gifts_arg+="${gifts[i]}"
  (( i < ${#recipients[@]}-1 )) && gifts_arg+=","
done

names_arg=$(IFS=, ; echo "${names_array[*]}")
recipients_arg=$(IFS=, ; echo "${recipients_array[*]}")

# -----------------------
# Prepare transaction directory
# -----------------------
mkdir -p "$TXS_DIR"
rm -f "$TXS_DIR"/*.tx 2>/dev/null

# -----------------------
# Debug output
# -----------------------
echo -e "\n📝 Debug: transaction arguments"
echo "names_arg=$names_arg"
echo "recipients_arg=$recipients_arg"
echo "gifts_arg=$gifts_arg"
echo "fee=$fee"

# -----------------------
# Create transaction
# -----------------------
echo -e "\n🛠️ Creating draft transaction..."
if ! nockchain-wallet --grpc-address "$GRPC_ADDRESS" create-tx \
  --names "$names_arg" \
  --recipients "$recipients_arg" \
  --gifts "$gifts_arg" \
  --fee "$fee"; then
    echo "❌ Failed to create draft transaction."
    exit 1
fi

# -----------------------
# Pick .tx file
# -----------------------
txfile=$(find "$TXS_DIR" -maxdepth 1 -type f -name '*.tx' | head -n 1)
[[ -z "$txfile" ]] && { echo "❌ No transaction file found."; exit 1; }
echo "✅ Draft transaction created: $txfile"

# -----------------------
# Confirm and send
# -----------------------
read -rp $'\n🚀 Send transaction now? (y/n): ' confirm
[[ "$confirm" != "y" ]] && { echo "❌ Transaction canceled."; exit 0; }

if nockchain-wallet --grpc-address "$GRPC_ADDRESS" send-tx "$txfile"; then
  echo "✅ Transaction sent successfully!"
else
  echo "❌ Failed to send transaction."
fi

