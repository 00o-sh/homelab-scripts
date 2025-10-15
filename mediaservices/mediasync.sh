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
printf "Host *\n\tStrictHostKeyChecking no\n" > ~/.ssh/config
chmod 600 ~/.ssh/config

# === Vars (same paths you used) ===
SYNC_LIST=/tmp/sync_list.txt
LOCAL_DEST="/local"
mkdir -p "$LOCAL_DEST"

log() { printf "%s %s\n" "$(date '+%F %T')" "$*"; }

# Retry wrapper that won't exit the whole script when rsync fails
retry_rsync() {
  # args: <src> <dest>
  src="$1"
  dest="$2"
  attempts=0
  max_attempts=3
  while [ "$attempts" -lt "$max_attempts" ]; do
    attempts=$((attempts+1))
    log "rsync attempt $attempts/$max_attempts: $src -> $dest"
    # Allow rsync to fail without killing script
    set +e
    rsync -avz --append-verify --partial \
      --progress --info=flist2,progress2,name0 --compress-choice=zstd \
      --no-perms --no-owner --no-group \
      -e "ssh $SSH_OPTS" \
      "$src" "$dest"
    status=$?
    set -e
    if [ $status -eq 0 ]; then
      log "rsync completed."
      return 0
    fi
    if [ "$attempts" -lt "$max_attempts" ]; then
      log "rsync failed (status $status). Retrying in 10s…"
      sleep 10
    else
      log "rsync failed after $attempts attempts (status $status)."
      return $status
    fi
  done
}

remote_is_file() { ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "[ -f \"$1\" ]"; }
remote_is_dir()  { ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "[ -d \"$1\" ]"; }
remote_sha256() {
  set +e
  out=$(ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "sha256sum \"$1\" | cut -d ' ' -f1" 2>/dev/null)
  rc=$?
  set -e
  [ $rc -eq 0 ] && printf "%s" "$out" || printf ""
}
local_sha256()  { sha256sum "$1" | cut -d ' ' -f1; }
remote_rm()     { set +e; ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" "rm -f \"$1\""; set -e; }

# === Get list of .syncdone files ===
log "Getting .syncdone files from $RSYNC_REMOTE_HOST..."
set +e
ssh $SSH_OPTS "$RSYNC_REMOTE_HOST" \
  "find '$RSYNC_REMOTE_DIR' -maxdepth 1 -type f -name '*.syncdone' -printf '%f\n'" > "$SYNC_LIST"
rc=$?
set -e
[ $rc -ne 0 ] && : > "$SYNC_LIST"

count=$(wc -l < "$SYNC_LIST" | tr -d ' ')
log "Found $count items"
[ "$count" -gt 0 ] && cat "$SYNC_LIST"

# === Begin sync loop ===
while IFS= read -r syncdone; do
  [ -z "$syncdone" ] && continue
  name="${syncdone%.syncdone}"
  log "Processing: $name"

  REMOTE_PATH="$RSYNC_REMOTE_DIR/$name"
  REMOTE_SOURCE="$RSYNC_REMOTE_HOST:$REMOTE_PATH"

  if remote_is_file "$REMOTE_PATH"; then
    log "File detected — syncing $name"

    if [ -f "$LOCAL_DEST/$name" ]; then
      R_HASH="$(remote_sha256 "$REMOTE_PATH")"
      L_HASH="$(local_sha256 "$LOCAL_DEST/$name")"
      if [ -n "$R_HASH" ] && [ "$R_HASH" = "$L_HASH" ]; then
        log "Local file already complete (hash match). Removing marker."
        remote_rm "$RSYNC_REMOTE_DIR/${name}.syncdone"
        continue
      fi
      log "Local exists but hash mismatch. Will resume transfer."
    fi

    if retry_rsync "$REMOTE_SOURCE" "$LOCAL_DEST"; then
      R_HASH="$(remote_sha256 "$REMOTE_PATH")"
      L_HASH="$(local_sha256 "$LOCAL_DEST/$name")"
      if [ -n "$R_HASH" ] && [ "$R_HASH" = "$L_HASH" ]; then
        log "Hash match: $name"
        remote_rm "$RSYNC_REMOTE_DIR/${name}.syncdone"
      else
        log "Hash mismatch: $name — leaving .syncdone in place"
      fi
    else
      log "Give up on $name after retries — leaving .syncdone in place"
    fi

  elif remote_is_dir "$REMOTE_PATH"; then
    log "Directory detected — syncing contents of $name"
    if retry_rsync "$REMOTE_SOURCE/" "$LOCAL_DEST"; then
      log "Folder synced: $name"
      remote_rm "$RSYNC_REMOTE_DIR/${name}.syncdone"
    else
      log "Folder failed after retries — leaving .syncdone in place"
    fi

  else
    log "Not found on remote: $name"
  fi
done < "$SYNC_LIST"

log "Sync complete"