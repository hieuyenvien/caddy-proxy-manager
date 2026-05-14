# Quy Trình Triển Khai Caddy WAF CRS + Rootless Docker + Keepalived HA

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
      ┌────────────┐          ┌────────────┐
      │ Keepalived │          │ Keepalived │
      │ (pri=100)  │          │ (pri=90)   │
      ├────────────┤          ├────────────┤
      │ Rootless   │          │ Rootless   │
      │ Docker     │          │ Docker     │
      │ (dockerwaf)│          │ (dockerwaf)│
      ├────────────┤          ├────────────┤
      │ Caddy +    │          │ Caddy +    │
      │ Coraza WAF │          │ Coraza WAF │
      │ Web UI     │          │ Web UI     │
      │ ClickHouse │          │ ClickHouse │
      └────────────┘          └────────────┘
```

**Cơ chế hoạt động:**

- Caddy Proxy Manager = Caddy reverse proxy + Coraza WAF (CRS-compatible) + Web UI quản trị
- Toàn bộ Docker daemon chạy rootless dưới user `dockerwaf` (không cần root)
- Keepalived dùng VRRP unicast để floating VIP giữa 2 node
- Health check kiểm tra cả Caddy container + Web UI container
- Failover tự động < 10 giây khi MASTER fail

**Thành phần container:**

| Container | Port | Chức năng |
|---|---|---|
| caddy-proxy-manager-caddy | 80, 443 | Reverse proxy + Coraza WAF engine |
| caddy-proxy-manager-web | 3000 | Web UI quản trị |
| caddy-proxy-manager-docker-proxy | 2375 (internal) | Docker socket proxy bảo mật |
| caddy-proxy-manager-l4-ports | — | Tự động update L4 port mapping |
| caddy-proxy-manager-clickhouse | 8123 (internal) | Analytics database |

---

## Thông tin hạ tầng

| Thành phần | VM1 (nginxlove1) | VM2 (nginxlove2) |
|---|---|---|
| Hostname | nginxlove1 | nginxlove2 |
| IP chính | 10.2.159.18 | 10.2.159.19 |
| Interface | enp1s0 | enp1s0 |
| Role | MASTER (priority 100) | BACKUP (priority 90) |
| VIP | 10.2.159.20 (floating) | 10.2.159.20 (floating) |
| OS | Ubuntu 24.04 | Ubuntu 24.04 |
| Docker user | dockerwaf (rootless) | dockerwaf (rootless) |
| Project path | /home/dockerwaf/caddy-proxy-manager | /home/dockerwaf/caddy-proxy-manager |

> **Quan trọng:** Thực hiện trên **từng VM một** (rolling) để không mất service.
> Làm VM2 (BACKUP) trước, test OK, rồi mới làm VM1 (MASTER).

---

## Phần 1: Chuẩn Bị Hệ Thống

Thực hiện trên **cả 2 VM** với **root**.

### 1.1 Cập nhật hệ thống

```bash
apt update && apt upgrade -y
```

### 1.2 Cài đặt Docker Engine (nếu chưa có)

```bash
# Cài Docker Engine
curl -fsSL https://get.docker.com | sh

# Verify
docker --version
docker compose version
```

### 1.3 Cài dependency cho rootless Docker

```bash
apt install -y uidmap dbus-user-session fuse-overlayfs slirp4netns systemd-container
```

### 1.4 Đồng bộ hostname

```bash
cat >> /etc/hosts << EOF
10.2.159.18 nginxlove1
10.2.159.19 nginxlove2
EOF
```

### 1.5 Kiểm tra kết nối giữa 2 VM

```bash
# Từ VM1
ping -c 3 10.2.159.19

# Từ VM2
ping -c 3 10.2.159.18
```

### 1.6 Xóa VIP cũ trên loopback (nếu có)

```bash
ip addr show lo | grep 10.2.159.20

# Nếu có, xóa
ip addr del 10.2.159.20/32 dev lo

# Kiểm tra config persistent
grep -r "10.2.159.20" /etc/netplan/ 2>/dev/null
grep -r "10.2.159.20" /etc/network/ 2>/dev/null
# Nếu tìm thấy → xóa dòng đó → netplan apply
```

---

## Phần 2: Tạo User dockerwaf + Cài Rootless Docker

Thực hiện trên **cả 2 VM** với **root**.

### 2.1 Tạo user

```bash
# Tạo user
useradd -m -s /bin/bash dockerwaf
passwd dockerwaf

# Kiểm tra UID mapping
cat /etc/subuid | grep dockerwaf
cat /etc/subgid | grep dockerwaf

# Nếu chưa có, thêm vào
echo "dockerwaf:100000:65536" >> /etc/subuid
echo "dockerwaf:100000:65536" >> /etc/subgid

# Cho phép service chạy khi user không login
loginctl enable-linger dockerwaf
```

### 2.2 Tạo AppArmor policy (Ubuntu 24.04 yêu cầu)

```bash
cat <<EOT | tee "/etc/apparmor.d/home.dockerwaf.bin.rootlesskit"
abi <abi/4.0>,
include <tunables/global>
/home/dockerwaf/bin/rootlesskit flags=(unconfined) {
  userns,
  include if exists <local/home.dockerwaf.bin.rootlesskit>
}
EOT

systemctl restart apparmor.service

# Verify
aa-status | grep rootlesskit
```

### 2.3 Cho phép bind port thấp (80, 443)

```bash
echo "net.ipv4.ip_unprivileged_port_start=80" >> /etc/sysctl.conf
sysctl -p
```

### 2.4 Cài rootless Docker

**Quan trọng:** Dùng `machinectl` để login (tạo đúng D-Bus session), KHÔNG dùng `su`:

```bash
# Login vào user dockerwaf (từ root)
machinectl shell dockerwaf@

# Verify D-Bus
echo $XDG_RUNTIME_DIR
# Phải trả về: /run/user/<UID>

# Cài rootless Docker
curl -fsSL https://get.docker.com/rootless | sh

# Thêm environment vào .bashrc
cat >> ~/.bashrc << 'EOF'
export PATH=/home/dockerwaf/bin:$PATH
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
EOF

source ~/.bashrc

# Enable Docker rootless tự start khi boot
systemctl --user enable docker
systemctl --user start docker

# Verify
docker --version
docker info | grep -i "root"
# Phải thấy: rootless

docker ps
# Phải trả về danh sách rỗng (chưa có container)
```

> **Lưu ý:** Nếu `machinectl` không dùng được, cài `apt install systemd-container -y`.
> Nếu gặp lỗi "Failed to connect to bus: No medium found" khi dùng `su`, đó là do
> thiếu D-Bus session → phải dùng `machinectl shell dockerwaf@`.

### 2.5 Cài pasta để lấy Real Source IP

Mặc định rootless Docker dùng `slirp4netns` — tất cả traffic vào container đều thấy source IP là `10.0.2.2` (loopback nội bộ), không phải IP thật của client. Cài **pasta** và bật `port-driver=implicit` để fix vấn đề này.

**Bước 1 — Cài pasta** (thực hiện với **root**):

```bash
# Ubuntu/Debian
apt install -y passt

# RHEL/Fedora
# dnf install passt
```

**Bước 2 — Cấu hình rootless Docker dùng pasta** (thực hiện với **user dockerwaf** qua `machinectl shell dockerwaf@`):

```bash
# Bắt buộc set XDG_RUNTIME_DIR trước nếu login qua SSH (tránh lỗi "no medium found")
export XDG_RUNTIME_DIR=/run/user/$(id -u)

# Mở drop-in config cho docker.service
systemctl --user edit docker.service
```

Thêm nội dung sau vào giữa 2 dòng comment do editor tự sinh:

```ini
[Service]
Environment="DOCKERD_ROOTLESS_ROOTLESSKIT_FLAGS=--net=pasta --port-driver=implicit"
```

Lưu lại (Ctrl+O → Enter → Ctrl+X nếu dùng nano, hoặc `:wq` nếu dùng vim), rồi reload:

```bash
systemctl --user daemon-reload
systemctl --user restart docker

# Verify Docker đã restart OK
docker info | grep -i "rootless"
```

**Bước 3 — Khởi động lại stack:**

```bash
cd /home/dockerwaf/caddy-proxy-manager
docker compose down
docker compose up -d

# Verify — container phải healthy
docker ps

# Verify real IP xuất hiện trong log
# Gửi 1 request test, xem log Caddy có IP thật hay không
curl http://localhost
docker logs caddy-proxy-manager-caddy --tail 20
```

> **Lưu ý về lỗi `failed to connect to bus: no medium found`:**
> Lỗi này xảy ra khi session SSH không có D-Bus user session (thường gặp khi dùng `su` hoặc `sudo -u`).
> Fix: luôn set `export XDG_RUNTIME_DIR=/run/user/$(id -u)` trước khi chạy `systemctl --user`, hoặc login bằng `machinectl shell dockerwaf@` để có đầy đủ user session.

---

## Phần 3: Triển Khai Caddy Proxy Manager

Thực hiện trên **cả 2 VM** với **user dockerwaf** (dùng `machinectl shell dockerwaf@`).

### 3.1 Clone project

```bash
cd /home/dockerwaf
git clone https://github.com/fuomag9/caddy-proxy-manager.git
cd caddy-proxy-manager
```

### 3.2 Tạo file .env

```bash
cp .env.example .env
chmod 600 .env
```

### 3.3 Chỉnh sửa .env

```bash
nano .env
```

Các giá trị cần sửa:

```ini
# === BẮT BUỘC ===

# Session secret — generate bằng: openssl rand -base64 32
SESSION_SECRET=<paste_giá_trị_generate_được>

# Admin credentials — password phải 12+ ký tự, có chữ hoa, thường, số, ký tự đặc biệt
ADMIN_USERNAME=admin
ADMIN_PASSWORD=Your-Secure-P@ssw0rd-Here!

# Base URL — khi test dùng IP, sau này đổi sang domain
# KHÔNG dùng https khi chưa có TLS termination
BASE_URL=http://10.2.159.20:3000

# === ANALYTICS (nếu dùng ClickHouse) ===
COMPOSE_PROFILES=clickhouse
CLICKHOUSE_PASSWORD=<paste_giá_trị_generate_được>
```

> **Lưu ý về BASE_URL:**
> - Khi test: `http://10.2.159.18:3000` (IP trực tiếp) hoặc `http://10.2.159.20:3000` (VIP)
> - Khi production có domain: `https://waf.example.com`
> - KHÔNG dùng `https` khi chưa setup TLS → sẽ lỗi login (cookie Secure flag)
> - KHÔNG để trailing slash

### 3.4 Sửa docker-socket-proxy cho rootless Docker

Rootless Docker socket nằm ở `/run/user/<UID>/docker.sock`, không phải `/var/run/docker.sock`.

```bash
# Xem UID của dockerwaf
id -u
# Ví dụ: 1001

# Sửa docker-compose.yml
nano docker-compose.yml
```

Tìm phần `docker-socket-proxy`, đổi volume mount:

```yaml
  docker-socket-proxy:
    ...
    volumes:
      # ĐỔI từ:
      # - /var/run/docker.sock:/var/run/docker.sock:ro
      # THÀNH (thay 1001 bằng UID thực):
      - /run/user/1001/docker.sock:/var/run/docker.sock:ro
```

### 3.5 Tạo thư mục lưu log Caddy ra host

Log access và WAF attack log của container Caddy được bind mount ra host tại `/home/dockerwaf/caddy-logs` (hoặc path tùy chỉnh qua biến `CADDY_LOG_DIR` trong `.env`).

Trong rootless Docker, UID/GID bên trong container được ánh xạ qua user namespace — UID thật trên host sẽ khác với UID trong container. Cần lấy UID/GID thật sau khi container chạy để cấp quyền chính xác.

#### Bước 1: Tạo thư mục (trước khi start stack)

```bash
# Tạo thư mục log (chạy với root)
mkdir -p /home/dockerwaf/caddy-logs
chown dockerwaf:dockerwaf /home/dockerwaf/caddy-logs

# (Optional) Tùy chỉnh path — thêm vào .env
echo "CADDY_LOG_DIR=/home/dockerwaf/caddy-logs" >> /home/dockerwaf/caddy-proxy-manager/.env
```

#### Bước 2: Lấy UID/GID thật sau khi stack đã chạy - Từ bước 2, sẽ thực hiện sau khi pull và chạy container xong để có thể lấy UID/GID thật của container

```bash
# UID thật của caddy container (owner file log)
cat /proc/$(docker inspect --format '{{.State.Pid}}' caddy-proxy-manager-caddy)/status \
    | grep -E "^(Uid|Gid)"
# Ví dụ: Uid: 166536 ... → dùng giá trị cột 2

# Groups thật của web container (group cần đọc log)
cat /proc/$(docker inspect --format '{{.State.Pid}}' caddy-proxy-manager-web)/status \
    | grep Groups
# Ví dụ: Groups: 166534 ... → dùng GID đầu tiên (CADDY_GID trong compose)
```

#### Bước 3: Tạo group và cấp quyền (chạy với root)

Thay `166536` và `166534` bằng giá trị thực lấy ở bước 2.

```bash
# Tạo group với GID của web container
groupdel caddy-logs 2>/dev/null || true
groupadd -g 166534 caddy-logs

# Thêm các user cần đọc log vào group
usermod -aG caddy-logs dockerwaf
usermod -aG caddy-logs syslog

# Cấp ownership: caddy UID làm owner, caddy-logs group làm group
chown -R 166536:caddy-logs /home/dockerwaf/caddy-logs

# setgid (2) — file mới tạo kế thừa group; 750 — owner rwx, group r-x
chmod 2750 /home/dockerwaf/caddy-logs

# Cấp read cho các file log đã có (nếu cần)
find /home/dockerwaf/caddy-logs -name "*.log" -exec chmod g+r {} \;
```

> **Lưu ý:** Sau `usermod`, cần đăng xuất/đăng nhập lại (hoặc `newgrp caddy-logs`) để session của `dockerwaf` nhận group mới.

#### Bước 4: Verify

```bash
# Web container đọc được log
docker exec caddy-proxy-manager-web cat /logs/access.log | head -3

# Host đọc được log trực tiếp
tail -f /home/dockerwaf/caddy-logs/access.log
```

> **Lưu ý:** `caddy-logs` không còn là Docker named volume nữa mà là bind mount trực tiếp ra host.
> Sau khi container chạy, log sẽ xuất hiện tại `/home/dockerwaf/caddy-logs/access.log` (và các file log khác tùy cấu hình Caddy).

### 3.6 Đồng bộ timezone container với host

Các container cần đọc đúng múi giờ host (đặc biệt Caddy để timestamp log chính xác). Cấu hình này đã được tích hợp sẵn trong `docker-compose.yml`:

- **Caddy**: mount timezone files + biến `TZ=Asia/Ho_Chi_Minh` → log access/WAF ghi giờ Việt Nam
- **Web UI** và **ClickHouse**: giữ UTC nội bộ, browser tự convert sang local time khi hiển thị
- **l4-port-manager**: mount timezone files để timestamp log nhất quán với host

Nếu host chưa có file timezone hoặc dùng distro tối giản, cài thêm:

```bash
# Ubuntu/Debian
apt install -y tzdata

# Verify
ls -la /etc/localtime
cat /etc/timezone
# Phải trả về: Asia/Ho_Chi_Minh (hoặc múi giờ tương ứng)

# Nếu chưa đúng, cấu hình lại
timedatectl set-timezone Asia/Ho_Chi_Minh
timedatectl status
```

Verify sau khi stack chạy:

```bash
# Timestamp log Caddy phải theo giờ Việt Nam (UTC+7)
docker exec caddy-proxy-manager-caddy date
# Ví dụ: Sun May 11 08:30:00 +07 2026

# So sánh với host
date
```

### 3.7 Pull images và khởi động

```bash
cd /home/dockerwaf/caddy-proxy-manager

# Pull images
docker compose pull

# Start
docker compose up -d

# Verify — tất cả container phải healthy
docker ps

# Test health
curl -s http://localhost:3000/api/health
# Phải trả về: {"status":"ok"}

curl -s -o /dev/null -w "%{http_code}" http://localhost
# Phải trả về: 200
```

### 3.8 Kiểm tra truy cập

```bash
# Từ VM, test qua IP
curl -I http://10.2.159.18:3000

# Từ máy client (Windows/Mac)
curl -v http://10.2.159.18:3000/api/health
```

> **Nếu trình duyệt báo "Connection timed out" nhưng curl OK:**
> Nguyên nhân là proxy/squid của mạng công ty chặn port 3000.
> Fix: Thêm IP `10.2.159.18` vào bypass proxy list trong trình duyệt.

---

## Phần 4: Cài Đặt Keepalived

Thực hiện trên **cả 2 VM** với **root**.

### 4.1 Cài đặt

```bash
apt install keepalived -y
```

### 4.2 Tạo health check script

Trên **cả 2 VM**:

```bash
cat > /usr/local/bin/check_caddy_waf.sh << 'SCRIPT'
#!/bin/bash
# ====================================================
# Health check cho Caddy Proxy Manager stack
# Keepalived gọi mỗi 3 giây
# Exit 0 = healthy, Exit 1 = unhealthy
# ====================================================

DOCKERWAF_UID=$(id -u dockerwaf)
export DOCKER_HOST="unix:///run/user/${DOCKERWAF_UID}/docker.sock"
LOG="/var/log/keepalived-check.log"
TIMEOUT=3

# Check 1: Caddy container running?
if ! docker inspect --format='{{.State.Running}}' caddy-proxy-manager-caddy 2>/dev/null | grep -q "true"; then
    echo "$(date '+%F %T') FAIL: Caddy container not running" >> "$LOG"
    exit 1
fi

# Check 2: Web container running?
if ! docker inspect --format='{{.State.Running}}' caddy-proxy-manager-web 2>/dev/null | grep -q "true"; then
    echo "$(date '+%F %T') FAIL: Web container not running" >> "$LOG"
    exit 1
fi

# Check 3: Caddy HTTP respond?
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" http://localhost 2>/dev/null)
if [ "$HTTP_CODE" = "000" ]; then
    echo "$(date '+%F %T') FAIL: Caddy no response" >> "$LOG"
    exit 1
fi

# Check 4: Web UI respond?
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" http://localhost:3000/api/health 2>/dev/null)
if [ "$HTTP_CODE" != "200" ]; then
    echo "$(date '+%F %T') FAIL: Web UI returned $HTTP_CODE" >> "$LOG"
    exit 1
fi

exit 0
SCRIPT

chmod +x /usr/local/bin/check_caddy_waf.sh

# Test
/usr/local/bin/check_caddy_waf.sh && echo "HEALTHY" || echo "UNHEALTHY"
```

### 4.3 Config Keepalived — VM1 (MASTER - nginxlove1)

```bash
cat > /etc/keepalived/keepalived.conf << 'EOF'
# ============================================
# Keepalived config — VM1 MASTER
# ============================================

global_defs {
    router_id CADDY_WAF_VM1
    script_user root
    enable_script_security
}

vrrp_script chk_caddy {
    script "/usr/local/bin/check_caddy_waf.sh"
    interval 3          # Check mỗi 3 giây
    weight -20          # Giảm priority 20 nếu fail
    fall 3              # Fail 3 lần liên tiếp mới tính
    rise 2              # Recover 2 lần liên tiếp mới tính healthy
}

vrrp_instance VI_CADDY_WAF {
    state MASTER
    interface enp1s0
    virtual_router_id 52       # 1-255, phải giống trên cả 2 node
    priority 100               # MASTER cao hơn BACKUP

    advert_int 1               # Gửi VRRP advertisement mỗi 1 giây

    authentication {
        auth_type PASS
        auth_pass Caddy@WAF2026    # Đổi password phù hợp, giống 2 node
    }

    # Unicast (dùng khi môi trường không hỗ trợ multicast)
    unicast_src_ip 10.2.159.18     # IP của chính VM này
    unicast_peer {
        10.2.159.19                # IP của VM kia
    }

    virtual_ipaddress {
        10.2.159.20/32 dev enp1s0 label enp1s0:vip
    }

    track_script {
        chk_caddy
    }

    notify_master "/usr/local/bin/keepalived_notify.sh MASTER"
    notify_backup "/usr/local/bin/keepalived_notify.sh BACKUP"
    notify_fault  "/usr/local/bin/keepalived_notify.sh FAULT"
}
EOF
```

### 4.4 Config Keepalived — VM2 (BACKUP - nginxlove2)

```bash
cat > /etc/keepalived/keepalived.conf << 'EOF'
# ============================================
# Keepalived config — VM2 BACKUP
# ============================================

global_defs {
    router_id CADDY_WAF_VM2
    script_user root
    enable_script_security
}

vrrp_script chk_caddy {
    script "/usr/local/bin/check_caddy_waf.sh"
    interval 3
    weight -20
    fall 3
    rise 2
}

vrrp_instance VI_CADDY_WAF {
    state BACKUP
    interface enp1s0
    virtual_router_id 52          # Giống MASTER
    priority 90                   # Thấp hơn MASTER

    advert_int 1

    authentication {
        auth_type PASS
        auth_pass Caddy@WAF2026   # Giống MASTER
    }

    unicast_src_ip 10.2.159.19    # IP của chính VM này
    unicast_peer {
        10.2.159.18               # IP của VM kia
    }

    virtual_ipaddress {
        10.2.159.20/32 dev enp1s0 label enp1s0:vip
    }

    track_script {
        chk_caddy
    }

    notify_master "/usr/local/bin/keepalived_notify.sh MASTER"
    notify_backup "/usr/local/bin/keepalived_notify.sh BACKUP"
    notify_fault  "/usr/local/bin/keepalived_notify.sh FAULT"
}
EOF
```

### 4.5 Tạo notify script

Trên **cả 2 VM**:

```bash
cat > /usr/local/bin/keepalived_notify.sh << 'SCRIPT'
#!/bin/bash
STATE=$1
TIMESTAMP=$(date '+%F %T')
HOSTNAME=$(hostname)
LOG="/var/log/keepalived-state.log"

echo "$TIMESTAMP [$HOSTNAME] Transitioning to $STATE" >> "$LOG"

case $STATE in
    MASTER)
        echo "$TIMESTAMP [$HOSTNAME] VIP is now on THIS node" >> "$LOG"
        # Optional: gửi alert
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

### 4.6 Cấu hình Firewall

Trên **cả 2 VM**:

```bash
# Cho phép VRRP protocol
iptables -I INPUT -p vrrp -j ACCEPT

# Cho phép traffic đến VIP
iptables -I INPUT -d 10.2.159.20 -j ACCEPT

# Lưu persistent
apt install iptables-persistent -y
netfilter-persistent save
```

### 4.7 Khởi động Keepalived

Trên **cả 2 VM**:

```bash
systemctl enable keepalived
systemctl start keepalived

# Xem trạng thái
systemctl status keepalived
```

---

## Phần 5: Kiểm Tra Và Test

### 5.1 Verify VIP

```bash
# Trên VM1 (MASTER) — phải thấy VIP
ip addr show enp1s0 | grep 10.2.159.20
# Output: inet 10.2.159.20/32 scope global enp1s0:vip

# Trên VM2 (BACKUP) — KHÔNG thấy VIP
ip addr show enp1s0 | grep 10.2.159.20
# Output: (trống)
```

### 5.2 Test truy cập qua VIP

```bash
# Caddy reverse proxy
curl -I http://10.2.159.20

# Web UI
curl http://10.2.159.20:3000/api/health

# WAF test — SQL injection
curl "http://10.2.159.20/?id=1%20OR%201=1"
# Mong đợi: 403 Forbidden (nếu WAF đã bật)
```

### 5.3 Test Failover

#### Kịch bản 1: Stop Caddy container trên MASTER

```bash
# Trên VM1 (dưới user dockerwaf)
machinectl shell dockerwaf@
docker stop caddy-proxy-manager-caddy

# Đợi ~10 giây (interval=3 x fall=3 = 9s)

# Trên VM2 — kiểm tra VIP đã chuyển chưa
ip addr show enp1s0 | grep 10.2.159.20
# Phải thấy VIP ở đây

# Từ client — test truy cập
curl -I http://10.2.159.20
# Phải vẫn respond OK

# Recovery: start lại container trên VM1
machinectl shell dockerwaf@
docker start caddy-proxy-manager-caddy

# Đợi ~6 giây (interval=3 x rise=2 = 6s)
# VIP sẽ quay lại VM1 (vì priority cao hơn)
```

#### Kịch bản 2: Stop Keepalived trên MASTER

```bash
# Trên VM1 (root)
systemctl stop keepalived
# VIP chuyển sang VM2 ngay lập tức (< 3 giây)

# Recovery
systemctl start keepalived
```

#### Kịch bản 3: Network failure

```bash
# Trên VM1 (giả lập mất mạng)
ip link set enp1s0 down

# VM2 sẽ nhận VIP sau advert_int timeout

# Recovery
ip link set enp1s0 up
systemctl restart keepalived
```

### 5.4 Xem log

```bash
# Keepalived system log
journalctl -u keepalived -f

# Health check log
tail -f /var/log/keepalived-check.log

# State change log
tail -f /var/log/keepalived-state.log

# Container logs (chạy dưới dockerwaf)
machinectl shell dockerwaf@
docker logs caddy-proxy-manager-web -f --tail 50
docker logs caddy-proxy-manager-caddy -f --tail 50
```

---

## Phần 6: Giám Sát Và Bảo Trì

### 6.1 Script giám sát tổng hợp

Đặt trên **cả 2 VM** tại `/usr/local/bin/ha_status.sh`:

```bash
cat > /usr/local/bin/ha_status.sh << 'SCRIPT'
#!/bin/bash
DOCKERWAF_UID=$(id -u dockerwaf)
export DOCKER_HOST="unix:///run/user/${DOCKERWAF_UID}/docker.sock"

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

# 2. Docker containers
echo -e "\n--- Docker Containers ---"
docker ps --format "{{.Names}}: {{.Status}}" 2>/dev/null | grep caddy-proxy

# 3. Health check
echo -e "\n--- Health Check ---"
CADDY_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://localhost 2>/dev/null)
WEB_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://localhost:3000/api/health 2>/dev/null)
echo "Caddy HTTP: $CADDY_CODE | Web UI: $WEB_CODE"

# 4. IP Addresses
echo -e "\n--- IP Addresses ---"
ip -4 addr show enp1s0 | grep inet

# 5. Recent state changes
echo -e "\n--- Recent State Changes ---"
tail -5 /var/log/keepalived-state.log 2>/dev/null || echo "No state log yet"

echo -e "\n=========================================="
SCRIPT

chmod +x /usr/local/bin/ha_status.sh
```

Chạy: `ha_status.sh`

### 6.2 Crontab giám sát

```bash
crontab -e
# Thêm dòng:
*/5 * * * * /usr/local/bin/ha_status.sh >> /var/log/ha-status-history.log 2>&1
```

### 6.3 Quy trình Rolling Update

Khi cần update Caddy Proxy Manager:

```bash
# === BƯỚC 1: Update BACKUP trước (VM2) ===
# Trên VM2 (machinectl shell dockerwaf@):
cd ~/caddy-proxy-manager
git pull
docker compose pull
docker compose down
docker compose up -d

# Verify healthy
curl -s http://localhost:3000/api/health

# === BƯỚC 2: Failover VIP sang VM2 ===
# Trên VM1 (root):
systemctl stop keepalived

# Verify traffic qua VIP vẫn OK
curl -I http://10.2.159.20

# === BƯỚC 3: Update MASTER (VM1) ===
# Trên VM1 (machinectl shell dockerwaf@):
cd ~/caddy-proxy-manager
git pull
docker compose pull
docker compose down
docker compose up -d

# Verify healthy
curl -s http://localhost:3000/api/health

# === BƯỚC 4: Restore Keepalived ===
# Trên VM1 (root):
systemctl start keepalived
# VIP quay lại VM1

# === BƯỚC 5: Verify ===
ha_status.sh    # Trên cả 2 VM
```

---

## Phần 7: Xử Lý Sự Cố

### 7.1 Login Web UI bị "Invalid origin"

```
ERROR [Better Auth]: Invalid origin: http://localhost:3000
```

**Nguyên nhân:** `BASE_URL` trong `.env` không khớp với URL truy cập.

**Fix:** Sửa `BASE_URL` trong `.env` cho đúng URL đang dùng, rồi restart:

```bash
# Ví dụ truy cập qua http://10.2.159.18:3000
BASE_URL=http://10.2.159.18:3000

docker compose down && docker compose up -d
```

### 7.2 Trình duyệt báo "Connection timed out" nhưng curl OK

**Nguyên nhân:** Proxy/squid của mạng công ty chặn.

**Fix:** Thêm IP vào bypass proxy list trong trình duyệt settings.

### 7.3 Không truy cập được https://IP:3000

**Nguyên nhân:** Container web chỉ serve HTTP, không có TLS.

**Fix:** Dùng `http://` thay vì `https://`. Chỉ dùng HTTPS khi đã setup domain + TLS qua Caddy.

### 7.4 VIP không floating

```bash
# Check 1: Keepalived running?
systemctl status keepalived
journalctl -u keepalived --no-pager -n 50

# Check 2: VRRP bị block?
tcpdump -i enp1s0 -n vrrp -c 10

# Check 3: Firewall
iptables -L -n | grep -i vrrp

# Check 4: virtual_router_id trùng?
# Đổi virtual_router_id sang giá trị khác trên CẢ 2 node
```

### 7.5 Split-brain (cả 2 node đều là MASTER)

```bash
# Kiểm tra network giữa 2 node
ping -c 3 10.2.159.18   # từ VM2
ping -c 3 10.2.159.19   # từ VM1

# Kiểm tra unicast config đúng IP chưa

# Emergency: force 1 node về BACKUP
systemctl stop keepalived
# Sửa priority thấp hơn rồi start lại
```

### 7.6 D-Bus lỗi "No medium found" khi dùng su

**Nguyên nhân:** `su` không tạo D-Bus session.

**Fix:** Dùng `machinectl shell dockerwaf@` thay vì `su - dockerwaf`.

### 7.7 Container restart loop

```bash
# Xem log
machinectl shell dockerwaf@
docker logs caddy-proxy-manager-web --tail 100

# Kiểm tra .env — thường do:
# - SESSION_SECRET quá ngắn (< 32 chars)
# - ADMIN_PASSWORD không đạt yêu cầu (12+ chars, mixed case, number, special)
# - CLICKHOUSE_PASSWORD thiếu khi COMPOSE_PROFILES=clickhouse
```

---

## Checklist Tổng Hợp

### Trước khi go-live

- [ ] User dockerwaf tạo OK, rootless Docker chạy (`docker info` → rootless: true)
- [ ] AppArmor policy cho rootlesskit đã load
- [ ] sysctl ip_unprivileged_port_start=80 đã set
- [ ] pasta đã cài (`apt install passt`) và rootless Docker đã cấu hình `--net=pasta --port-driver=implicit`
- [ ] Thư mục log host đã tạo (`/home/dockerwaf/caddy-logs`) với đúng ownership
- [ ] Project clone tại /home/dockerwaf/caddy-proxy-manager
- [ ] .env đã cấu hình đúng (SESSION_SECRET, ADMIN_PASSWORD, BASE_URL)
- [ ] docker-socket-proxy đã sửa mount rootless Docker socket
- [ ] Tất cả container healthy trên cả 2 VM
- [ ] Web UI truy cập được (http://IP:3000)
- [ ] Caddy respond trên port 80/443
- [ ] Keepalived chạy trên cả 2 VM
- [ ] VIP nằm trên MASTER
- [ ] Truy cập qua VIP thành công (cả port 80 và 3000)
- [ ] Test failover: stop container → VIP chuyển node
- [ ] Test failover: stop keepalived → VIP chuyển node
- [ ] Test recovery: start lại → VIP quay về MASTER
- [ ] Health check script hoạt động đúng
- [ ] Firewall cho phép VRRP
- [ ] Log ghi nhận đúng state change

### Config files cần backup

```
/home/dockerwaf/caddy-proxy-manager/.env
/home/dockerwaf/caddy-proxy-manager/docker-compose.yml
/etc/keepalived/keepalived.conf
/etc/apparmor.d/home.dockerwaf.bin.rootlesskit
/etc/systemd/user/docker.service.d/override.conf   # pasta config
/usr/local/bin/check_caddy_waf.sh
/usr/local/bin/keepalived_notify.sh
/usr/local/bin/ha_status.sh
```
