#!/usr/bin/env bash
# ============================================================
# Автоустановка ноды Remnawave (Trojan / Hysteria2)
# ============================================================
set -euo pipefail

CERTBOT_IMAGE="certbot/dns-cloudflare"   # единый образ: умеет и standalone, и dns-cloudflare

echo "════════════════════════════════════════════"
echo " Установка ноды Remnawave: Trojan / Hysteria2"
echo "════════════════════════════════════════════"

# ── 0. Какой протокол ставим ──
echo ""
echo "Какую ноду разворачиваем?"
echo "  1) Trojan (TCP/TLS)"
echo "  2) Hysteria2 (UDP/QUIC)"
echo "  3) Обе (Trojan + Hysteria2 на одном порту, TCP+UDP)"
read -rp "Выбор [1-3]: " NODE_MODE

# ── 1. Базовые параметры ──
read -rp "Введите SECRET_KEY (ключ из панели Remnawave, БЕЗ кавычек): " SECRET_KEY
read -rp "Введите DOMAIN (для обычного серта — должен резолвиться на этот сервер): " DOMAIN
read -rp "Введите email для сертификата (Let's Encrypt): " EMAIL

# ── 2. Как выпускаем сертификат ──
echo ""
echo "Способ выпуска сертификата:"
echo "  1) Let's Encrypt HTTP-01 (standalone) — обычный домен, порт 80 открыт наружу"
echo "  2) Cloudflare DNS-01 (Global API Key) — обычный или wildcard, порт 80 не нужен"
read -rp "Выбор [1-2]: " CERT_MODE

WILDCARD="no"
CF_EMAIL=""
CF_API_KEY=""
if [ "$CERT_MODE" = "2" ]; then
  read -rp "Cloudflare account email: " CF_EMAIL
  read -rp "Cloudflare Global API Key: " CF_API_KEY
  read -rp "Выпустить ещё и wildcard *.$DOMAIN? (y/N): " WC_ANSWER
  [ "${WC_ANSWER,,}" = "y" ] && WILDCARD="yes"
fi

NODE_PORT="2222"            # порт ноды для панели
INBOUND_PORT="443"          # порт протокола (TCP для trojan, UDP для hysteria2)
DECOY="vkcloud"              # заглушка (downloads/decoy/<name>), пусто = выкл
SITE_URL="https://sh.ghostos.space"
ENABLE_BBR="yes"
ENABLE_IPV6="auto"

TCP_PORTS="22 80 ${NODE_PORT}"
UDP_PORTS=""
case "$NODE_MODE" in
  1) TCP_PORTS="$TCP_PORTS $INBOUND_PORT" ;;                       # Trojan: только TCP
  2) UDP_PORTS="$INBOUND_PORT" ;;                                  # Hysteria2: только UDP
  3) TCP_PORTS="$TCP_PORTS $INBOUND_PORT"; UDP_PORTS="$INBOUND_PORT" ;;  # Обе: TCP+UDP на 443
  *) echo "❌ Неверный выбор режима ноды"; exit 1 ;;
esac

# ── Проверки окружения ──
[ "$(id -u)" -eq 0 ] || { echo "❌ Запускайте от root (sudo su)"; exit 1; }
case "$SECRET_KEY" in ""|*"панели"*|"ВСТАВЬ"*) echo "❌ Впишите SECRET_KEY"; exit 1;; esac
case "$DOMAIN" in ""|"node.example.com") echo "❌ Впишите свой DOMAIN"; exit 1;; esac
case "$EMAIL" in "") echo "❌ Впишите email для сертификата"; exit 1;; esac
if [ "$CERT_MODE" = "2" ]; then
  case "$CF_EMAIL" in "") echo "❌ Впишите Cloudflare email"; exit 1;; esac
  case "$CF_API_KEY" in "") echo "❌ Впишите Cloudflare Global API Key"; exit 1;; esac
fi

# ── Базовые пакеты + Docker ──
apt update
DEBIAN_FRONTEND=noninteractive apt install -y curl wget nano ca-certificates iptables-persistent dnsutils openssl
if ! command -v docker >/dev/null 2>&1; then echo "▶️ Ставлю Docker…"; curl -fsSL https://get.docker.com | sh; fi
systemctl enable --now docker
docker compose version >/dev/null 2>&1 || { echo "❌ docker compose недоступен"; exit 1; }

# ── Проверка DNS (только для HTTP-01, DNS-01 работает и без A-записи на этот IP) ──
if [ "$CERT_MODE" = "1" ]; then
  SERVER_IP="$(curl -fsS4 https://api.ipify.org || true)"
  DOMAIN_IP="$(dig +short A "$DOMAIN" | tail -n1 || true)"
  echo "▶️ IP сервера: ${SERVER_IP:-?} | A-запись $DOMAIN → ${DOMAIN_IP:-нет}"
  if [ -n "$SERVER_IP" ] && [ -n "$DOMAIN_IP" ] && [ "$SERVER_IP" != "$DOMAIN_IP" ]; then
    echo "⚠️  A-запись не совпадает с IP сервера — HTTP-01 валидация может упасть."
    read -rp "   Продолжить всё равно? (y/N) " yn; [ "$yn" = "y" ] || exit 1
  fi
fi

# ── Firewall (открываем ДО выпуска сертификата) ──
open_fw() {
  local cmd="$1"
  for p in $TCP_PORTS; do "$cmd" -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || "$cmd" -A INPUT -p tcp --dport "$p" -j ACCEPT; done
  for p in $UDP_PORTS; do [ -n "$p" ] || continue; "$cmd" -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || "$cmd" -A INPUT -p udp --dport "$p" -j ACCEPT; done
}
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  echo "▶️ Активный UFW — открываю порты через него"
  for p in $TCP_PORTS; do ufw allow "${p}/tcp" >/dev/null; done
  for p in $UDP_PORTS; do [ -n "$p" ] && ufw allow "${p}/udp" >/dev/null; done
  ufw reload >/dev/null 2>&1 || true
else
  echo "▶️ Открываю порты через iptables"
  open_fw iptables
  if [ "$ENABLE_IPV6" = "yes" ] || { [ "$ENABLE_IPV6" = "auto" ] && ip -6 addr show scope global 2>/dev/null | grep -q inet6; }; then open_fw ip6tables; fi
  netfilter-persistent save >/dev/null 2>&1 || true
fi
echo "⚠️  Если у провайдера есть внешний firewall — откройте те же порты и там."

# ── SSL-сертификат ──
mkdir -p /opt/certbot/certs /opt/certbot/var
if [ "$CERT_MODE" = "2" ]; then
  # Cloudflare DNS-01 (Global API Key) — обычный и/или wildcard
  mkdir -p /root/.secrets/certbot
  cat > /root/.secrets/certbot/cloudflare.ini << CFEOF
dns_cloudflare_email = ${CF_EMAIL}
dns_cloudflare_api_key = ${CF_API_KEY}
CFEOF
  chmod 600 /root/.secrets/certbot/cloudflare.ini

  DOMAIN_ARGS=(-d "$DOMAIN")
  [ "$WILDCARD" = "yes" ] && DOMAIN_ARGS+=(-d "*.$DOMAIN")

  docker run --rm \
    -v /opt/certbot/certs:/etc/letsencrypt \
    -v /opt/certbot/var:/var/lib/letsencrypt \
    -v /root/.secrets/certbot:/root/.secrets/certbot:ro \
    "$CERTBOT_IMAGE" certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 30 \
    --non-interactive --agree-tos --email "$EMAIL" \
    "${DOMAIN_ARGS[@]}"
else
  # Let's Encrypt HTTP-01 standalone
  docker run --rm \
    -v /opt/certbot/certs:/etc/letsencrypt \
    -v /opt/certbot/var:/var/lib/letsencrypt \
    --network host \
    "$CERTBOT_IMAGE" certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN"
fi
[ -f "/opt/certbot/certs/live/$DOMAIN/fullchain.pem" ] || { echo "❌ Сертификат не выпущен"; exit 1; }
echo "✅ Сертификат для $DOMAIN получен ($([ "$WILDCARD" = "yes" ] && echo "включая wildcard *.$DOMAIN"))"

# ── Сайт-заглушка (decoy) для легитимности и фоллбэка ──
if [ -n "$DECOY" ]; then
  echo "▶️ Ставлю заглушку «$DECOY»…"
  GHOST_DECOY="$DECOY" bash <(curl -fsSL "https://sh.ghostos.space/spectral/u/0e939f98edaf6f91/spectral/core/sc-decoy.sh")
fi

# ── Оптимизация nginx.conf (воркеры/лимиты/буферы для XHTTP) ──
if command -v nginx >/dev/null 2>&1; then
  mkdir -p /etc/nginx/conf.d /etc/nginx/sites-enabled
  [ -f /etc/nginx/nginx.conf.ghost-bak ] || cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.ghost-bak 2>/dev/null || true
  cat > /etc/nginx/nginx.conf << 'NGXEOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 1048576;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}
http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    types_hash_max_size 4096;
    server_tokens off;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:xhttp_ssl:20m;
    ssl_session_timeout 1d;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log warn;
    gzip off;
    keepalive_timeout 30s;
    keepalive_requests 1000;
    reset_timedout_connection on;
    send_timeout 60s;
    client_body_timeout 60s;
    client_header_timeout 60s;
    client_max_body_size 0;
    client_header_buffer_size 16k;
    large_client_header_buffers 8 32k;
    proxy_headers_hash_max_size 1024;
    proxy_headers_hash_bucket_size 128;
    map_hash_bucket_size 128;
    map_hash_max_size 4096;
    log_format xhttp_min '$remote_addr $time_local host="$host" proto="$server_protocol" '
        '"$request_method $request_uri" st=$status bytes=$body_bytes_sent '
        'cl="$content_length" req_len=$request_length '
        'rt=$request_time urt="$upstream_response_time" '
        'ua="$http_user_agent"';
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGXEOF
  mkdir -p /etc/systemd/system/nginx.service.d
  printf '[Service]\nLimitNOFILE=1048576\nTasksMax=infinity\n' > /etc/systemd/system/nginx.service.d/ghost-limits.conf
  systemctl daemon-reload 2>/dev/null || true
  if nginx -t >/dev/null 2>&1; then systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true; else cp -a /etc/nginx/nginx.conf.ghost-bak /etc/nginx/nginx.conf 2>/dev/null || true; echo "⚠️  Тюнинг nginx.conf не прошёл nginx -t — откат к бэкапу"; fi
fi

# ── Remnanode (docker compose) — SECRET_KEY БЕЗ кавычек в ENV ──
NODE_IMAGE="${GHOST_NODE_IMAGE:-remnawave/node:latest}"
mkdir -p /opt/remnanode && cd /opt/remnanode
cat > docker-compose.yml << DEOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ${NODE_IMAGE}
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY=${SECRET_KEY}
    volumes:
      - '/opt/certbot/certs:/etc/letsencrypt:ro'
DEOF
docker compose pull
docker compose up -d --force-recreate
sleep 3
docker compose ps -a

# ── Автообновление сертификата (раз в месяц, тот же образ покрывает оба метода) ──
CRON_LINE="0 3 1 * * docker run --rm -v /opt/certbot/certs:/etc/letsencrypt -v /opt/certbot/var:/var/lib/letsencrypt -v /root/.secrets/certbot:/root/.secrets/certbot:ro --network host ${CERTBOT_IMAGE} renew --quiet && cd /opt/remnanode && docker compose restart"
( crontab -l 2>/dev/null | grep -v 'certbot.*renew' || true; echo "$CRON_LINE" ) | crontab -
echo "✅ Cron renew установлен"

# ── BBR + сетевой тюнинг ──
if [ "$ENABLE_BBR" = "yes" ]; then
  cat > /etc/sysctl.d/99-ghost.conf << 'SEOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.rmem_max=16777216
net.core.wmem_max=16777216
SEOF
  sysctl --system >/dev/null 2>&1 || true
  echo "✅ BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
fi

# ── Готово ──
MODE_NAME="Trojan"
[ "$NODE_MODE" = "2" ] && MODE_NAME="Hysteria2"
[ "$NODE_MODE" = "3" ] && MODE_NAME="Trojan + Hysteria2"
echo "════════════════════════════"
echo "✅ Нода ($MODE_NAME) поднята на $DOMAIN. Дальше — в панели Remnawave:"
echo "   • Создайте Config Profile (JSON) и Host под выбранный протокол"
echo "   • Логи ноды: cd /opt/remnanode && docker compose logs -f"
echo "   • После правки ENV: docker compose down && docker compose up -d (НЕ restart)"
echo "════════════════════════════"
