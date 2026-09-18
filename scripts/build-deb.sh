#!/usr/bin/env bash
set -Eeuo pipefail

# Build a Debian package using dpkg-deb (no network, pure staging).
# Usage: VERSION=1.0.0 ./scripts/build-deb.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
VERSION="${VERSION:-$(/bin/cat "$ROOT_DIR/VERSION" 2>/dev/null || printf '')}"

if [[ -z "$VERSION" ]]; then
  echo "ERROR: VERSION not set and VERSION file missing" >&2
  exit 1
fi

STAGE_DIR="$DIST_DIR/netwatch-agent_${VERSION}"
DEB_PATH="$DIST_DIR/netwatch-agent_${VERSION}_all.deb"

/bin/rm -rf "$STAGE_DIR"
/bin/mkdir -p "$STAGE_DIR/DEBIAN" \
  "$STAGE_DIR/usr/local/sbin" \
  "$STAGE_DIR/etc/default" \
  "$STAGE_DIR/etc/systemd/system" \
  "$STAGE_DIR/etc/logrotate.d" \
  "$STAGE_DIR/usr/share/doc/netwatch-agent"

# Install files with correct permissions
/usr/bin/install -m 0755 "$ROOT_DIR/src/netwatch-agent.sh" "$STAGE_DIR/usr/local/sbin/netwatch-agent.sh"
/usr/bin/install -m 0644 "$ROOT_DIR/config/netwatch-agent.conf" "$STAGE_DIR/etc/default/netwatch-agent"
/usr/bin/install -m 0644 "$ROOT_DIR/config/netwatch-agent.service" "$STAGE_DIR/etc/systemd/system/netwatch-agent.service"

# NIC health sampler and remediation tooling
/usr/bin/install -m 0755 "$ROOT_DIR/src/netwatch-netprobe.sh" "$STAGE_DIR/usr/local/sbin/netwatch-netprobe.sh"
/usr/bin/install -m 0644 "$ROOT_DIR/config/netwatch-netprobe.conf" "$STAGE_DIR/etc/default/netwatch-netprobe"
/usr/bin/install -m 0644 "$ROOT_DIR/config/netwatch-netprobe.service" "$STAGE_DIR/etc/systemd/system/netwatch-netprobe.service"
/usr/bin/install -m 0644 "$ROOT_DIR/config/netwatch-netprobe.timer" "$STAGE_DIR/etc/systemd/system/netwatch-netprobe.timer"
/usr/bin/install -m 0644 "$ROOT_DIR/config/netwatch-netprobe.logrotate" "$STAGE_DIR/etc/logrotate.d/netwatch-netprobe"
/usr/bin/install -m 0755 "$ROOT_DIR/scripts/netwatch-nic-remediation.sh" "$STAGE_DIR/usr/local/sbin/netwatch-nic-remediation.sh"
/usr/bin/install -m 0755 "$ROOT_DIR/scripts/netwatch-postmortem.sh" "$STAGE_DIR/usr/local/sbin/netwatch-postmortem.sh"
/usr/bin/install -m 0755 "$ROOT_DIR/scripts/netwatch-setup-journald.sh" "$STAGE_DIR/usr/local/sbin/netwatch-setup-journald.sh"
/usr/bin/install -m 0644 "$ROOT_DIR/LICENSE" "$STAGE_DIR/usr/share/doc/netwatch-agent/copyright"
/usr/bin/install -m 0644 "$ROOT_DIR/README.md" "$ROOT_DIR/CHANGELOG.md" "$ROOT_DIR/VERSION" "$STAGE_DIR/usr/share/doc/netwatch-agent/"

# Compress changelog per Debian policy (keep simple gzip)
/bin/gzip -fn9 "$STAGE_DIR/usr/share/doc/netwatch-agent/CHANGELOG.md"

# Control file
cat >"$STAGE_DIR/DEBIAN/control" <<EOF
Package: netwatch-agent
Version: ${VERSION}
Section: admin
Priority: optional
Architecture: all
Maintainer: Netwatch Maintainers <root@localhost>
Depends: bash, systemd, iproute2, procps
Recommends: fping | iputils-ping, ethtool
Suggests: curl, netcat-openbsd
Description: WAN watchdog for Proxmox VE (reboots on sustained WAN loss)
 Monitor WAN reachability via ICMP/TCP/HTTP targets and reboot after a
 configured outage window. Includes safety rails (boot grace, cooldown),
 dry-run mode, and systemd integration.
 .
 Also ships a local NIC health sampler that records link state, driver error
 counters, and offload configuration, plus tooling to diagnose and remediate
 Intel e1000e "Detected Hardware Unit Hang" failures on I217/I218/I219 NICs.
EOF

# Post-install: reload daemon and enable service
/bin/cat >"$STAGE_DIR/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
mkdir -p /var/lib/netwatch-agent /var/log/netwatch
chmod 0750 /var/lib/netwatch-agent
chmod 0755 /var/log/netwatch
if [ -x /usr/bin/systemctl ]; then
  /usr/bin/systemctl daemon-reload || true
  /usr/bin/systemctl enable --now netwatch-agent.service || true
  /usr/bin/systemctl enable --now netwatch-netprobe.timer || true
fi
exit 0
EOF

# Pre-remove: stop service and timer
/bin/cat >"$STAGE_DIR/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ -x /usr/bin/systemctl ]; then
  /usr/bin/systemctl stop netwatch-netprobe.timer || true
  /usr/bin/systemctl stop netwatch-agent.service || true
fi
exit 0
EOF

/bin/chmod 0755 "$STAGE_DIR/DEBIAN/postinst" "$STAGE_DIR/DEBIAN/prerm"

/usr/bin/dpkg-deb --build "$STAGE_DIR" "$DEB_PATH"

echo "Created $DEB_PATH"
