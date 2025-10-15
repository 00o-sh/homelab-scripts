#!/bin/bash
set -euo pipefail

# === Required ENV Variables ===
# RSYNC_REMOTE_HOST : e.g., root@seedbox.ts.net
# RSYNC_REMOTE_DIR  : e.g., /root/seedbox/media/completed

# === SSH Prep ===
SSH_KEY=~/.ssh/id_ed25519
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"

mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp /id_ed25519 "$SSH_KEY"
chmod 600 "$SSH_KEY"
echo -e "Host *\n\tStrictHostKeyChecking no" > ~/.ssh/config
chmod 600 ~/.ssh/config

# === Vars ===
SYNC_LIST=/tmp/sync_list.txt
LOCAL_DEST="/local"
PARTIAL_DIR="$LOCAL_DEST/.rsync-partials"
mkdir -p "$LOCAL_DEST" "$PARTIAL_DIR"

# === Helper ===
retry_rsync() {
  local src="$1"
  local dest="$2"
  local attempt=0
  local max_attempts=3

  while (( attempt < max_attempts )); do
    ((attempt++))
    echo "🔁 Attempt $attempt/$max_attempts..."
    if rsync -avz --append-verify --partial --partial-dir="$PARTIAL_DIR" \
      --progress --info=flist2,progress2,name0 --compress-choice=zstd \
      --no-perms --no-owner --no-group \
      -e "ssh $SSH_OPTS" "$src" "$dest"; then
      echo "✅ rsync completed successfully"
      return 0
    fi
    echo "⚠️ rsync failed (attempt $attempt). Retrying in 10s..."
    sleep 10
  done

  echo "❌ rsync failed after $max_attempts attempts"
  return 1
}

# === Get list of .syncdone files ===
echo "📥 Getting .syncdone files from $RSYNC_REMOTE_HOST..."
ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" \
  "find '$RSYNC_REMOTE_DIR' -maxdepth 1 -name '*.syncdone' -printf '%f\n'" > "$SYNC_LIST" || touch "$SYNC_LIST"

echo "📋 Found $(wc -l < "$SYNC_LIST") items"
cat "$SYNC_LIST"

# === Begin sync loop ===
while IFS= read -r syncdone; do
  [ -z "$syncdone" ] && continue
  name="${syncdone%.syncdone}"
  echo -e "\n🔍 Processing: $name"

  REMOTE_PATH="$RSYNC_REMOTE_DIR/$name"
  REMOTE_SOURCE="$RSYNC_REMOTE_HOST:$REMOTE_PATH"

  if ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "[ -f '$REMOTE_PATH' ]"; then
    echo "📄 File detected — syncing $name"
    retry_rsync "$REMOTE_SOURCE" "$LOCAL_DEST"

    REMOTE_HASH=$(ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "sha256sum '$REMOTE_PATH' | cut -d ' ' -f1")
    LOCAL_HASH=$(sha256sum "$LOCAL_DEST/$name" | cut -d ' ' -f1)

    if [ "$REMOTE_HASH" = "$LOCAL_HASH" ]; then
      echo "✅ Hash match: $name"
      ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "rm -f '$RSYNC_REMOTE_DIR/${name}.syncdone'"
    else
      echo "❌ Hash mismatch: $name — not deleting .syncdone"
    fi

  elif ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "[ -d '$REMOTE_PATH' ]"; then
    echo "📁 Directory detected — syncing contents of $name"
    retry_rsync "$REMOTE_SOURCE/" "$LOCAL_DEST"
    echo "✅ Folder synced: $name"
    ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "rm -f '$RSYNC_REMOTE_DIR/${name}.syncdone'"

  else
    echo "⚠️ Not found on remote: $name"
  fi
done < "$SYNC_LIST"

echo -e "\n🎉 Sync complete"