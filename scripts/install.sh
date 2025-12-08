#!/usr/bin/env bash
#
# install.sh - Idempotent installer for Netwatch WAN Watchdog
#
# Installs netwatch-agent to /usr/local/sbin with proper permissions,
# systemd unit file, and configuration. Safe to run multiple times.
#
# Usage: sudo ./install.sh
#

set -Eeuo pipefail

# Color output for better UX
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script directory (allows running from anywhere)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Installation paths
AGENT_SCRIPT="/usr/local/sbin/netwatch-agent.sh"
CONFIG_FILE="/etc/default/netwatch-agent"
SYSTEMD_UNIT="/etc/systemd/system/netwatch-agent.service"

# Source files
SRC_AGENT="$PROJECT_ROOT/src/netwatch-agent.sh"
SRC_CONFIG="$PROJECT_ROOT/config/netwatch-agent.conf"
SRC_UNIT="$PROJECT_ROOT/config/netwatch-agent.service"

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

log_info "Netwatch WAN Watchdog Installer"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root (use sudo)"
  exit 1
fi

# Check if systemd is available
if [[ ! -x /usr/bin/systemctl ]]; then
  log_error "systemd is required but not found"
  exit 1
fi

# Check if source files exist
if [[ ! -f "$SRC_AGENT" ]]; then
  log_error "Agent script not found: $SRC_AGENT"
  exit 1
fi

if [[ ! -f "$SRC_CONFIG" ]]; then
  log_error "Config template not found: $SRC_CONFIG"
  exit 1
fi

if [[ ! -f "$SRC_UNIT" ]]; then
  log_error "Systemd unit not found: $SRC_UNIT"
  exit 1
fi

log_info "Preflight checks passed"

#
# Install agent script
#

if [[ -f "$AGENT_SCRIPT" ]]; then
  log_warn "Agent script exists, backing up to ${AGENT_SCRIPT}.bak"
  cp "$AGENT_SCRIPT" "${AGENT_SCRIPT}.bak"
fi

log_info "Installing agent script to $AGENT_SCRIPT"
cp "$SRC_AGENT" "$AGENT_SCRIPT"
chmod 0755 "$AGENT_SCRIPT"
chown root:root "$AGENT_SCRIPT"

#
# Install configuration file
#

if [[ -f "$CONFIG_FILE" ]]; then
  log_warn "Config file exists, preserving existing: $CONFIG_FILE"
  log_info "New config template available at: ${CONFIG_FILE}.new"
  cp "$SRC_CONFIG" "${CONFIG_FILE}.new"
  chmod 0640 "${CONFIG_FILE}.new"
  chown root:root "${CONFIG_FILE}.new"
else
  log_info "Installing config file to $CONFIG_FILE"
  cp "$SRC_CONFIG" "$CONFIG_FILE"
  chmod 0640 "$CONFIG_FILE"
  chown root:root "$CONFIG_FILE"
fi

#
# Install systemd unit
#

if [[ -f "$SYSTEMD_UNIT" ]]; then
  log_warn "Systemd unit exists, updating: $SYSTEMD_UNIT"
fi

log_info "Installing systemd unit to $SYSTEMD_UNIT"
cp "$SRC_UNIT" "$SYSTEMD_UNIT"
chmod 0644 "$SYSTEMD_UNIT"
chown root:root "$SYSTEMD_UNIT"

#
# Check for fping (optional but recommended)
#

if command -v fping >/dev/null 2>&1; then
  log_info "fping is installed (recommended for better performance)"
else
  log_warn "fping not found - will use fallback ping mode"
  if command -v apt-get >/dev/null 2>&1; then
    log_info "To install fping: apt-get install fping"
  elif command -v yum >/dev/null 2>&1; then
    log_info "To install fping: yum install fping"
  fi
fi

#
# Reload systemd and enable service
#

log_info "Reloading systemd daemon"
/usr/bin/systemctl daemon-reload

log_info "Enabling netwatch-agent service"
/usr/bin/systemctl enable netwatch-agent

# Check if service is already running
if /usr/bin/systemctl is-active --quiet netwatch-agent; then
  log_info "Service is already running, restarting"
  /usr/bin/systemctl restart netwatch-agent
else
  log_info "Starting netwatch-agent service"
  /usr/bin/systemctl start netwatch-agent
fi

#
# Display status and instructions
#

echo
log_info "Installation complete!"
echo

echo "Service status:"
/usr/bin/systemctl status netwatch-agent --no-pager --lines=5 || true

echo
echo "Quick reference:"
echo "  - View logs:      journalctl -u netwatch-agent -f"
echo "  - Stop service:   /usr/bin/systemctl stop netwatch-agent"
echo "  - Disable:        /usr/bin/systemctl disable netwatch-agent"
echo "  - Pause watchdog: touch /etc/netwatch-agent.disable"
echo "  - Resume:         rm /etc/netwatch-agent.disable"
echo "  - Edit config:    nano $CONFIG_FILE"
echo "  - Uninstall:      $SCRIPT_DIR/uninstall.sh"
echo

log_info "Configuration: $CONFIG_FILE"
log_info "Edit the config and restart: /usr/bin/systemctl restart netwatch-agent"
