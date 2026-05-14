#!/bin/bash
DOCKERWAF_UID=$(id -u dockerwaf 2>/dev/null)
SOCK="/run/user/${DOCKERWAF_UID}/docker.sock"
LOG="/var/log/keepalived-check.log"
TIMEOUT=3
VIP="10.2.159.20"
IFACE="enp1s0"
LOCAL_IP=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

if [ ! -S "$SOCK" ]; then
    echo "$(date '+%F %T') ERROR: docker socket not found" >> "$LOG"
    exit 1
fi

export DOCKER_HOST="unix://${SOCK}"

# Check 1: Caddy container running?
CADDY_STATE=$(docker inspect --format='{{.State.Running}}' \
    caddy-proxy-manager-caddy 2>/dev/null)
if [ "$CADDY_STATE" != "true" ]; then
    echo "$(date '+%F %T') FAIL: caddy container not running" >> "$LOG"
    exit 1
fi

# Check 2: Caddy port 80 reachable?
# exit 7  = connection refused → Caddy dead
# exit 28 = timeout → dead/firewall
# exit 52 = empty reply → alive (no config)
# exit 56 = connection reset → alive (no matching host)
curl -s --max-time "$TIMEOUT" "http://${LOCAL_IP}" > /dev/null 2>&1
CURL_EXIT=$?
if [ "$CURL_EXIT" = "7" ] || [ "$CURL_EXIT" = "28" ]; then
    echo "$(date '+%F %T') FAIL: Caddy not responding (curl exit $CURL_EXIT)" >> "$LOG"
    exit 1
fi

# Check 3: Web UI — chỉ khi MASTER
IS_MASTER=$(ip addr show "$IFACE" 2>/dev/null | grep -c "$VIP" || true)
if [ "$IS_MASTER" = "1" ]; then
    WEB_STATE=$(docker inspect --format='{{.State.Running}}' \
        caddy-proxy-manager-web 2>/dev/null)
    if [ "$WEB_STATE" != "true" ]; then
        echo "$(date '+%F %T') FAIL [MASTER]: web container not running" >> "$LOG"
        exit 1
    fi

    WEB_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time "$TIMEOUT" "http://${LOCAL_IP}:3000/api/health" 2>/dev/null)
    if [ "$WEB_CODE" != "200" ]; then
        echo "$(date '+%F %T') FAIL [MASTER]: web UI returned $WEB_CODE" >> "$LOG"
        exit 1
    fi
fi

exit 0