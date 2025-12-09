#!/usr/bin/env bash
#
# test-webhook.sh - Test netwatch webhook notifications
#
# Usage: sudo ./scripts/test-webhook.sh
#
# Sends a test notification using your configured webhook settings.
# Useful for verifying URLs, authentication, and message formatting.
#

set -Eeuo pipefail

# Absolute PATH for deterministic binary resolution
PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root (for config file access)"
  echo "Usage: sudo $0"
  exit 1
fi

# Load configuration
CONFIG_FILE="/etc/default/netwatch-agent"
if [[ ! -r "$CONFIG_FILE" ]]; then
  echo "Error: Configuration file not found: $CONFIG_FILE"
  echo "Please install netwatch-agent first using scripts/install.sh"
  exit 1
fi

# Source the config file
# shellcheck disable=SC1090
. "$CONFIG_FILE"

# Apply defaults for webhook variables
: "${WEBHOOK_ENABLED:=0}"
: "${WEBHOOK_URL:=}"
: "${WEBHOOK_METHOD:=POST}"
: "${WEBHOOK_HEADERS:=}"
: "${WEBHOOK_BODY_TEMPLATE:=}"
: "${WEBHOOK_TIMEOUT:=10}"

echo "=== Netwatch Webhook Test ==="
echo ""

# Check if webhooks are enabled
if [[ "$WEBHOOK_ENABLED" != "1" ]]; then
  echo "Error: Webhooks are not enabled in configuration."
  echo "Please edit $CONFIG_FILE and set:"
  echo "  WEBHOOK_ENABLED=1"
  echo "  WEBHOOK_URL=https://your-webhook-url"
  exit 1
fi

# Check if URL is configured
if [[ -z "$WEBHOOK_URL" ]]; then
  echo "Error: WEBHOOK_URL is not configured."
  echo "Please edit $CONFIG_FILE and set:"
  echo "  WEBHOOK_URL=https://your-webhook-url"
  exit 1
fi

# Check if curl is available
if ! command -v /usr/bin/curl >/dev/null 2>&1; then
  echo "Error: curl not found. Please install it:"
  echo "  apt install curl"
  exit 1
fi

echo "Configuration:"
echo "  URL: $WEBHOOK_URL"
echo "  Method: $WEBHOOK_METHOD"
echo "  Timeout: ${WEBHOOK_TIMEOUT}s"
if [[ -n "$WEBHOOK_HEADERS" ]]; then
  echo "  Custom headers: Yes"
else
  echo "  Custom headers: None"
fi
if [[ -n "$WEBHOOK_BODY_TEMPLATE" ]]; then
  echo "  Custom template: Yes"
else
  echo "  Custom template: No (using default JSON)"
fi
echo ""

# Get system info for template variables
hostname=$(/usr/bin/hostname 2>/dev/null || echo "test-host")
timestamp=$(/usr/bin/date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown")
uptime_seconds=$(/usr/bin/cut -d. -f1 /proc/uptime 2>/dev/null || echo "0")

# Build the test message body
event="test"
message="Test notification from netwatch-agent webhook test script"
duration=0

if [[ -n "$WEBHOOK_BODY_TEMPLATE" ]]; then
  # Use custom template with variable substitution
  body="$WEBHOOK_BODY_TEMPLATE"
  body="${body//\{EVENT\}/$event}"
  body="${body//\{MESSAGE\}/$message}"
  body="${body//\{HOSTNAME\}/$hostname}"
  body="${body//\{TIMESTAMP\}/$timestamp}"
  body="${body//\{DURATION\}/$duration}"
  body="${body//\{TARGETS\}/1.1.1.1 8.8.8.8 9.9.9.9}"
  body="${body//\{DOWN_WINDOW\}/600}"
  body="${body//\{UPTIME\}/$uptime_seconds}"
  body="${body//\{TOTAL_REBOOTS\}/0}"
  body="${body//\{TOTAL_OUTAGES\}/0}"
  body="${body//\{TOTAL_RECOVERIES\}/0}"
  body="${body//\{TOTAL_DOWNTIME\}/0}"
  body="${body//\{SERVICE_RUNTIME\}/0}"
else
  # Default JSON format
  body="{\"event\":\"$event\",\"message\":\"$message\",\"hostname\":\"$hostname\",\"timestamp\":\"$timestamp\",\"duration\":$duration,\"targets\":\"1.1.1.1 8.8.8.8 9.9.9.9\"}"
fi

echo "Payload preview:"
echo "$body" | head -c 200
if [[ ${#body} -gt 200 ]]; then
  echo "... (truncated)"
fi
echo ""
echo ""

# Build curl command
curl_args=(
  -X "$WEBHOOK_METHOD"
  -m "$WEBHOOK_TIMEOUT"
  -w "\nHTTP Status: %{http_code}\n"
  -v
)

# Add custom headers if specified (semicolon-separated)
if [[ -n "$WEBHOOK_HEADERS" ]]; then
  IFS=';'
  for header in $WEBHOOK_HEADERS; do
    curl_args+=(-H "$header")
  done
  IFS=$' \t\n'  # Reset IFS
fi

# Add default Content-Type if not specified and body is JSON-like
if [[ -z "$WEBHOOK_HEADERS" ]] || [[ ! "$WEBHOOK_HEADERS" == *"Content-Type"* ]]; then
  if [[ "$body" == "{"* ]] || [[ -z "$WEBHOOK_BODY_TEMPLATE" ]]; then
    curl_args+=(-H "Content-Type: application/json")
  fi
fi

# Add body data
curl_args+=(-d "$body")

echo "Sending test notification..."
echo "---"
echo ""

# Send webhook
if /usr/bin/curl "${curl_args[@]}" "$WEBHOOK_URL"; then
  echo ""
  echo "---"
  echo ""
  echo "✓ Webhook test completed successfully!"
  echo ""
  echo "Check your notification service to verify the message was received."
  exit 0
else
  exit_code=$?
  echo ""
  echo "---"
  echo ""
  echo "✗ Webhook test failed (curl exit code: $exit_code)"
  echo ""
  echo "Common issues:"
  echo "  - Check the webhook URL is correct"
  echo "  - Verify authentication headers/tokens"
  echo "  - Ensure the service is reachable from this host"
  echo "  - Check firewall/network connectivity"
  exit 1
fi
