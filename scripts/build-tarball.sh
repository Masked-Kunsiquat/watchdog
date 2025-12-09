#!/usr/bin/env bash
set -Eeuo pipefail

# Build a release tarball containing the agent, configs, docs, and scripts.
# Usage: VERSION=1.0.0 ./scripts/build-tarball.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
VERSION="${VERSION:-$(/bin/cat "$ROOT_DIR/VERSION" 2>/dev/null || printf '')}"

if [[ -z "$VERSION" ]]; then
  echo "ERROR: VERSION not set and VERSION file missing" >&2
  exit 1
fi

STAGE_DIR="$DIST_DIR/netwatch-agent-$VERSION"
ARCHIVE="$DIST_DIR/netwatch-agent_${VERSION}.tar.gz"

/bin/rm -rf "$STAGE_DIR"
/bin/mkdir -p "$STAGE_DIR" "$DIST_DIR"

# Copy core assets
/bin/cp -a "$ROOT_DIR/src" "$STAGE_DIR/"
/bin/cp -a "$ROOT_DIR/config" "$STAGE_DIR/"
/bin/cp -a "$ROOT_DIR/scripts" "$STAGE_DIR/"
/bin/cp "$ROOT_DIR/README.md" "$ROOT_DIR/CHANGELOG.md" "$ROOT_DIR/LICENSE" "$ROOT_DIR/VERSION" "$STAGE_DIR/"

# Remove build artifacts from staged scripts to keep archive clean
/bin/rm -f "$STAGE_DIR/scripts/build-tarball.sh" "$STAGE_DIR/scripts/build-deb.sh" 2>/dev/null || true

/bin/tar -C "$DIST_DIR" -czf "$ARCHIVE" "netwatch-agent-$VERSION"

echo "Created $ARCHIVE"
