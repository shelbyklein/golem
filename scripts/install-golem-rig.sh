#!/bin/sh
# Copies Golem's live rig (Golem/rig: golem.json, stone and eye images, head.png) into the
# assistant's Avatar folder, where Chatterbox picks it up within a few seconds and the iPhone
# app fetches it from the Mac. Any <mood>.mov files already there stay as the fallback.
set -e
cd "$(dirname "$0")/.."
AVATAR="${CHATTERBOX_AVATAR_DIR:-$HOME/Chatterbox/Dot/Avatar}"
mkdir -p "$AVATAR"
# golem.json goes last, so the app never reads a rig whose images haven't landed yet.
for f in Golem/rig/*.png; do cp "$f" "$AVATAR/"; done
cp Golem/rig/golem.json "$AVATAR/golem.json.tmp" && mv "$AVATAR/golem.json.tmp" "$AVATAR/golem.json"
echo "Installed Golem's rig in $AVATAR"
