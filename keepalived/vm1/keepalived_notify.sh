#!/bin/bash
# ====================================================
# Keepalived notify script — VM1 (nginxlove1 - 10.2.159.18)
# PEER = VM2 (10.2.159.19)
#
# Được gọi bởi Keepalived khi state thay đổi:
#   MASTER  → node này đang giữ VIP
#   BACKUP  → node kia đang giữ VIP
#   FAULT   → health check fail liên tục
#
# Đồng bộ config được xử lý tự động bởi cơ chế INSTANCE_SYNC
# của Web UI (INSTANCE_MODE=master, INSTANCE_SYNC_INTERVAL).
# Script này chỉ cần reload Caddy khi trở thành MASTER.
# ====================================================

STATE="$1"
HOSTNAME=$(hostname)
TIMESTAMP=$(date '+%F %T')
LOG="/var/log/keepalived-state.log"

DOCKERWAF_UID=$(id -u dockerwaf 2>/dev/null)
export DOCKER_HOST="unix:///run/user/${DOCKERWAF_UID}/docker.sock"

log() {
    echo "${TIMESTAMP} [${HOSTNAME}] $*" >> "$LOG"
}

log "===== Transitioning to ${STATE} ====="

case "$STATE" in

    MASTER)
        log "VIP is now on THIS node — becoming MASTER"

        # Reload Caddy để áp dụng config mới nhất từ DB
        # Config đã được đồng bộ liên tục qua REST API (INSTANCE_SYNC_INTERVAL)
        log "Reloading Caddy config..."
        docker exec caddy-proxy-manager-caddy \
            wget -qO- --post-data='' http://localhost:2019/load >> "$LOG" 2>&1 || true

        log "MASTER transition complete"
        ;;

    BACKUP)
        log "VIP moved AWAY — becoming BACKUP"
        log "Caddy WAF tiếp tục phục vụ traffic, Web UI vẫn chạy ở chế độ slave"
        log "BACKUP transition complete"
        ;;

    FAULT)
        log "FAULT state — health check failed repeatedly"
        log "FAULT transition complete"
        ;;

    *)
        log "Unknown state: ${STATE}"
        ;;
esac
