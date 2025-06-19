#!/bin/bash
set -euo pipefail

SSH_OPTS="-i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no"
REMOTE_HOST="root@seedbox.reindeer-salmon.ts.net"
REMOTE_DIR="/root/seedbox/media/completed"

mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp /id_ed25519 ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519
echo -e "Host *\n\tStrictHostKeyChecking no" > ~/.ssh/config

# Get list of .syncdone files
ssh $SSH_OPTS "$REMOTE_HOST" "find $REMOTE_DIR -maxdepth 1 -name '*.syncdone' -printf '%f\n'" > /tmp/sync_list.txt

while IFS= read -r syncdone; do
  [ -z "$syncdone" ] && continue
  name="${syncdone%.syncdone}"
  echo "🔍 Checking $name"

  REMOTE_SOURCE="${REMOTE_HOST}:${REMOTE_DIR}/$name"
  LOCAL_DEST="/local/"

  if ssh $SSH_OPTS "$REMOTE_HOST" "[ -f \"$REMOTE_DIR/$name\" ]"; then
    echo "📄 Syncing file $name"
    rsync -avz --compress-choice=zstd --info=progress2 --human-readable --no-perms --no-owner --no-group \
      -e "ssh $SSH_OPTS" \
      "$REMOTE_SOURCE" "$LOCAL_DEST"

    REMOTE_HASH=$(ssh $SSH_OPTS "$REMOTE_HOST" "sha256sum \"$REMOTE_DIR/$name\" | cut -d ' ' -f1")
    LOCAL_HASH=$(sha256sum "/local/$name" | cut -d ' ' -f1)

    if [ "$REMOTE_HASH" = "$LOCAL_HASH" ]; then
      echo "✅ Hash match: $name"
      ssh $SSH_OPTS "$REMOTE_HOST" "rm -f \"$REMOTE_DIR/${name}.syncdone\""
    else
      echo "❌ Hash mismatch: $name"
    fi

  elif ssh $SSH_OPTS "$REMOTE_HOST" "[ -d \"$REMOTE_DIR/$name\" ]"; then
    echo "📁 Syncing folder $name"
    rsync -avz --compress-choice=zstd --info=progress2 --human-readable --no-perms --no-owner --no-group \
      -e "ssh $SSH_OPTS" \
      "$REMOTE_SOURCE/" "$LOCAL_DEST"
    echo "✅ Folder synced: $name"
    ssh $SSH_OPTS "$REMOTE_HOST" "rm -f \"$REMOTE_DIR/${name}.syncdone\""
  else
    echo "⚠️ Skipping $name — not found."
  fi
done < /tmp/sync_list.txt
