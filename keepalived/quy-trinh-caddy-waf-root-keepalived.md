# Quy Trình Triển Khai Keepalived + Docker CRS WAF (2 Node HA)

## Mô hình tổng quan

```
                    Client
                      │
                [VIP: 10.2.159.20]
                      │
          ┌───────────┴───────────┐
          │                       │
   VM1 (MASTER)            VM2 (BACKUP)
   10.2.159.18             10.2.159.19
   ┌──────────┐            ┌──────────┐
   │Keepalived│            │Keepalived│
   │  (pri=100)│           │  (pri=90) │
   ├──────────┤            ├──────────┤
   │ Docker   │            │ Docker   │
   │ nginx +  │            │ nginx +  │
   │ CRS WAF  │            │ CRS WAF  │
   └──────────┘            └──────────┘
```

**Cơ chế hoạt động:**

- Keepalived dùng giao thức VRRP để bầu chọn MASTER
- VIP luôn nằm trên node MASTER
- Health check script kiểm tra Nginx container
- Nếu MASTER fail → VIP tự động chuyển sang BACKUP (< 5 giây)
- Khi MASTER recover → VIP quay lại MASTER

---

## Phần 1: Chuẩn Bị Hạ Tầng

### 1.1 Thông tin các node

| Thành phần | VM1 (nginxlove1) | VM2 (nginxlove2) |
|---|---|---|
| Hostname | nginxlove1 | nginxlove2 |
| IP chính | 10.2.159.18 | 10.2.159.19 |
| Interface | enp1s0 | enp1s0 |
| Role | MASTER (priority 100) | BACKUP (priority 90) |
| VIP | 10.2.159.20 (floating) | 10.2.159.20 (floating) |

### 1.2 Yêu cầu trước khi bắt đầu

Thực hiện trên **cả 2 VM**:

```bash
# 1. Cập nhật hệ thống
apt update && apt upgrade -y

# 2. Kiểm tra Docker đã cài
docker --version
docker compose version

# 3. Kiểm tra kết nối giữa 2 VM
# Từ VM1
ping -c 3 10.2.159.19
# Từ VM2
ping -c 3 10.2.159.18

# 4. Đồng bộ hostname (thêm vào /etc/hosts trên cả 2 VM)
cat >> /etc/hosts << EOF
10.2.159.18 nginxlove1
10.2.159.19 nginxlove2
EOF
```

### 1.3 Xóa VIP cũ trên loopback (nếu có)

```bash
# Kiểm tra VIP trên loopback
ip addr show lo | grep 10.2.159.20

# Nếu có, xóa bỏ
ip addr del 10.2.159.20/32 dev lo

# Tìm và xóa config persistent
# Kiểm tra trong netplan
grep -r "10.2.159.20" /etc/netplan/
# Hoặc trong interfaces
grep -r "10.2.159.20" /etc/network/

# Nếu tìm thấy, comment hoặc xóa dòng đó rồi apply
netplan apply
# hoặc
systemctl restart networking
```

---

## Phần 2: Triển Khai Docker CRS WAF

### 2.1 Tạo thư mục project

Trên **cả 2 VM**:

```bash
mkdir -p /opt/nginx-crs-waf/{conf,logs,modsec}
cd /opt/nginx-crs-waf
```

### 2.2 Tạo file docker-compose.yml

```bash
cat > /opt/nginx-crs-waf/docker-compose.yml << 'EOF'
version: "3.8"

services:
  nginx-crs-waf:
    image: owasp/modsecurity-crs:nginx-alpine
    container_name: nginx-crs-waf
    restart: unless-stopped
    ports:
      - "80:8080"
      - "443:8443"
    environment:
      # === CRS Settings ===
      - PARANOIA=1
      - ANOMALY_INBOUND=5
      - ANOMALY_OUTBOUND=4
      - BLOCKING_PARANOIA=1

      # === Backend / Proxy ===
      - BACKEND=http://your-backend-ip:port
      # Nếu có nhiều backend, dùng nginx upstream config riêng

      # === ModSecurity Engine ===
      - MODSEC_RULE_ENGINE=On
      # DetectionOnly = chỉ log, không block (dùng khi test)
      # On = enforcement mode (block request vi phạm)

      # === Allowed Methods ===
      - ALLOWED_METHODS=GET HEAD POST OPTIONS PUT PATCH DELETE
      - MAX_FILE_SIZE=10485760
      - MAX_NUM_ARGS=255

      # === Logging ===
      - MODSEC_AUDIT_LOG=/var/log/modsecurity/audit.log
      - MODSEC_AUDIT_ENGINE=RelevantOnly

    volumes:
      # Custom nginx config (optional)
      - ./conf/nginx-custom.conf:/etc/nginx/conf.d/custom.conf:ro
      # Logs
      - ./logs:/var/log/nginx
      # Custom ModSecurity rules (optional)
      - ./modsec/custom-rules.conf:/etc/modsecurity.d/owasp-crs/rules/CUSTOM-RULES.conf:ro

    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8080/healthz"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 30s

    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
EOF
```

### 2.3 Tạo custom rules (optional)

```bash
cat > /opt/nginx-crs-waf/modsec/custom-rules.conf << 'EOF'
# === Whitelist specific IP ===
SecRule REMOTE_ADDR "@ipMatch 10.0.0.0/8" \
    "id:10001,phase:1,pass,nolog,ctl:ruleEngine=Off"

# === Whitelist specific URL path ===
SecRule REQUEST_URI "@beginsWith /api/health" \
    "id:10002,phase:1,pass,nolog,ctl:ruleEngine=Off"

# === Custom block rule example ===
# SecRule REQUEST_URI "@contains /admin" \
#     "id:10003,phase:1,deny,status:403,log,msg:'Admin access blocked'"
EOF
```

### 2.4 Tạo nginx custom config (optional)

```bash
cat > /opt/nginx-crs-waf/conf/nginx-custom.conf << 'EOF'
# Health check endpoint cho Keepalived
server {
    listen 8080;
    server_name _;

    location /healthz {
        access_log off;
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }
}
EOF
```

> **Lưu ý:** Tùy image CRS WAF bạn đang dùng, config có thể khác.
> Điều chỉnh port, volume mount, env cho phù hợp với setup hiện tại.

### 2.5 Khởi động container

Trên **cả 2 VM**:

```bash
cd /opt/nginx-crs-waf
docker compose up -d

# Verify
docker ps
docker logs nginx-crs-waf --tail 20

# Test health
curl -s http://localhost/healthz
curl -s -o /dev/null -w "%{http_code}" http://localhost
```

### 2.6 Kiểm tra CRS WAF hoạt động

```bash
# Test 1: Request bình thường → 200
curl -I http://localhost

# Test 2: SQL injection test → 403 (nếu MODSEC_RULE_ENGINE=On)
curl "http://localhost/?id=1%20OR%201=1"

# Test 3: XSS test → 403
curl "http://localhost/?q=<script>alert(1)</script>"

# Xem audit log
docker exec nginx-crs-waf tail -20 /var/log/modsecurity/audit.log
```

---

## Phần 3: Cài Đặt Keepalived

### 3.1 Cài đặt

Trên **cả 2 VM**:

```bash
apt install keepalived -y
```

### 3.2 Tạo health check script

Trên **cả 2 VM**:

```bash
cat > /usr/local/bin/check_nginx_crs.sh << 'SCRIPT'
#!/bin/bash
# ====================================================
# Health check script cho Nginx CRS WAF container
# Keepalived gọi script này mỗi N giây
# Exit 0 = healthy, Exit 1 = unhealthy
# ====================================================

CONTAINER_NAME="nginx-crs-waf"
CHECK_URL="http://localhost/healthz"
TIMEOUT=3
LOG="/var/log/keepalived-check.log"

# --- Check 1: Container đang running? ---
if ! docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q "true"; then
    echo "$(date '+%F %T') FAIL: Container $CONTAINER_NAME not running" >> "$LOG"
    exit 1
fi

# --- Check 2: Nginx respond HTTP 200? ---
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "$CHECK_URL" 2>/dev/null)

if [ "$HTTP_CODE" != "200" ]; then
    echo "$(date '+%F %T') FAIL: HTTP check returned $HTTP_CODE" >> "$LOG"
    exit 1
fi

# --- All good ---
exit 0
SCRIPT

chmod +x /usr/local/bin/check_nginx_crs.sh

# Test thử
/usr/local/bin/check_nginx_crs.sh && echo "HEALTHY" || echo "UNHEALTHY"
```

### 3.3 Config Keepalived — VM1 (MASTER)

```bash
cat > /etc/keepalived/keepalived.conf << 'EOF'
# ============================================
# Keepalived config — VM1 MASTER
# ============================================

global_defs {
    router_id NGINX_CRS_VM1
    script_user root
    enable_script_security

    # Gửi notification (optional)
    # notification_email {
    #     admin@example.com
    # }
    # notification_email_from keepalived@nginxlove1
    # smtp_server 127.0.0.1
    # smtp_connect_timeout 30
}

# Health check script
vrrp_script chk_nginx_crs {
    script "/usr/local/bin/check_nginx_crs.sh"
    interval 3          # Check mỗi 3 giây
    weight -20          # Giảm priority 20 nếu fail
    fall 3              # Fail 3 lần liên tiếp mới tính
    rise 2              # Recover 2 lần liên tiếp mới tính healthy
}

vrrp_instance VI_NGINX_CRS {
    state MASTER
    interface enp1s0
    virtual_router_id 51       # Phải giống nhau trên cả 2 node (1-255)
    priority 100               # MASTER cao hơn BACKUP

    advert_int 1               # Gửi VRRP advertisement mỗi 1 giây

    # Authentication giữa 2 node
    authentication {
        auth_type PASS
        auth_pass Nginx@CRS2024    # Đổi password phù hợp
    }

    # Dùng unicast nếu môi trường không hỗ trợ multicast
    unicast_src_ip 10.2.159.18     # IP của chính VM này
    unicast_peer {
        10.2.159.19                # IP của VM kia
    }

    # VIP
    virtual_ipaddress {
        10.2.159.20/32 dev enp1s0 label enp1s0:vip
    }

    # Gắn health check
    track_script {
        chk_nginx_crs
    }

    # Script chạy khi chuyển trạng thái (optional nhưng rất hữu ích)
    notify_master "/usr/local/bin/keepalived_notify.sh MASTER"
    notify_backup "/usr/local/bin/keepalived_notify.sh BACKUP"
    notify_fault  "/usr/local/bin/keepalived_notify.sh FAULT"
}
EOF
```

### 3.4 Config Keepalived — VM2 (BACKUP)

```bash
cat > /etc/keepalived/keepalived.conf << 'EOF'
# ============================================
# Keepalived config — VM2 BACKUP
# ============================================

global_defs {
    router_id NGINX_CRS_VM2
    script_user root
    enable_script_security
}

vrrp_script chk_nginx_crs {
    script "/usr/local/bin/check_nginx_crs.sh"
    interval 3
    weight -20
    fall 3
    rise 2
}

vrrp_instance VI_NGINX_CRS {
    state BACKUP
    interface enp1s0
    virtual_router_id 51          # Giống MASTER
    priority 90                   # Thấp hơn MASTER

    advert_int 1

    authentication {
        auth_type PASS
        auth_pass Nginx@CRS2024   # Giống MASTER
    }

    unicast_src_ip 10.2.159.19    # IP của chính VM này
    unicast_peer {
        10.2.159.18               # IP của VM kia
    }

    virtual_ipaddress {
        10.2.159.20/32 dev enp1s0 label enp1s0:vip
    }

    track_script {
        chk_nginx_crs
    }

    notify_master "/usr/local/bin/keepalived_notify.sh MASTER"
    notify_backup "/usr/local/bin/keepalived_notify.sh BACKUP"
    notify_fault  "/usr/local/bin/keepalived_notify.sh FAULT"
}
EOF
```

### 3.5 Tạo notify script (optional, recommended)

Trên **cả 2 VM**:

```bash
cat > /usr/local/bin/keepalived_notify.sh << 'SCRIPT'
#!/bin/bash
# ====================================================
# Keepalived state change notification
# Ghi log + có thể gửi alert
# ====================================================

STATE=$1
TIMESTAMP=$(date '+%F %T')
HOSTNAME=$(hostname)
LOG="/var/log/keepalived-state.log"

echo "$TIMESTAMP [$HOSTNAME] Transitioning to $STATE" >> "$LOG"

case $STATE in
    MASTER)
        echo "$TIMESTAMP [$HOSTNAME] VIP is now on THIS node" >> "$LOG"
        # Có thể gửi webhook/telegram alert ở đây
        # curl -s -X POST "https://hooks.slack.com/..." -d "{\"text\":\"$HOSTNAME is now MASTER\"}"
        ;;
    BACKUP)
        echo "$TIMESTAMP [$HOSTNAME] VIP moved AWAY from this node" >> "$LOG"
        ;;
    FAULT)
        echo "$TIMESTAMP [$HOSTNAME] Keepalived entered FAULT state!" >> "$LOG"
        ;;
esac
SCRIPT

chmod +x /usr/local/bin/keepalived_notify.sh
```

### 3.6 Cấu hình Firewall

Trên **cả 2 VM**:

```bash
# Cho phép VRRP protocol (protocol number 112)
iptables -I INPUT -p vrrp -j ACCEPT

# Cho phép traffic đến VIP
iptables -I INPUT -d 10.2.159.20 -j ACCEPT

# Lưu rule persistent
apt install iptables-persistent -y
netfilter-persistent save

# Nếu dùng UFW
ufw allow proto vrrp from 10.2.159.18
ufw allow proto vrrp from 10.2.159.19
```

### 3.7 Khởi động Keepalived

Trên **cả 2 VM**:

```bash
# Enable và start
systemctl enable keepalived
systemctl start keepalived

# Xem trạng thái
systemctl status keepalived
```

---

## Phần 4: Kiểm Tra Và Test

### 4.1 Verify VIP

```bash
# Trên VM1 (MASTER) — phải thấy VIP
ip addr show enp1s0 | grep 10.2.159.20
# Output mong đợi: inet 10.2.159.20/32 scope global enp1s0:vip

# Trên VM2 (BACKUP) — KHÔNG thấy VIP
ip addr show enp1s0 | grep 10.2.159.20
# Output mong đợi: (trống)
```

### 4.2 Test truy cập qua VIP

```bash
# Từ một máy khác trong cùng mạng
curl -I http://10.2.159.20
curl -kI https://10.2.159.20

# Test CRS WAF qua VIP
curl "http://10.2.159.20/?id=1%20OR%201=1"
# Mong đợi: 403 Forbidden
```

### 4.3 Test Failover

#### Kịch bản 1: Stop container trên MASTER

```bash
# === Trên VM1 (MASTER) ===
docker stop nginx-crs-waf

# Đợi ~10 giây (interval=3 x fall=3 = 9s)

# === Trên VM2 (BACKUP) === kiểm tra VIP đã chuyển chưa
ip addr show enp1s0 | grep 10.2.159.20
# Phải thấy VIP ở đây

# === Từ client === test truy cập
curl -I http://10.2.159.20
# Phải vẫn respond OK

# === Recovery: start lại container trên VM1 ===
docker start nginx-crs-waf

# Đợi ~6 giây (interval=3 x rise=2 = 6s)
# VIP sẽ quay lại VM1 (vì priority cao hơn)

# === Trên VM1 === verify
ip addr show enp1s0 | grep 10.2.159.20
```

#### Kịch bản 2: Stop keepalived trên MASTER

```bash
# Trên VM1
systemctl stop keepalived

# VIP chuyển sang VM2 ngay lập tức (< 3 giây)

# Verify trên VM2
ip addr show enp1s0 | grep 10.2.159.20

# Recovery
systemctl start keepalived
```

#### Kịch bản 3: Network failure (rút cáp/disable interface)

```bash
# Trên VM1 (giả lập mất mạng)
ip link set enp1s0 down

# VM2 sẽ nhận VIP sau advert_int timeout

# Recovery
ip link set enp1s0 up
systemctl restart keepalived
```

### 4.4 Xem log

```bash
# Keepalived system log
journalctl -u keepalived -f

# Health check log
tail -f /var/log/keepalived-check.log

# State change log
tail -f /var/log/keepalived-state.log

# Nginx access/error log
docker logs nginx-crs-waf -f --tail 50
```

---

## Phần 5: Giám Sát Và Bảo Trì

### 5.1 Script giám sát tổng hợp

Đặt trên **cả 2 VM** tại `/usr/local/bin/ha_status.sh`:

```bash
cat > /usr/local/bin/ha_status.sh << 'SCRIPT'
#!/bin/bash
# ====================================================
# Script kiểm tra trạng thái tổng hợp HA cluster
# ====================================================

echo "=========================================="
echo "  HA Status — $(hostname) — $(date '+%F %T')"
echo "=========================================="

# 1. Keepalived
echo -e "\n--- Keepalived ---"
systemctl is-active keepalived
if ip addr show enp1s0 | grep -q "10.2.159.20"; then
    echo "Role: MASTER (VIP is HERE)"
else
    echo "Role: BACKUP (VIP is on other node)"
fi

# 2. Docker container
echo -e "\n--- Docker Container ---"
docker ps --filter "name=nginx-crs-waf" --format "Name: {{.Names}} | Status: {{.Status}} | Ports: {{.Ports}}"

# 3. Health check
echo -e "\n--- Health Check ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://localhost 2>/dev/null)
echo "HTTP Status: $HTTP_CODE"

# 4. CRS WAF
echo -e "\n--- CRS WAF ---"
docker exec nginx-crs-waf nginx -T 2>/dev/null | grep -i "modsecurity" | head -3
if [ $? -ne 0 ]; then
    echo "WARNING: Cannot query CRS WAF config"
fi

# 5. Network
echo -e "\n--- IP Addresses ---"
ip -4 addr show enp1s0 | grep inet

# 6. Recent state changes
echo -e "\n--- Recent State Changes ---"
tail -5 /var/log/keepalived-state.log 2>/dev/null || echo "No state log yet"

echo -e "\n=========================================="
SCRIPT

chmod +x /usr/local/bin/ha_status.sh
```

Chạy: `ha_status.sh`

### 5.2 Crontab giám sát (optional)

```bash
# Ghi trạng thái mỗi 5 phút
crontab -e
# Thêm dòng:
*/5 * * * * /usr/local/bin/ha_status.sh >> /var/log/ha-status-history.log 2>&1
```

### 5.3 Quy trình bảo trì rolling update

Khi cần update CRS WAF image hoặc config:

```bash
# === BƯỚC 1: Update BACKUP trước (VM2) ===
# Trên VM2:
cd /opt/nginx-crs-waf
docker compose pull
docker compose down
docker compose up -d

# Verify VM2 healthy
curl -s -o /dev/null -w "%{http_code}" http://localhost
# Phải trả về 200

# === BƯỚC 2: Failover VIP sang BACKUP ===
# Trên VM1 (MASTER):
systemctl stop keepalived
# VIP chuyển sang VM2

# Verify traffic qua VIP vẫn OK
# Từ client:
curl -I http://10.2.159.20

# === BƯỚC 3: Update MASTER (VM1) ===
# Trên VM1:
cd /opt/nginx-crs-waf
docker compose pull
docker compose down
docker compose up -d

# Verify healthy
curl -s -o /dev/null -w "%{http_code}" http://localhost

# === BƯỚC 4: Restore Keepalived trên VM1 ===
systemctl start keepalived
# VIP sẽ quay lại VM1 (priority cao hơn)

# === BƯỚC 5: Verify toàn bộ ===
# Trên VM1:
ha_status.sh
# Trên VM2:
ha_status.sh
```

---

## Phần 6: Xử Lý Sự Cố

### 6.1 VIP không floating

```bash
# Check 1: Keepalived có running không?
systemctl status keepalived
journalctl -u keepalived --no-pager -n 50

# Check 2: VRRP có bị block không?
tcpdump -i enp1s0 -n vrrp -c 10

# Check 3: Firewall
iptables -L -n | grep -i vrrp

# Check 4: virtual_router_id có trùng với service khác không?
# Đổi virtual_router_id sang giá trị khác (1-255) trên CẢ 2 node
```

### 6.2 Split-brain (cả 2 node đều là MASTER)

```bash
# Nguyên nhân: 2 node không giao tiếp VRRP được

# Fix 1: Kiểm tra network giữa 2 node
ping -c 3 10.2.159.18   # từ VM2
ping -c 3 10.2.159.19   # từ VM1

# Fix 2: Kiểm tra unicast config đúng IP chưa

# Fix 3: Nếu dùng multicast, chuyển sang unicast
# (thêm unicast_src_ip và unicast_peer vào config)

# Emergency: Force 1 node về BACKUP
# Trên node cần force về BACKUP:
systemctl stop keepalived
# Sửa priority thấp hơn rồi start lại
```

### 6.3 Container crash loop

```bash
# Xem log container
docker logs nginx-crs-waf --tail 100

# Kiểm tra resource
docker stats nginx-crs-waf --no-stream

# Restart container
docker compose -f /opt/nginx-crs-waf/docker-compose.yml restart

# Nếu vẫn fail → tạm set DetectionOnly
# Sửa docker-compose.yml: MODSEC_RULE_ENGINE=DetectionOnly
docker compose up -d
```

---

## Checklist Tổng Hợp

### Trước khi go-live

- [ ] Docker CRS WAF chạy OK trên cả 2 VM
- [ ] CRS WAF detect/block được request độc hại
- [ ] Keepalived chạy trên cả 2 VM
- [ ] VIP nằm trên MASTER
- [ ] Truy cập qua VIP thành công
- [ ] Test failover: stop container → VIP chuyển node
- [ ] Test failover: stop keepalived → VIP chuyển node
- [ ] Test recovery: start lại service → VIP quay về
- [ ] Health check script hoạt động đúng
- [ ] Firewall cho phép VRRP
- [ ] Log ghi nhận đúng state change
- [ ] Config đồng bộ giữa 2 VM (trừ IP và priority)
- [ ] Backup config đã lưu

### Config files cần backup

```
/opt/nginx-crs-waf/docker-compose.yml
/opt/nginx-crs-waf/conf/*
/opt/nginx-crs-waf/modsec/*
/etc/keepalived/keepalived.conf
/usr/local/bin/check_nginx_crs.sh
/usr/local/bin/keepalived_notify.sh
/usr/local/bin/ha_status.sh
```
