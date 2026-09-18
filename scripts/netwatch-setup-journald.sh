#!/usr/bin/env bash
#
# netwatch-setup-journald.sh - Persistent, size-capped journald
#
# Ensures the systemd journal survives reboots (so `journalctl -b -1` can show
# what happened before an outage) and is bounded in size (so it cannot fill the
# root filesystem).
#
# Without persistent storage the journal lives in a tmpfs at /run/log/journal
# and is wiped on every boot - `journalctl -b -1` then returns nothing and
# post-mortem analysis of an outage is impossible.
#
# Drop-in precedence note: systemd sorts *.conf.d/ snippets lexicographically
# by filename ACROSS all config directories (/usr/lib, /run, /etc), and for
# single-value options the LAST file sorted wins. A vendor file named e.g.
# 40-foo.conf would therefore override an admin file named 10-bar.conf. This
# script uses a 90- prefix so it reliably takes precedence.
#
# Usage:
#   ./netwatch-setup-journald.sh --check     # report only, change nothing
#   ./netwatch-setup-journald.sh --apply     # write the drop-in and restart
#
# License: MIT
#

set -Eeuo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DROPIN_DIR="${DROPIN_DIR:-/etc/systemd/journald.conf.d}"
DROPIN_FILE="$DROPIN_DIR/90-netwatch.conf"
JOURNAL_DIR="${JOURNAL_DIR:-/var/log/journal}"

# Retention targets for a small host: bounded size, ~1 month of history
SYSTEM_MAX_USE="${SYSTEM_MAX_USE:-2G}"
SYSTEM_KEEP_FREE="${SYSTEM_KEEP_FREE:-1G}"
SYSTEM_MAX_FILE_SIZE="${SYSTEM_MAX_FILE_SIZE:-64M}"
MAX_RETENTION="${MAX_RETENTION:-1month}"

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) ACTION="check"; shift ;;
    --apply) ACTION="apply"; shift ;;
    -h|--help)
      /bin/sed -n '2,24p' "$0" | /bin/sed 's/^# \?//'
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      echo "Usage: $0 --check | --apply"
      exit 1
      ;;
  esac
done

if [[ -z "$ACTION" ]]; then
  echo "Usage: $0 --check | --apply"
  exit 1
fi

#
# Report current journal configuration and health.
#
show_status() {
  echo
  echo "=============================================="
  echo " journald Status"
  echo "=============================================="

  if [[ -d "$JOURNAL_DIR" ]]; then
    log_info "Persistent storage: ENABLED ($JOURNAL_DIR exists)"
    echo "  permissions: $(/usr/bin/stat -c '%A %U:%G' "$JOURNAL_DIR" 2>/dev/null || echo unknown)"
  else
    log_warn "Persistent storage: DISABLED ($JOURNAL_DIR missing)"
    echo "  'journalctl -b -1' will return nothing after a reboot."
  fi

  echo "  disk usage:  $(/usr/bin/journalctl --disk-usage 2>&1 | /usr/bin/tail -1)"
  echo

  echo "--- boots retained ---"
  /usr/bin/journalctl --list-boots --no-pager 2>&1 | /usr/bin/tail -8 | /bin/sed 's/^/  /'
  echo

  echo "--- existing drop-ins (later filenames win) ---"
  local found=0
  local d f
  for d in /usr/lib/systemd/journald.conf.d /run/systemd/journald.conf.d "$DROPIN_DIR"; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*.conf; do
      [[ -e "$f" ]] || continue
      echo "  $f"
      found=1
    done
  done
  (( found )) || echo "  (none)"
  echo

  echo "--- effective size limits ---"
  local limits
  limits=$(/usr/bin/systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
    | /bin/grep -E '^[[:space:]]*(Storage|SystemMaxUse|SystemKeepFree|MaxRetentionSec|SystemMaxFileSize)=' || true)
  if [[ -n "$limits" ]]; then
    echo "$limits" | /bin/sed 's/^/  /'
  else
    echo "  (no explicit limits set - systemd defaults to 10% of the filesystem, capped at 4G)"
  fi
  echo
}

show_status

if [[ "$ACTION" == "check" ]]; then
  log_info "Check only; nothing was changed."
  exit 0
fi

# --- apply ---

if [[ $EUID -ne 0 ]]; then
  log_error "--apply must be run as root"
  exit 1
fi

# Create the journal directory only if absent. When it already exists, leave it
# alone: re-running systemd-tmpfiles on a healthy directory is unnecessary and
# would touch ownership on a working setup.
if [[ ! -d "$JOURNAL_DIR" ]]; then
  log_info "Creating $JOURNAL_DIR"
  /bin/mkdir -p "$JOURNAL_DIR"
  if [[ -x /usr/bin/systemd-tmpfiles ]]; then
    # Applies systemd's shipped ownership/mode (root:systemd-journal, 2755).
    # A bare mkdir would leave root:root 0755, which is wrong.
    /usr/bin/systemd-tmpfiles --create --prefix "$JOURNAL_DIR" || true
  fi
  NEEDS_FLUSH=1
else
  log_info "$JOURNAL_DIR already exists; leaving ownership untouched"
  NEEDS_FLUSH=0
fi

/bin/mkdir -p "$DROPIN_DIR"

if [[ -f "$DROPIN_FILE" ]]; then
  log_info "Updating existing $DROPIN_FILE"
else
  log_info "Creating $DROPIN_FILE"
fi

/bin/cat > "$DROPIN_FILE" <<EOF
# Managed by netwatch-setup-journald.sh
#
# The 90- prefix matters: systemd sorts drop-ins lexicographically across all
# config directories and, for single-value options, the last file wins. A
# vendor-shipped file (e.g. 40-something.conf under /usr/lib) would otherwise
# override these settings.

[Journal]
# Survive reboots so post-mortem analysis of an outage is possible
Storage=persistent

# Bound total size so the journal cannot fill the root filesystem
SystemMaxUse=$SYSTEM_MAX_USE
SystemKeepFree=$SYSTEM_KEEP_FREE
SystemMaxFileSize=$SYSTEM_MAX_FILE_SIZE
MaxRetentionSec=$MAX_RETENTION
EOF

/bin/chmod 0644 "$DROPIN_FILE"
log_info "Wrote $DROPIN_FILE"

if (( NEEDS_FLUSH )); then
  # Migrates any existing volatile journal into persistent storage. Restarting
  # journald alone can leave the switch a silent no-op.
  log_info "Flushing volatile journal to persistent storage"
  /usr/bin/journalctl --flush || true
fi

log_info "Restarting systemd-journald"
/usr/bin/systemctl restart systemd-journald

echo
log_info "Applied. Verifying:"
show_status

if [[ -d "$JOURNAL_DIR" ]]; then
  log_info "Persistence confirmed."
  echo "After the next reboot, verify previous-boot access with:"
  echo "    journalctl --list-boots"
  echo "    journalctl -k -b -1 --no-pager | tail"
else
  log_error "$JOURNAL_DIR still missing - persistence is NOT active."
  exit 1
fi
