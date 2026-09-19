#!/usr/bin/env bash
#
# netwatch-config-merge.sh - Add new config keys after a package upgrade
#
# dpkg deliberately never merges config files: it cannot know whether a local
# edit conflicts with an upstream change, so it prompts and you keep one side.
# Keeping your side is usually right - it preserves your webhook URL, DRY_RUN,
# and targets - but it also means new settings added upstream are absent, and
# the features behind them silently stay off.
#
# This appends ONLY the keys your config is missing, with their shipped
# defaults and comments. It never modifies a value you have already set, and
# never removes anything.
#
# Usage:
#   netwatch-config-merge.sh            # report what is missing, change nothing
#   netwatch-config-merge.sh --apply    # append the missing keys
#
# License: MIT
#

set -Eeuo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

APPLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    -h|--help)
      /bin/sed -n '2,20p' "$0" | /bin/sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Usage: $0 [--apply]" >&2
      exit 1
      ;;
  esac
done

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# List the KEY names assigned in a config file, ignoring comments.
config_keys() {
  local file="$1"
  [[ -r "$file" ]] || return 0
  /bin/grep -oE '^[[:space:]]*[A-Z_][A-Z0-9_]*=' "$file" 2>/dev/null \
    | /bin/sed 's/[[:space:]]*//g; s/=$//' \
    | /usr/bin/sort -u
}

# Print the comment block immediately preceding a key, plus the key line, so an
# appended setting arrives with its documentation rather than bare.
extract_key_block() {
  local file="$1" key="$2"

  /usr/bin/awk -v want="$key" '
    # Collect consecutive comment lines as the running block
    /^[[:space:]]*#/ { block = block $0 "\n"; next }
    # A blank line ends the block
    /^[[:space:]]*$/ { block = ""; next }
    {
      # An assignment to the key we want: emit its comments then the line
      if ($0 ~ "^[[:space:]]*" want "=") {
        printf "%s%s\n", block, $0
        exit
      }
      block = ""
    }
  ' "$file"
}

#
# Locate the pair of files to compare.
#
# dpkg writes the maintainer version to .dpkg-dist when you keep yours. If that
# is absent (installed via install.sh, or an older upgrade), fall back to the
# template shipped in /usr/share/doc.
#
find_reference() {
  local live="$1"

  if [[ -f "${live}.dpkg-dist" ]]; then
    echo "${live}.dpkg-dist"
    return 0
  fi
  if [[ -f "${live}.new" ]]; then
    echo "${live}.new"
    return 0
  fi
  return 1
}

CHANGED=0
CHECKED=0

for LIVE in /etc/default/netwatch-agent /etc/default/netwatch-netprobe; do
  [[ -f "$LIVE" ]] || continue
  CHECKED=$((CHECKED + 1))

  REF=""
  if ! REF=$(find_reference "$LIVE"); then
    continue
  fi

  # Keys present in the reference but not in the live config
  MISSING=()
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    MISSING+=("$key")
  done < <(/usr/bin/comm -13 \
    <(config_keys "$LIVE") \
    <(config_keys "$REF"))

  if (( ${#MISSING[@]} == 0 )); then
    log_info "$(basename "$LIVE"): up to date"
    continue
  fi

  echo
  echo -e "${BOLD}$(basename "$LIVE")${NC} is missing ${#MISSING[@]} setting(s):"
  for key in "${MISSING[@]}"; do
    echo "  $key"
  done
  echo "  reference: $REF"

  if (( ! APPLY )); then
    CHANGED=1
    continue
  fi

  if [[ $EUID -ne 0 ]]; then
    log_error "--apply must be run as root"
    exit 1
  fi

  BACKUP="${LIVE}.$(/usr/bin/date +%Y%m%d-%H%M%S).bak"
  /bin/cp "$LIVE" "$BACKUP"
  log_info "Backed up to $BACKUP"

  {
    echo
    echo "#"
    echo "# Added by netwatch-config-merge.sh on $(/usr/bin/date -Is)"
    echo "# New settings from the packaged config. Existing values above were"
    echo "# not modified."
    echo "#"
    for key in "${MISSING[@]}"; do
      echo
      BLOCK=$(extract_key_block "$REF" "$key")
      if [[ -n "$BLOCK" ]]; then
        echo "$BLOCK"
      else
        # Should not happen, but never silently drop a key
        /bin/grep -E "^[[:space:]]*${key}=" "$REF" | /usr/bin/head -1
      fi
    done
  } >> "$LIVE"

  /bin/chmod 0640 "$LIVE" 2>/dev/null || true
  log_info "Appended ${#MISSING[@]} setting(s) to $LIVE"
  CHANGED=1
done

if (( CHECKED == 0 )); then
  log_warn "No Netwatch config files found under /etc/default"
  exit 0
fi

echo

if (( APPLY )); then
  if (( CHANGED )); then
    log_info "Review the additions, then restart:"
    echo "    systemctl restart netwatch-agent"
    echo "    systemctl start netwatch-digest.service   # to test the digest"
  else
    log_info "Nothing to do - all configs are current"
  fi
elif (( CHANGED )); then
  log_warn "Run with --apply to append the missing settings"
  echo "    sudo netwatch-config-merge.sh --apply"
else
  log_info "All configs are current"
fi
