#!/usr/bin/env bash
#
# uninstall.sh - Uninstaller for Netwatch WAN Watchdog
#
# Safely removes netwatch-agent from the system, stopping the service
# and cleaning up all installed files. Optionally preserves configuration.
#
# Usage: sudo ./uninstall.sh [--keep-config]
#

set -Eeuo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Installation paths
AGENT_SCRIPT="/usr/local/sbin/netwatch-agent.sh"
AGENT_BACKUP="/usr/local/sbin/netwatch-agent.sh.bak"
CONFIG_FILE="/etc/default/netwatch-agent"
CONFIG_NEW="/etc/default/netwatch-agent.new"
SYSTEMD_UNIT="/etc/systemd/system/netwatch-agent.service"
STATE_DIR="/run/netwatch-agent"

# Parse options
KEEP_CONFIG=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --keep-config)
      KEEP_CONFIG=true
      shift
      ;;
    *)
      echo "Usage: $0 [--keep-config]"
      exit 1
      ;;
  esac
done

#
# Utility functions
#

log_info() {
  echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

#
# Preflight checks
#

log_info "Netwatch WAN Watchdog Uninstaller"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root (use sudo)"
  exit 1
fi

#
# Stop and disable service
#

if systemctl is-active --quiet netwatch-agent 2>/dev/null; then
  log_info "Stopping netwatch-agent service"
  systemctl stop netwatch-agent
else
  log_info "Service is not running"
fi

if systemctl is-enabled --quiet netwatch-agent 2>/dev/null; then
  log_info "Disabling netwatch-agent service"
  systemctl disable netwatch-agent
else
  log_info "Service is not enabled"
fi

#
# Remove systemd unit
#

if [[ -f "$SYSTEMD_UNIT" ]]; then
  log_info "Removing systemd unit: $SYSTEMD_UNIT"
  rm -f "$SYSTEMD_UNIT"
else
  log_warn "Systemd unit not found: $SYSTEMD_UNIT"
fi

log_info "Reloading systemd daemon"
systemctl daemon-reload

#
# Remove agent script
#

if [[ -f "$AGENT_SCRIPT" ]]; then
  log_info "Removing agent script: $AGENT_SCRIPT"
  rm -f "$AGENT_SCRIPT"
else
  log_warn "Agent script not found: $AGENT_SCRIPT"
fi

if [[ -f "$AGENT_BACKUP" ]]; then
  log_info "Removing backup: $AGENT_BACKUP"
  rm -f "$AGENT_BACKUP"
fi

#
# Handle configuration file
#

if [[ "$KEEP_CONFIG" == true ]]; then
  if [[ -f "$CONFIG_FILE" ]]; then
    log_info "Preserving config: $CONFIG_FILE"
    log_info "Backed up to: ${CONFIG_FILE}.uninstall-backup"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.uninstall-backup"
  fi
else
  if [[ -f "$CONFIG_FILE" ]]; then
    log_info "Removing config: $CONFIG_FILE"
    rm -f "$CONFIG_FILE"
  else
    log_warn "Config file not found: $CONFIG_FILE"
  fi
fi

if [[ -f "$CONFIG_NEW" ]]; then
  log_info "Removing config template: $CONFIG_NEW"
  rm -f "$CONFIG_NEW"
fi

#
# Clean state directory
#

if [[ -d "$STATE_DIR" ]]; then
  log_info "Cleaning state directory: $STATE_DIR"
  rm -rf "$STATE_DIR"
fi

#
# Final status
#

echo
log_info "Uninstall complete!"

if [[ "$KEEP_CONFIG" == true ]]; then
  echo
  echo "Configuration preserved:"
  echo "  - Config: $CONFIG_FILE"
  echo "  - Backup: ${CONFIG_FILE}.uninstall-backup"
fi

echo
echo "Netwatch has been removed from your system."
echo "To reinstall, run: ./scripts/install.sh"
