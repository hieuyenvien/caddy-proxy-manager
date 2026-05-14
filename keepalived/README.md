# Hướng Dẫn Triển Khai HA Caddy WAF — Hướng 2

## Kiến trúc

```
                     Admin truy cập Web UI
                     http://10.2.159.20:3000
                             │
                       [VIP: 10.2.159.20]
                             │
              ┌──────────────┴──────────────┐
              │                             │
       VM1 .18 (MASTER)             VM2 .19 (BACKUP)
       ┌──────────────────┐         ┌──────────────────┐
       │ Keepalived ✓     │         │ Keepalived ✓     │
       │ Caddy WAF ✓ :80  │         │ Caddy WAF ✓ :80  │
       │ Web UI ✓ :3000   │──sync──►│ Web UI ✓ :3000   │
       │ INSTANCE=master  │  REST   │ INSTANCE=slave   │
       └──────────────────┘   API   └──────────────────┘

Caddy WAF (port 80/443): chạy 24/7 trên CẢ 2 node
Web UI (port 3000):      chạy 24/7 trên CẢ 2 node
  - VM1 (master): nhận và xử lý thay đổi config
  - VM2 (slave):  nhận config từ VM1 qua REST API định kỳ
```

## Cơ chế đồng bộ

```
Admin sửa config trên Web UI (.20:3000 → VM1)
         │
         ▼
  Web UI VM1 (INSTANCE_MODE=master)
         │
         │  REST API push mỗi INSTANCE_SYNC_INTERVAL giây
         │  POST /api/instances/sync  (Bearer INSTANCE_SYNC_TOKEN)
         ▼
  Web UI VM2 (INSTANCE_MODE=slave)
         │
         ▼
  Caddy VM2 tự động reload từ DB đã sync

Khi failover:
  Keepalived chuyển VIP → VM2
  → keepalived_notify.sh reload Caddy VM2
  → Config đã sẵn sàng (đã sync trước đó)
```

> **Lưu ý:** Chỉ thực hiện thay đổi config trên Web UI qua VIP (.20:3000).
> VM2 hoạt động ở chế độ slave — config sẽ bị ghi đè bởi lần sync tiếp theo từ VM1.

---

## Bước 1: Chuẩn bị (cả 2 VM, chạy root)

### 1.1 Trên VM1 (10.2.159.18) — đã có stack chạy

```bash
# Sửa .env — BASE_URL phải là VIP, thêm INSTANCE_SYNC config
nano /home/dockerwaf/caddy-proxy-manager/.env
```

Thêm vào .env của VM1:
```env
BASE_URL=http://10.2.159.20:3000
INSTANCE_MODE=master
# token trong INSTANCE_SLAVES phải trùng với INSTANCE_SYNC_TOKEN trên VM2
INSTANCE_SLAVES=[{"name":"vm2","url":"http://10.2.159.19:3000","token":"<openssl rand -hex 32>"}]
INSTANCE_SYNC_INTERVAL=30
INSTANCE_SYNC_ALLOW_HTTP=true
```

```bash
# Restart để áp dụng config mới
machinectl shell dockerwaf@
cd ~/caddy-proxy-manager
docker compose up -d
exit
```

### 1.2 Copy thư mục keepalived lên cả 2 VM

```bash
scp -r keepalived/ root@10.2.159.18:/root/
scp -r keepalived/ root@10.2.159.19:/root/
```

---

## Bước 2: Triển khai VM1

```bash
ssh root@10.2.159.18
bash /root/keepalived/setup_ha.sh vm1
```

---

## Bước 3: Triển khai VM2

```bash
ssh root@10.2.159.19

# Trước tiên: cài Docker stack trên VM2 (theo quy trình Phần 1-3 trong file md chính)
# Sau khi stack chạy OK, sửa .env của VM2:
nano /home/dockerwaf/caddy-proxy-manager/.env
```

Thêm vào .env của VM2 (dùng cùng INSTANCE_SYNC_TOKEN với VM1):
```env
BASE_URL=http://10.2.159.20:3000
INSTANCE_MODE=slave
INSTANCE_SYNC_TOKEN=<same token as VM1>
INSTANCE_SYNC_ALLOW_HTTP=true
```

```bash
# Restart stack VM2
machinectl shell dockerwaf@
cd ~/caddy-proxy-manager
docker compose up -d
exit

# Chạy setup keepalived
bash /root/keepalived/setup_ha.sh vm2
```

---

## Bước 4: Đồng bộ lần đầu VM1 → VM2

```bash
# Trên VM1 (root) — trigger sync ngay thay vì đợi INSTANCE_SYNC_INTERVAL
/usr/local/bin/sync_config.sh

# Kiểm tra log:
tail -20 /var/log/keepalived-sync.log
```

---

## Bước 5: Khởi tạo trạng thái ban đầu

### Restart Keepalived cả 2 VM

```bash
# VM1:
systemctl restart keepalived

# VM2:
systemctl restart keepalived
```

---

## Bước 6: Verify

```bash
# Trên VM1 — phải là MASTER
ha_status.sh

# Trên VM2 — phải là BACKUP
ha_status.sh

# Test truy cập qua VIP
curl http://10.2.159.20/          # Caddy WAF
curl http://10.2.159.20:3000/api/health  # Web UI qua VIP

# Kiểm tra instance sync hoạt động (trên VM1)
curl -s http://localhost:3000/api/v1/settings/instance \
    -H "Authorization: Bearer <ADMIN_TOKEN>" | jq .
```

---

## Test Failover

### Kịch bản 1: Stop keepalived trên VM1

```bash
# VM1 (root):
systemctl stop keepalived
# VIP chuyển sang VM2 ngay (<3 giây)

# VM2: theo dõi log
tail -f /var/log/keepalived-state.log
# Sẽ thấy:
#   VIP is now on THIS node — becoming MASTER
#   Reloading Caddy config...
#   MASTER transition complete

# Test Web UI vẫn truy cập được
curl http://10.2.159.20:3000/api/health

# Recovery: start lại keepalived VM1
systemctl start keepalived
# VIP quay về VM1 (priority cao hơn)
```

### Kịch bản 2: Stop Caddy container trên VM1

```bash
# VM1 (dockerwaf):
docker stop caddy-proxy-manager-caddy
# Keepalived health check fail sau 9 giây (interval=3 x fall=3)
# priority giảm 30: 100-30=70 < VM2=90 → VIP failover

# Recovery:
docker start caddy-proxy-manager-caddy
# Sau 6 giây (interval=3 x rise=2), priority phục hồi → VIP về VM1
```

---

## Rolling Update

```bash
# === Bước 1: Update VM2 (BACKUP) ===
ssh dockerwaf@10.2.159.19
cd ~/caddy-proxy-manager
git pull && docker compose pull
docker compose up -d --no-deps caddy web l4-port-manager
exit

# === Bước 2: Failover VIP sang VM2 ===
ssh root@10.2.159.18
systemctl stop keepalived
# Chờ VM2 nhận VIP và Caddy reload (~5 giây)
curl http://10.2.159.20:3000/api/health   # Phải OK

# === Bước 3: Update VM1 ===
ssh dockerwaf@10.2.159.18
cd ~/caddy-proxy-manager
git pull && docker compose pull
docker compose up -d --no-deps caddy web l4-port-manager
exit

# === Bước 4: Restore ===
ssh root@10.2.159.18
systemctl start keepalived
# VIP về VM1, instance sync tiếp tục
```

---

## Cấu trúc file

```
keepalived/
├── setup_ha.sh                    ← Chạy một lần trên mỗi VM
├── shared/
│   ├── check_caddy_waf.sh         → /usr/local/bin/  (cả 2 VM)
│   ├── sync_config.sh             → /usr/local/bin/  (cả 2 VM, trigger API sync thủ công)
│   ├── ha_status.sh               → /usr/local/bin/  (cả 2 VM)
│   └── .env.example               → ~/caddy-proxy-manager/.env  (cả 2 VM)
├── vm1/
│   ├── keepalived.conf            → /etc/keepalived/  (VM1 only)
│   └── keepalived_notify.sh       → /usr/local/bin/  (VM1 only)
└── vm2/
    ├── keepalived.conf            → /etc/keepalived/  (VM2 only)
    └── keepalived_notify.sh       → /usr/local/bin/  (VM2 only)
```

---

## Xử lý sự cố

### Sync không hoạt động

```bash
# Kiểm tra log sync
tail -20 /var/log/keepalived-sync.log

# Test API thủ công từ VM1
curl -v -X POST http://localhost:3000/api/instances/sync \
    -H "Authorization: Bearer ${INSTANCE_SYNC_TOKEN}"

# Kiểm tra VM2 có nhận được không
tail -20 /var/log/keepalived-state.log
```

### VIP không floating

```bash
# Check VRRP packets
tcpdump -i enp1s0 -n vrrp -c 10

# Check priority hiện tại
journalctl -u keepalived --no-pager -n 30 | grep -i priority
```

### Web UI VM2 không nhận sync

```bash
# Kiểm tra .env VM2 có đúng INSTANCE_MODE=slave không
grep INSTANCE /home/dockerwaf/caddy-proxy-manager/.env

# INSTANCE_SYNC_TOKEN phải trùng với VM1
# INSTANCE_SYNC_ALLOW_HTTP=true (cần thiết vì dùng HTTP nội bộ)
```
