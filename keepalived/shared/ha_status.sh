#!/bin/bash
# ====================================================
# HA Status — hiển thị trạng thái tổng hợp 2 node
# Chạy: ha_status.sh
# ====================================================

DOCKERWAF_UID=$(id -u dockerwaf 2>/dev/null)
export DOCKER_HOST="unix:///run/user/${DOCKERWAF_UID}/docker.sock"
VIP="10.2.159.20"
IFACE="enp1s0"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓ $*${NC}"; }
fail() { echo -e "  ${RED}✗ $*${NC}"; }
warn() { echo -e "  ${YELLOW}! $*${NC}"; }
info() { echo -e "  ${CYAN}→ $*${NC}"; }

echo ""
echo "=========================================="
echo "  HA Status — $(hostname) — $(date '+%F %T')"
echo "=========================================="

# 1. Keepalived state
echo -e "\n${CYAN}--- Keepalived ---${NC}"
if systemctl is-active --quiet keepalived; then
    ok "keepalived is running"
else
    fail "keepalived is NOT running"
fi

if ip addr show "$IFACE" 2>/dev/null | grep -q "$VIP"; then
    ok "Role: MASTER — VIP ${VIP} is on THIS node"
    ROLE="MASTER"
else
    info "Role: BACKUP — VIP is on other node"
    ROLE="BACKUP"
fi

# 2. Docker containers
echo -e "\n${CYAN}--- Docker Containers ---${NC}"
CONTAINERS=(
    "caddy-proxy-manager-caddy"
    "caddy-proxy-manager-web"
    "caddy-proxy-manager-docker-proxy"
    "caddy-proxy-manager-l4-ports"
    "caddy-proxy-manager-clickhouse"
)

for C in "${CONTAINERS[@]}"; do
    STATUS=$(docker inspect --format='{{.State.Status}}' "$C" 2>/dev/null)
    if [ -z "$STATUS" ]; then
        warn "$C: not found"
    elif [ "$STATUS" = "running" ]; then
        ok "$C: running"
    elif [ "$C" = "caddy-proxy-manager-web" ] && [ "$ROLE" = "BACKUP" ]; then
        info "$C: stopped (expected on BACKUP node)"
    elif [ "$C" = "caddy-proxy-manager-clickhouse" ]; then
        info "$C: $STATUS (optional)"
    else
        fail "$C: $STATUS"
    fi
done

# 3. HTTP health checks
echo -e "\n${CYAN}--- HTTP Health ---${NC}"
CADDY_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://localhost 2>/dev/null)
if [ "$CADDY_CODE" != "000" ]; then
    ok "Caddy port 80: HTTP $CADDY_CODE"
else
    fail "Caddy port 80: no response"
fi

if [ "$ROLE" = "MASTER" ]; then
    WEB_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
        http://localhost:3000/api/health 2>/dev/null)
    if [ "$WEB_CODE" = "200" ]; then
        ok "Web UI port 3000: HTTP $WEB_CODE"
    else
        fail "Web UI port 3000: HTTP $WEB_CODE"
    fi
else
    info "Web UI: not checked (BACKUP)"
fi

# 4. IPs
echo -e "\n${CYAN}--- IP Addresses ---${NC}"
ip -4 addr show "$IFACE" | grep inet | while read -r LINE; do
    info "$LINE"
done

# 5. Sync log (5 dòng gần nhất)
echo -e "\n${CYAN}--- Last Sync Events ---${NC}"
if [ -f /var/log/keepalived-sync.log ]; then
    tail -5 /var/log/keepalived-sync.log | while read -r LINE; do
        info "$LINE"
    done
else
    warn "No sync log yet (/var/log/keepalived-sync.log)"
fi

# 6. State change log (5 dòng gần nhất)
echo -e "\n${CYAN}--- Last State Changes ---${NC}"
if [ -f /var/log/keepalived-state.log ]; then
    tail -5 /var/log/keepalived-state.log | while read -r LINE; do
        info "$LINE"
    done
else
    warn "No state log yet (/var/log/keepalived-state.log)"
fi

echo -e "\n=========================================="
echo ""
