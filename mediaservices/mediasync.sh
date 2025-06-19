#!/bin/bash
set -euo pipefail

# === EXPECTED ENVIRONMENT VARIABLES ===
# RSYNC_REMOTE_HOST : SSH hostname, e.g., root@host.ts.net
# RSYNC_REMOTE_DIR  : Remote path containing .syncdone markers

# === SSH Prep ===
SSH_KEY=~/.ssh/id_ed25519
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp /id_ed25519 "$SSH_KEY"
chmod 600 "$SSH_KEY"
echo -e "Host *\n\tStrictHostKeyChecking no" > ~/.ssh/config
chmod 600 ~/.ssh/config

# === Sync Process ===
echo "📥 Fetching .syncdone files from $RSYNC_REMOTE_HOST:$RSYNC_REMOTE_DIR..."
ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" \
  "find \"$RSYNC_REMOTE_DIR\" -maxdepth 1 -name '*.syncdone' -printf '%f\n'" > /tmp/sync_list.txt || touch /tmp/sync_list.txt

echo "📋 Found $(wc -l < /tmp/sync_list.txt) items to sync"
cat /tmp/sync_list.txt

while IFS= read -r syncdone; do
  [ -z "$syncdone" ] && continue
  name="${syncdone%.syncdone}"
  echo -e "\n🔍 Processing: $name"

  REMOTE_PATH="$RSYNC_REMOTE_DIR/$name"
  REMOTE_SOURCE="$RSYNC_REMOTE_HOST:$REMOTE_PATH"
  LOCAL_DEST="/local/"

  if ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "[ -f \"$REMOTE_PATH\" ]"; then
    echo "📄 File detected — syncing $name"
    rsync -avz --compress-choice=zstd --info=progress2 --human-readable --no-perms --no-owner --no-group \
      -e "ssh $SSH_OPTS" \
      "$REMOTE_SOURCE" "$LOCAL_DEST"

    REMOTE_HASH=$(ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "sha256sum \"$REMOTE_PATH\" | cut -d ' ' -f1")
    LOCAL_HASH=$(sha256sum "$LOCAL_DEST/$name" | cut -d ' ' -f1)

    if [ "$REMOTE_HASH" = "$LOCAL_HASH" ]; then
      echo "✅ Hash match confirmed for $name"
      ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "rm -f \"$RSYNC_REMOTE_DIR/${name}.syncdone\""
    else
      echo "❌ Hash mismatch for $name — skipping delete"
    fi

  elif ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "[ -d \"$REMOTE_PATH\" ]"; then
    echo "📁 Directory detected — syncing contents of $name"
    rsync -avz --compress-choice=zstd --info=progress2 --human-readable --no-perms --no-owner --no-group \
      -e "ssh $SSH_OPTS" \
      "$REMOTE_SOURCE/" "$LOCAL_DEST"

    echo "✅ Directory synced: $name"
    ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "rm -f \"$RSYNC_REMOTE_DIR/${name}.syncdone\""

  else
    echo "⚠️ $name not found as file or directory on remote — skipping"
  fi
done < /tmp/sync_list.txt

echo -e "\n🎉 Sync script complete"
