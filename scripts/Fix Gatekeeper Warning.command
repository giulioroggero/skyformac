#!/usr/bin/env bash
set -euo pipefail

# Skyformac isn't notarized by Apple yet (that needs a paid Apple Developer Program
# membership — see docs/distribution.md), so macOS Gatekeeper quarantines it on
# download and refuses to open it the normal way ("skyformac.app is damaged and
# can't be opened" / "cannot be opened because the developer cannot be verified").
# The app itself is fine — this just clears that quarantine flag so it can run.
#
# Double-click this file in Finder to run it (Terminal opens automatically), or
# run it directly: ./"Fix Gatekeeper Warning.command"

cd "$(dirname "$0")"

APP="skyformac.app"
if [ ! -d "$APP" ]; then
  # Fall back to whatever .app is sitting alongside this script, in case it's been
  # renamed by the browser (e.g. "skyformac 2.app" for a repeat download).
  APP=$(find . -maxdepth 1 -iname "*.app" -print -quit)
fi

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "error: couldn't find a .app next to this script — make sure this file stays" >&2
  echo "in the same folder as skyformac.app (e.g. wherever you unzipped the download)." >&2
  exit 1
fi

echo "==> Clearing the quarantine flag from \"$APP\"…"
find "$APP" -exec xattr -d com.apple.quarantine {} \; 2>/dev/null || true

echo "==> Done. \"$APP\" should now open normally — double-click it in Finder."
read -r -p "Press Return to close this window…"
