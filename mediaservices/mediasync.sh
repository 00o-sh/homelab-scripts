#!/bin/bash
set -euo pipefail

# === This script expects the following env vars to be set: ===
# RSYNC_REMOTE_HOST    → remote SSH host (e.g., root@host.ts.net)
# RSYNC_REMOTE_DIR     → remote directory to sync from

SSH_OPTS="-i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no"

mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp /id_ed25519 ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519
echo -e "Host *\n\tStrictHostKeyChecking no" > ~/.ssh/config

echo "📥 Getting list of .syncdone files..."
ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "find $RSYNC_REMOTE_DIR -maxdepth 1 -name '*.syncdone' -printf '%f\n'" > /tmp/sync_list.txt

while IFS= read -r syncdone; do
  [ -z "$syncdone" ] && continue
  name="${syncdone%.syncdone}"
  echo "🔍 Checking $name"

  REMOTE_SOURCE="${RSYNC_REMOTE_HOST}:${RSYNC_REMOTE_DIR}/$name"
  LOCAL_DEST="/local/"

  if ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "[ -f \"$RSYNC_REMOTE_DIR/$name\" ]"; then
    echo "📄 Syncing file $name"
    rsync -avz --compress-choice=zstd --info=progress2 --human-readable --no-perms --no-owner --no-group \
      -e "ssh $SSH_OPTS" "$REMOTE_SOURCE" "$LOCAL_DEST"

    REMOTE_HASH=$(ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "sha256sum \"$RSYNC_REMOTE_DIR/$name\" | cut -d ' ' -f1")
    LOCAL_HASH=$(sha256sum "/local/$name" | cut -d ' ' -f1)

    if [ "$REMOTE_HASH" = "$LOCAL_HASH" ]; then
      echo "✅ Hash match: $name"
      ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "rm -f \"$RSYNC_REMOTE_DIR/${name}.syncdone\""
    else
      echo "❌ Hash mismatch: $name"
    fi

  elif ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "[ -d \"$RSYNC_REMOTE_DIR/$name\" ]"; then
    echo "📁 Syncing folder $name"
    rsync -avz --compress-choice=zstd --info=progress2 --human-readable --no-perms --no-owner --no-group \
      -e "ssh $SSH_OPTS" "$REMOTE_SOURCE/" "$LOCAL_DEST"
    echo "✅ Folder synced: $name"
    ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "rm -f \"$RSYNC_REMOTE_DIR/${name}.syncdone\""
  else
    echo "⚠️ Skipping $name — not found."
  fi
done < /tmp/sync_list.txt
