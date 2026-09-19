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
/usr/bin/install -m 0640 "$ROOT_DIR/config/netwatch-agent.conf" "$STAGE_DIR/etc/default/netwatch-agent"
/usr/bin/install -m 0644 "$ROOT_DIR/config/netwatch-agent.service" "$STAGE_DIR/etc/systemd/system/netwatch-agent.service"

# NIC health sampler and remediation tooling
/usr/bin/install -m 0755 "$ROOT_DIR/src/netwatch-netprobe.sh" "$STAGE_DIR/usr/local/sbin/netwatch-netprobe.sh"
/usr/bin/install -m 0640 "$ROOT_DIR/config/netwatch-netprobe.conf" "$STAGE_DIR/etc/default/netwatch-netprobe"
/usr/bin/install -m 0644 "$ROOT_DIR/config/netwatch-netprobe.service" "$STAGE_DIR/etc/systemd/system/netwatch-netprobe.service"
/usr/bin/install -m 0644 "$ROOT_DIR/config/netwatch-netprobe.timer" "$STAGE_DIR/etc/systemd/system/netwatch-netprobe.timer"
/usr/bin/install -m 0644 "$ROOT_DIR/config/netwatch-netprobe.logrotate" "$STAGE_DIR/etc/logrotate.d/netwatch-netprobe"
/usr/bin/install -m 0755 "$ROOT_DIR/scripts/netwatch-nic-remediation.sh" "$STAGE_DIR/usr/local/sbin/netwatch-nic-remediation.sh"
/usr/bin/install -m 0755 "$ROOT_DIR/scripts/netwatch-postmortem.sh" "$STAGE_DIR/usr/local/sbin/netwatch-postmortem.sh"
/usr/bin/install -m 0755 "$ROOT_DIR/scripts/netwatch-setup-journald.sh" "$STAGE_DIR/usr/local/sbin/netwatch-setup-journald.sh"
/usr/bin/install -m 0755 "$ROOT_DIR/scripts/netwatch-status-summary.sh" "$STAGE_DIR/usr/local/sbin/netwatch-status-summary.sh"
/usr/bin/install -m 0755 "$ROOT_DIR/src/netwatch-digest.sh" "$STAGE_DIR/usr/local/sbin/netwatch-digest.sh"
/usr/bin/install -m 0644 "$ROOT_DIR/config/netwatch-digest.service" "$STAGE_DIR/etc/systemd/system/netwatch-digest.service"
/usr/bin/install -m 0644 "$ROOT_DIR/config/netwatch-digest.timer" "$STAGE_DIR/etc/systemd/system/netwatch-digest.timer"

# The digest reads its settings from the sampler config, so append them here the
# same way install.sh does. Without this the package ships no DIGEST_* keys and
# the digest silently falls back to built-in defaults.
/bin/cat "$ROOT_DIR/config/netwatch-digest.conf" >> "$STAGE_DIR/etc/default/netwatch-netprobe"
/usr/bin/install -m 0644 "$ROOT_DIR/LICENSE" "$STAGE_DIR/usr/share/doc/netwatch-agent/copyright"
/usr/bin/install -m 0644 "$ROOT_DIR/README.md" "$ROOT_DIR/CHANGELOG.md" "$ROOT_DIR/VERSION" "$STAGE_DIR/usr/share/doc/netwatch-agent/"

# Declare the config files as dpkg conffiles.
#
# Without this, dpkg treats them as ordinary package files and silently
# overwrites local edits on every upgrade - losing webhook URLs, DRY_RUN, and
# custom targets. Declared here, dpkg preserves a modified file and reports the
# difference instead.
/bin/cat >"$STAGE_DIR/DEBIAN/conffiles" <<'EOF'
/etc/default/netwatch-agent
/etc/default/netwatch-netprobe
/etc/logrotate.d/netwatch-netprobe
EOF

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

# Post-install: reload daemon, enable on FIRST install only
#
# $1 is "configure" on a fresh install and "configure <old-version>" on an
# upgrade. Enabling unconditionally would silently re-enable timers the
# operator had deliberately disabled, so only enable when $2 is empty.
/bin/cat >"$STAGE_DIR/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

case "$1" in
  configure)
    # Create state directories if absent. mkdir -p leaves an existing directory
    # untouched, so metrics.dat and the digest baseline survive an upgrade -
    # they hold lifetime counters that cannot be reconstructed.
    mkdir -p /var/lib/netwatch-agent /var/log/netwatch
    chmod 0750 /var/lib/netwatch-agent
    chmod 0755 /var/log/netwatch

    if [ -x /usr/bin/systemctl ]; then
      /usr/bin/systemctl daemon-reload || true

      if [ -z "$2" ]; then
        # Fresh install: enable and start everything.
        /usr/bin/systemctl enable --now netwatch-agent.service || true
        /usr/bin/systemctl enable --now netwatch-netprobe.timer || true
        /usr/bin/systemctl enable --now netwatch-digest.timer || true
      else
        # Upgrade: restart only what is already enabled, so a deliberately
        # disabled component stays disabled.
        for unit in netwatch-agent.service netwatch-netprobe.timer netwatch-digest.timer; do
          if /usr/bin/systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            /usr/bin/systemctl restart "$unit" || true
          fi
        done
      fi
    fi

    # Report the resulting state. dpkg is otherwise nearly silent, so an
    # upgrade that changed what the watchdog will do would give no sign of it.
    if [ -x /usr/local/sbin/netwatch-status-summary.sh ]; then
      /usr/local/sbin/netwatch-status-summary.sh || true
    fi
    ;;
esac

exit 0
EOF

# Pre-remove: stop units before their files disappear
#
# Runs for both "remove" and "upgrade". Stopping on upgrade is correct - the
# new postinst restarts whatever was enabled.
/bin/cat >"$STAGE_DIR/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e

case "$1" in
  remove|upgrade|deconfigure)
    if [ -x /usr/bin/systemctl ]; then
      # Stop each timer first so no new run starts, then the oneshot service
      # itself - a run already in flight would otherwise keep going while its
      # files are removed underneath it.
      /usr/bin/systemctl stop netwatch-digest.timer || true
      /usr/bin/systemctl stop netwatch-digest.service || true
      /usr/bin/systemctl stop netwatch-netprobe.timer || true
      /usr/bin/systemctl stop netwatch-netprobe.service || true
      /usr/bin/systemctl stop netwatch-agent.service || true
    fi
    ;;
esac

exit 0
EOF

# Post-remove: disable units and reload, so systemd does not keep dangling
# symlinks in /etc/systemd/system/*.wants/ pointing at deleted unit files.
# Without this, `systemctl list-unit-files` reports the units as enabled long
# after the package is gone.
/bin/cat >"$STAGE_DIR/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e

case "$1" in
  remove|purge)
    if [ -x /usr/bin/systemctl ]; then
      /usr/bin/systemctl disable netwatch-digest.timer || true
      /usr/bin/systemctl disable netwatch-netprobe.timer || true
      /usr/bin/systemctl disable netwatch-agent.service || true
      /usr/bin/systemctl daemon-reload || true
      /usr/bin/systemctl reset-failed netwatch-agent.service || true
    fi
    ;;
esac

# purge additionally drops collected state. Diagnostic logs may be the only
# record of a past outage, so they are kept on a plain `remove`.
if [ "$1" = "purge" ]; then
  rm -rf /var/lib/netwatch-agent
  rm -rf /var/log/netwatch
  rm -f /etc/netwatch-agent.disable
fi

exit 0
EOF

/bin/chmod 0755 "$STAGE_DIR/DEBIAN/postinst" "$STAGE_DIR/DEBIAN/prerm" "$STAGE_DIR/DEBIAN/postrm"

/usr/bin/dpkg-deb --build "$STAGE_DIR" "$DEB_PATH"

echo "Created $DEB_PATH"
