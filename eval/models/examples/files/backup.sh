#!/usr/bin/env bash
# Copy every log under SRC into a dated folder under DEST, then prune old ones.
set -eu

SRC=${1:?usage: backup.sh SRC DEST [KEEP]}
DEST=${2:?usage: backup.sh SRC DEST [KEEP]}
KEEP=${3:-7}

stamp=$(date +%Y-%m-%d)
target="$DEST/$stamp"
mkdir -p "$target"

for f in $SRC/*.log; do
  cp "$f" "$target/"
done

# keep the newest $KEEP backups, delete the rest
ls -1d "$DEST"/*/ | sort | head -n "$KEEP" | while read -r old; do
  rm -rf "$old"
done

echo "backed up to $target"
