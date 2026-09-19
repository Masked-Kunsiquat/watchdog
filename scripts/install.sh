#!/usr/bin/env bash
#
# install.sh - Idempotent installer for Netwatch WAN Watchdog
#
# Installs netwatch-agent to /usr/local/sbin with proper permissions,
# systemd unit file, and configuration. Safe to run multiple times.
#
# Usage: ./install.sh   (run as root or with sudo)
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
PERSIST_DIR="/var/lib/netwatch-agent"

# NIC health sampler (optional companion component)
NETPROBE_SCRIPT="/usr/local/sbin/netwatch-netprobe.sh"
NETPROBE_CONFIG="/etc/default/netwatch-netprobe"
NETPROBE_UNIT="/etc/systemd/system/netwatch-netprobe.service"
NETPROBE_TIMER="/etc/systemd/system/netwatch-netprobe.timer"
NETPROBE_LOGROTATE="/etc/logrotate.d/netwatch-netprobe"
DIGEST_SCRIPT="/usr/local/sbin/netwatch-digest.sh"
DIGEST_UNIT="/etc/systemd/system/netwatch-digest.service"
DIGEST_TIMER="/etc/systemd/system/netwatch-digest.timer"
SUMMARY_SCRIPT="/usr/local/sbin/netwatch-status-summary.sh"
NETPROBE_LOG_DIR="/var/log/netwatch"

# Source files
SRC_AGENT="$PROJECT_ROOT/src/netwatch-agent.sh"
SRC_CONFIG="$PROJECT_ROOT/config/netwatch-agent.conf"
SRC_UNIT="$PROJECT_ROOT/config/netwatch-agent.service"
SRC_NETPROBE="$PROJECT_ROOT/src/netwatch-netprobe.sh"
SRC_NETPROBE_CONFIG="$PROJECT_ROOT/config/netwatch-netprobe.conf"
SRC_NETPROBE_UNIT="$PROJECT_ROOT/config/netwatch-netprobe.service"
SRC_NETPROBE_TIMER="$PROJECT_ROOT/config/netwatch-netprobe.timer"
SRC_NETPROBE_LOGROTATE="$PROJECT_ROOT/config/netwatch-netprobe.logrotate"
SRC_DIGEST="$PROJECT_ROOT/src/netwatch-digest.sh"
SRC_DIGEST_CONF="$PROJECT_ROOT/config/netwatch-digest.conf"
SRC_DIGEST_UNIT="$PROJECT_ROOT/config/netwatch-digest.service"
SRC_DIGEST_TIMER="$PROJECT_ROOT/config/netwatch-digest.timer"
SRC_SUMMARY="$PROJECT_ROOT/scripts/netwatch-status-summary.sh"

# Install the NIC sampler unless explicitly disabled: INSTALL_NETPROBE=0
INSTALL_NETPROBE="${INSTALL_NETPROBE:-1}"

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

# Helper to run commands with sudo when not root
# Helper to run commands with sudo when not root
SUDO=""
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    log_error "This script must be run as root (sudo not available)"
    exit 1
  fi
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
  $SUDO cp "$AGENT_SCRIPT" "${AGENT_SCRIPT}.bak"
fi

log_info "Installing agent script to $AGENT_SCRIPT"
$SUDO cp "$SRC_AGENT" "$AGENT_SCRIPT"
$SUDO chmod 0755 "$AGENT_SCRIPT"
$SUDO chown root:root "$AGENT_SCRIPT"

#
# Install configuration file
#

if [[ -f "$CONFIG_FILE" ]]; then
  log_warn "Config file exists, preserving existing: $CONFIG_FILE"
  log_info "New config template available at: ${CONFIG_FILE}.new"
  $SUDO cp "$SRC_CONFIG" "${CONFIG_FILE}.new"
  $SUDO chmod 0640 "${CONFIG_FILE}.new"
  $SUDO chown root:root "${CONFIG_FILE}.new"
else
  log_info "Installing config file to $CONFIG_FILE"
  $SUDO cp "$SRC_CONFIG" "$CONFIG_FILE"
  $SUDO chmod 0640 "$CONFIG_FILE"
  $SUDO chown root:root "$CONFIG_FILE"
fi

#
# Install systemd unit
#

if [[ -f "$SYSTEMD_UNIT" ]]; then
  log_warn "Systemd unit exists, updating: $SYSTEMD_UNIT"
fi

log_info "Installing systemd unit to $SYSTEMD_UNIT"
$SUDO cp "$SRC_UNIT" "$SYSTEMD_UNIT"
$SUDO chmod 0644 "$SYSTEMD_UNIT"
$SUDO chown root:root "$SYSTEMD_UNIT"

#
# Create persistent state directory
#
# The agent creates this at runtime, but creating it here means correct
# ownership from the start and gives the uninstaller something to clean up.
#

log_info "Creating state directory $PERSIST_DIR"
$SUDO mkdir -p "$PERSIST_DIR"
$SUDO chmod 0750 "$PERSIST_DIR"
$SUDO chown root:root "$PERSIST_DIR"

#
# Status summary - installed regardless of INSTALL_NETPROBE, since knowing
# whether the watchdog is armed matters even without the NIC tooling.
#

$SUDO cp "$SRC_SUMMARY" "$SUMMARY_SCRIPT"
$SUDO chmod 0755 "$SUMMARY_SCRIPT"
$SUDO chown root:root "$SUMMARY_SCRIPT"

#
# Install NIC health sampler (optional companion)
#

if [[ "$INSTALL_NETPROBE" == "1" ]] && [[ -f "$SRC_NETPROBE" ]]; then
  log_info "Installing NIC health sampler"

  $SUDO cp "$SRC_NETPROBE" "$NETPROBE_SCRIPT"
  $SUDO chmod 0755 "$NETPROBE_SCRIPT"
  $SUDO chown root:root "$NETPROBE_SCRIPT"

  if [[ -f "$NETPROBE_CONFIG" ]]; then
    log_warn "Sampler config exists, preserving: $NETPROBE_CONFIG"
    $SUDO cp "$SRC_NETPROBE_CONFIG" "${NETPROBE_CONFIG}.new"
    $SUDO chmod 0640 "${NETPROBE_CONFIG}.new"
    $SUDO chown root:root "${NETPROBE_CONFIG}.new"
  else
    $SUDO cp "$SRC_NETPROBE_CONFIG" "$NETPROBE_CONFIG"
    $SUDO chmod 0640 "$NETPROBE_CONFIG"
    $SUDO chown root:root "$NETPROBE_CONFIG"
  fi

  $SUDO cp "$SRC_NETPROBE_UNIT" "$NETPROBE_UNIT"
  $SUDO chmod 0644 "$NETPROBE_UNIT"
  $SUDO chown root:root "$NETPROBE_UNIT"

  $SUDO cp "$SRC_NETPROBE_TIMER" "$NETPROBE_TIMER"
  $SUDO chmod 0644 "$NETPROBE_TIMER"
  $SUDO chown root:root "$NETPROBE_TIMER"

  $SUDO mkdir -p "$NETPROBE_LOG_DIR"
  $SUDO chmod 0755 "$NETPROBE_LOG_DIR"
  $SUDO chown root:root "$NETPROBE_LOG_DIR"

  if [[ -d /etc/logrotate.d ]]; then
    $SUDO cp "$SRC_NETPROBE_LOGROTATE" "$NETPROBE_LOGROTATE"
    $SUDO chmod 0644 "$NETPROBE_LOGROTATE"
    $SUDO chown root:root "$NETPROBE_LOGROTATE"
  else
    log_warn "/etc/logrotate.d not found - the sampler log will not be rotated"
  fi

  # Daily diagnostic digest (timer-driven, independent of the agent)
  $SUDO cp "$SRC_DIGEST" "$DIGEST_SCRIPT"
  $SUDO chmod 0755 "$DIGEST_SCRIPT"
  $SUDO chown root:root "$DIGEST_SCRIPT"

  $SUDO cp "$SRC_DIGEST_UNIT" "$DIGEST_UNIT"
  $SUDO chmod 0644 "$DIGEST_UNIT"
  $SUDO chown root:root "$DIGEST_UNIT"

  $SUDO cp "$SRC_DIGEST_TIMER" "$DIGEST_TIMER"
  $SUDO chmod 0644 "$DIGEST_TIMER"
  $SUDO chown root:root "$DIGEST_TIMER"

  # Append digest settings to the sampler config on first install only, so an
  # operator's edits are never overwritten.
  if ! $SUDO grep -q 'DIGEST_ENABLED' "$NETPROBE_CONFIG" 2>/dev/null; then
    log_info "Adding digest settings to $NETPROBE_CONFIG"
    $SUDO tee -a "$NETPROBE_CONFIG" < "$SRC_DIGEST_CONF" > /dev/null
  fi

  if ! command -v ethtool >/dev/null 2>&1; then
    log_warn "ethtool not found - the sampler needs it for driver counters"
    log_info "Install it with: apt-get install ethtool"
  fi
else
  log_info "Skipping NIC health sampler (INSTALL_NETPROBE=0)"
fi

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
$SUDO /usr/bin/systemctl daemon-reload

log_info "Enabling netwatch-agent service"
$SUDO /usr/bin/systemctl enable netwatch-agent

if [[ "$INSTALL_NETPROBE" == "1" ]] && [[ -f "$NETPROBE_TIMER" ]]; then
  log_info "Enabling netwatch-netprobe timer"
  $SUDO /usr/bin/systemctl enable --now netwatch-netprobe.timer
fi

if [[ "$INSTALL_NETPROBE" == "1" ]] && [[ -f "$DIGEST_TIMER" ]]; then
  log_info "Enabling netwatch-digest timer (daily summary)"
  $SUDO /usr/bin/systemctl enable --now netwatch-digest.timer
fi

# Check if service is already running
if $SUDO /usr/bin/systemctl is-active --quiet netwatch-agent; then
  log_info "Service is already running, restarting"
  $SUDO /usr/bin/systemctl restart netwatch-agent
else
  log_info "Starting netwatch-agent service"
  $SUDO /usr/bin/systemctl start netwatch-agent
fi

#
# Display status and instructions
#

echo
log_info "Installation complete!"
echo

echo "Service status:"
$SUDO /usr/bin/systemctl status netwatch-agent --no-pager --lines=5 || true

# Report the resulting state. The file-copy logging above says what was
# written; this says what is actually armed - the question that matters, and
# the one a silent config reset would otherwise hide.
if [[ -x "$SUMMARY_SCRIPT" ]]; then
  $SUDO "$SUMMARY_SCRIPT" || true
fi

echo "Quick reference:"
echo "  - Status again:   netwatch-status-summary.sh"
echo "  - View logs:      journalctl -u netwatch-agent -f"
echo "  - NIC anomalies:  journalctl -t netwatch-netprobe -p crit --no-pager"
echo "  - Send a digest:  systemctl start netwatch-digest.service"
echo "  - Pause watchdog: touch /etc/netwatch-agent.disable"
echo "  - Edit config:    nano $CONFIG_FILE"
echo "  - Uninstall:      $SCRIPT_DIR/uninstall.sh"
echo
