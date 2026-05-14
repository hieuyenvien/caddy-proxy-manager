#!/bin/bash
# ====================================================
# Setup HA Caddy WAF — chạy với root trên từng VM
#
# Cách dùng:
#   Trên VM1: bash setup_ha.sh vm1
#   Trên VM2: bash setup_ha.sh vm2
#
# Script sẽ:
#   1. Cài các file script vào /usr/local/bin/
#   2. Cài keepalived.conf
#   3. Cấu hình firewall
#   4. Start keepalived
# ====================================================

set -euo pipefail

NODE="${1:-}"
if [ "$NODE" != "vm1" ] && [ "$NODE" != "vm2" ]; then
    echo "Usage: $0 {vm1|vm2}"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: phải chạy với root"
    exit 1
fi

if ! id dockerwaf &>/dev/null; then
    echo "ERROR: user dockerwaf chưa tồn tại — chạy phần 2 trong quy trình trước"
    exit 1
fi

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== [1/4] Cài shared scripts ==="
install -m 755 "${SCRIPTS_DIR}/shared/check_caddy_waf.sh"  /usr/local/bin/check_caddy_waf.sh
install -m 755 "${SCRIPTS_DIR}/shared/sync_config.sh"      /usr/local/bin/sync_config.sh
install -m 755 "${SCRIPTS_DIR}/shared/ha_status.sh"        /usr/local/bin/ha_status.sh

echo "=== [2/4] Cài notify script cho ${NODE} ==="
install -m 755 "${SCRIPTS_DIR}/${NODE}/keepalived_notify.sh" /usr/local/bin/keepalived_notify.sh

echo "=== [3/4] Cài keepalived.conf cho ${NODE} ==="
apt install -y keepalived > /dev/null 2>&1
mkdir -p /etc/keepalived
cp "${SCRIPTS_DIR}/${NODE}/keepalived.conf" /etc/keepalived/keepalived.conf

echo "=== [4/4] Cấu hình firewall ==="
# VRRP protocol (112)
iptables -C INPUT -p vrrp -j ACCEPT 2>/dev/null || iptables -I INPUT -p vrrp -j ACCEPT
# Traffic đến VIP
iptables -C INPUT -d 10.2.159.20 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -d 10.2.159.20 -j ACCEPT
# Lưu persistent
if ! dpkg -l | grep -q iptables-persistent; then
    DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent > /dev/null 2>&1
fi
netfilter-persistent save > /dev/null 2>&1

echo "=== [5/5] Khởi động Keepalived ==="
systemctl enable keepalived
systemctl restart keepalived
sleep 2
systemctl status keepalived --no-pager -l

echo ""
echo "=== DONE ==="
echo ""
echo "Các bước tiếp theo:"
echo "  1. Cấu hình .env trên từng node (xem shared/.env.example)"
if [ "$NODE" = "vm1" ]; then
    echo "     VM1: INSTANCE_MODE=master, INSTANCE_SLAVES=[\"http://10.2.159.19:3000\"]"
    echo "     VM1: INSTANCE_SYNC_INTERVAL=30, INSTANCE_SYNC_TOKEN=<shared_secret>"
    echo "  2. Chạy script này trên VM2: bash setup_ha.sh vm2"
    echo "  3. Cấu hình .env trên VM2: INSTANCE_MODE=slave, INSTANCE_SYNC_TOKEN=<same_secret>"
else
    echo "     VM2: INSTANCE_MODE=slave, INSTANCE_SYNC_TOKEN=<same_secret_as_vm1>"
fi
echo "  4. Restart stack trên cả 2 node: docker compose up -d"
echo "  5. Kiểm tra trạng thái: ha_status.sh"
echo "  6. Test sync thủ công (từ VM1): sync_config.sh"
