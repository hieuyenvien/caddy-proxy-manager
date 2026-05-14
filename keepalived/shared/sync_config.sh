#!/bin/bash
# ====================================================
# Kích hoạt đồng bộ cấu hình qua REST API của master
# Gọi thủ công khi cần push ngay, không đợi INSTANCE_SYNC_INTERVAL
#
# Cách dùng:
#   sync_config.sh
# ====================================================

ENV_FILE="/home/dockerwaf/caddy-proxy-manager/.env"
LOG="/var/log/keepalived-sync.log"
TIMESTAMP=$(date '+%F %T')

# Load .env
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE" 2>/dev/null
    set +a
fi

SYNC_TOKEN="${INSTANCE_SYNC_TOKEN:-}"
INSTANCE_MODE="${INSTANCE_MODE:-standalone}"

if [ "$INSTANCE_MODE" != "master" ]; then
    echo "${TIMESTAMP} [sync] Node này không phải master (mode=${INSTANCE_MODE}), bỏ qua" >> "$LOG"
    exit 0
fi

if [ -z "$SYNC_TOKEN" ]; then
    echo "${TIMESTAMP} [sync] ERROR: INSTANCE_SYNC_TOKEN chưa cấu hình trong .env" >> "$LOG"
    exit 1
fi

echo "${TIMESTAMP} [sync] Triggering REST API sync master → slaves..." >> "$LOG"

HTTP_CODE=$(curl -s -o /tmp/sync_resp.txt -w "%{http_code}" \
    -X POST "http://localhost:3000/api/instances/sync" \
    -H "Authorization: Bearer ${SYNC_TOKEN}" \
    --max-time 30 2>/dev/null)

if [ "$HTTP_CODE" = "200" ]; then
    echo "${TIMESTAMP} [sync] Sync OK" >> "$LOG"
else
    echo "${TIMESTAMP} [sync] Sync FAIL (HTTP ${HTTP_CODE}): $(cat /tmp/sync_resp.txt 2>/dev/null)" >> "$LOG"
    exit 1
fi
