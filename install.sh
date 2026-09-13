#!/usr/bin/env bash
# ============================================================================
#  AdGuard Home — автоматическая установка в одну команду
# ----------------------------------------------------------------------------
#  Запуск:
#    sudo bash install.sh
#  Или одной командой (замените URL на свой raw-URL из GitHub):
#    curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/install.sh | sudo bash
#
#  Что делает скрипт:
#    1. Обновляет систему и ставит зависимости (curl, jq, ufw, certbot, ...)
#    2. Настраивает UFW (SSH/DNS/HTTP/HTTPS/DoT/DoQ) БЕЗ сброса существующих правил
#    3. Освобождает порт 53 от systemd-resolved
#    4. Скачивает и устанавливает AdGuard Home как systemd-сервис
#    5. Создаёт администратора и выставляет порты (80/53) через ОФИЦИАЛЬНЫЙ API
#       /control/install/configure — пароль хэширует сам AdGuard (scrypt),
#       никакого велосипеда с htpasswd/openssl/python-хэшами
#    6. Опционально выпускает Let's Encrypt сертификат и включает TLS через
#       /control/tls/config API с Basic Auth
#    7. Ставит renewal-hooks, чтобы certbot мог продлевать сертификат
#       (останавливает AdGuard на время проверки, поднимает обратно)
#
#  Ключевые отличия от сломанной версии:
#    * Никакого ручного хэширования scrypt — используем wizard-API AdGuard'а
#    * Никакого sed по всему YAML — обновляем TLS через JSON-API с jq
#    * Никакого chattr +i на /etc/resolv.conf — он ломает обновления и reboot
#    * JSON строится через jq — спецсимволы в пароле/домене экранируются
#    * SSH-правило добавляется ДО включения UFW — нет риска потерять доступ
#    * Бэкап старого конфига перед удалением
# ============================================================================

set -uo pipefail

# --- Цвета и логирование ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${BLUE}${BOLD}=== $* ===${NC}"; }
die()       { log_error "$*"; exit 1; }

# --- Pre-flight проверки ---
[ "$(id -u)" -eq 0 ] || die "Запустите с правами root: sudo bash $0"

if ! command -v apt-get >/dev/null 2>&1; then
    die "Скрипт рассчитан на Debian/Ubuntu. На вашей ОС он может не работать."
fi

ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] || die "Поддерживается только x86_64 (у вас: $ARCH)."

echo -e "${BLUE}${BOLD}"
echo "================================================"
echo "   Автоматическая установка AdGuard Home"
echo "================================================"
echo -e "${NC}"

# --- Сбор данных ---
log_step "Ввод данных"

read -rp "Домен для SSL (например, doh.example.com) [Enter — без SSL]: " USER_DOMAIN
USER_DOMAIN="${USER_DOMAIN// /}"
USER_DOMAIN="${USER_DOMAIN:-}"

USER_EMAIL=""
if [ -n "$USER_DOMAIN" ]; then
    while true; do
        read -rp "Email для уведомлений Let's Encrypt: " USER_EMAIL
        if [[ "$USER_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            break
        fi
        log_error "Некорректный email. Попробуйте снова."
    done
fi

read -rp "Логин администратора [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"

while true; do
    read -s -rp "Пароль администратора: " ADMIN_PASS; echo
    read -s -rp "Повторите пароль: " ADMIN_PASS2; echo
    [ -z "$ADMIN_PASS" ] && { log_error "Пароль не может быть пустым."; continue; }
    [ "$ADMIN_PASS" = "$ADMIN_PASS2" ] && break
    log_error "Пароли не совпадают. Попробуйте снова."
done

# --- Подтверждение ---
echo
log_info "Проверьте данные перед установкой:"
echo "  Логин:  $ADMIN_USER"
if [ -n "$USER_DOMAIN" ]; then
    echo "  Домен:  $USER_DOMAIN"
    echo "  Email:  $USER_EMAIL"
    echo "  SSL:    будет настроен (Let's Encrypt + DoH/DoT/DoQ)"
else
    echo "  SSL:    отключён"
fi
echo
read -rp "Продолжить установку? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[YyДд]$ ]] || { echo "Отменено пользователем."; exit 0; }

# --- [1/8] Зависимости ---
log_step "[1/8] Обновление системы и установка зависимостей"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y curl wget ufw ca-certificates jq dnsutils

# --- [2/8] Файрвол ---
log_step "[2/8] Настройка UFW (без сброса существующих правил)"

# SSH — ДО включения UFW, чтобы не потерять доступ к серверу
ufw allow 22/tcp comment 'SSH' >/dev/null

ufw default deny incoming
ufw default allow outgoing
ufw allow 53/tcp   comment 'DNS TCP'
ufw allow 53/udp   comment 'DNS UDP'
ufw allow 80/tcp   comment 'HTTP / Lets Encrypt'
ufw allow 443/tcp  comment 'HTTPS / DoH'
ufw allow 853/tcp  comment 'DoT'
ufw allow 784/udp  comment 'DoQ'
ufw allow 3000/tcp comment 'AdGuard wizard (temp)'
ufw --force enable
ufw status verbose | head -30

# --- [3/8] Освобождение порта 53 ---
log_step "[3/8] Освобождение порта 53 от systemd-resolved"

if systemctl is-active --quiet systemd-resolved; then
    systemctl disable --now systemd-resolved
    log_info "systemd-resolved отключён."
else
    log_info "systemd-resolved не активен — пропускаем."
fi

# /etc/resolv.conf БЕЗ chattr +i (это ломает обновления и перезагрузку)
cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
log_info "/etc/resolv.conf переписан на публичные DNS."

# Проверка
if ss -tuln 2>/dev/null | grep -qE ':53\s'; then
    log_warn "Порт 53 всё ещё занят:"
    ss -tuln 2>/dev/null | grep -E ':53\s' || true
    log_warn "AdGuard может не запуститься. Освободите порт вручную и повторите."
fi

# --- [4/8] Проверка порта 80 ---
log_step "[4/8] Проверка порта 80"

if ss -tuln 2>/dev/null | grep -qE ':80\s'; then
    PORT80_INFO="$(ss -tuln 2>/dev/null | grep -E ':80\s' | head -1)"
    log_warn "Порт 80 занят: $PORT80_INFO"
    log_warn "AdGuard не сможет запуститься. Освободите порт и повторите установку."
fi

# --- [5/8] Загрузка AdGuard Home ---
log_step "[5/8] Загрузка AdGuard Home"

INSTALL_DIR="/opt/AdGuardHome"

# Остановить существующий сервис, если он есть
if [ -x "$INSTALL_DIR/AdGuardHome" ]; then
    "$INSTALL_DIR/AdGuardHome" -s stop 2>/dev/null || true
    sleep 1
fi

cd /opt || die "Не удалось перейти в /opt"

if ! curl -fsSL -o /tmp/adguard.tar.gz \
        https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz; then
    die "Не удалось скачать AdGuard Home. Проверьте интернет-соединение."
fi

# Бэкап старого конфига
if [ -f "$INSTALL_DIR/AdGuardHome.yaml" ]; then
    BACKUP="$INSTALL_DIR/AdGuardHome.yaml.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$INSTALL_DIR/AdGuardHome.yaml" "$BACKUP"
    log_info "Старый конфиг сохранён: $BACKUP"
fi

# Распаковка (перезапишет бинарник)
tar -xzf /tmp/adguard.tar.gz -C /opt
rm -f /tmp/adguard.tar.gz

[ -x "$INSTALL_DIR/AdGuardHome" ] || die "Бинарник AdGuardHome не найден после распаковки."

# Удаляем старый конфиг, чтобы запустился мастер установки
rm -f "$INSTALL_DIR/AdGuardHome.yaml"

# --- [6/8] Установка сервиса ---
log_step "[6/8] Установка и запуск сервиса"

"$INSTALL_DIR/AdGuardHome" -s install
"$INSTALL_DIR/AdGuardHome" -s start

# Ждём, пока мастер установки поднимется на порту 3000
log_info "Ожидание мастера установки (порт 3000)..."
WIZARD_OK=false
for _ in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:3000/control/status >/dev/null 2>&1; then
        WIZARD_OK=true
        break
    fi
    sleep 1
done
[ "$WIZARD_OK" = true ] || die "AdGuard не запустился на порту 3000. Смотрите: journalctl -u AdGuardHome"

# --- [7/8] Настройка через ОФИЦИАЛЬНЫЙ wizard-API ---
log_step "[7/8] Настройка через /control/install/configure"
log_info "Пароль хэширует сам AdGuard (scrypt) — никакого ручного хэширования."

# jq безопасно экранирует спецсимволы в пароле и логине
PAYLOAD="$(jq -n \
    --arg user "$ADMIN_USER" \
    --arg pass "$ADMIN_PASS" \
    '{web:{ip:"0.0.0.0",port:80}, dns:{ip:"0.0.0.0",port:53}, username:$user, password:$pass}')"

HTTP_CODE="$(curl -s -o /tmp/agh_resp -w "%{http_code}" \
    -X POST http://127.0.0.1:3000/control/install/configure \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")"

if [ "$HTTP_CODE" != "200" ]; then
    log_error "API вернул HTTP $HTTP_CODE"
    log_error "Ответ: $(cat /tmp/agh_resp 2>/dev/null)"
    rm -f /tmp/agh_resp
    die "Не удалось настроить AdGuard. Смотрите: journalctl -u AdGuardHome"
fi
rm -f /tmp/agh_resp
log_info "Конфигурация применена. AdGuard переключается на порт 80..."

# AdGuard может не перезапуститься сам — поможем
sleep 2
"$INSTALL_DIR/AdGuardHome" -s restart 2>/dev/null || \
    "$INSTALL_DIR/AdGuardHome" -s start 2>/dev/null || true

# Ждём, пока AdGuard поднимется на порту 80
API_OK=false
for _ in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:80/control/status >/dev/null 2>&1; then
        API_OK=true
        break
    fi
    sleep 1
done
[ "$API_OK" = true ] || die "AdGuard не поднялся на порту 80. Смотрите: journalctl -u AdGuardHome"

# Закрываем временный порт 3000 в файрволе
ufw delete allow 3000/tcp 2>/dev/null || true
ufw reload >/dev/null
log_info "Временный порт 3000 закрыт."

# --- [8/8] SSL (опционально) ---
SSL_SUCCESS=false

if [ -n "$USER_DOMAIN" ]; then
    log_step "[8/8] Выпуск SSL-сертификата и настройка TLS"

    # Определяем внешний IP сервера
    SERVER_IP="$(curl -fsS --max-time 5 ifconfig.me 2>/dev/null || true)"

    # Проверяем, что домен смотрит на этот сервер
    if [ -n "$SERVER_IP" ]; then
        RESOLVED_IP="$(dig +short "$USER_DOMAIN" @1.1.1.1 2>/dev/null | tail -1 || true)"
        if [ -n "$RESOLVED_IP" ] && [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
            log_warn "Внимание: $USER_DOMAIN резолвится в $RESOLVED_IP, а внешний IP сервера — $SERVER_IP."
            log_warn "Let's Encrypt не сможет подтвердить домен. Настройте A-запись у регистратора."
            read -rp "Всё равно попытаться выпустить сертификат? [y/N]: " SSL_CONFIRM
            if [[ ! "$SSL_CONFIRM" =~ ^[YyДд]$ ]]; then
                log_info "SSL пропущен по решению пользователя."
                USER_DOMAIN=""
            fi
        fi
    fi
fi

if [ -n "$USER_DOMAIN" ]; then
    # Устанавливаем certbot
    apt-get install -y certbot

    # Останавливаем AdGuard, чтобы освободить порт 80 для certbot --standalone
    "$INSTALL_DIR/AdGuardHome" -s stop
    sleep 2

    if certbot certonly --standalone \
            -d "$USER_DOMAIN" \
            --email "$USER_EMAIL" \
            --agree-tos \
            --non-interactive \
            --no-eff-email; then

        CERT="/etc/letsencrypt/live/$USER_DOMAIN/fullchain.pem"
        KEY="/etc/letsencrypt/live/$USER_DOMAIN/privkey.pem"

        log_info "Сертификат получен. Запускаем AdGuard и настраиваем TLS через API..."
        "$INSTALL_DIR/AdGuardHome" -s start
        sleep 3

        # Получаем текущий TLS-конфиг и модифицируем через jq
        TLS_CFG="$(curl -fsS -u "$ADMIN_USER:$ADMIN_PASS" \
            http://127.0.0.1:80/control/tls/config)" || {
            log_warn "Не удалось получить TLS-конфиг через API."
        }

        if [ -n "$TLS_CFG" ]; then
            TLS_CFG_NEW="$(echo "$TLS_CFG" | jq \
                --arg domain "$USER_DOMAIN" \
                --arg cert "$CERT" \
                --arg key "$KEY" '
                .enabled=true |
                .server_name=$domain |
                .force_https=true |
                .port_https=443 |
                .port_dns_over_tls=853 |
                .port_dns_over_quic=784 |
                .certificate_chain="" |
                .private_key="" |
                .certificate_path=$cert |
                .private_key_path=$key |
                .allow_unencrypted_doh=true |
                .strict_sni_check=false
            ')"

            HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
                -X POST http://127.0.0.1:80/control/tls/config \
                -u "$ADMIN_USER:$ADMIN_PASS" \
                -H "Content-Type: application/json" \
                -d "$TLS_CFG_NEW")"

            if [ "$HTTP_CODE" = "200" ]; then
                log_info "TLS успешно настроен через API."
                SSL_SUCCESS=true
            else
                log_warn "Не удалось применить TLS-конфиг через API (HTTP $HTTP_CODE)."
                log_warn "Включите TLS вручную в веб-панели: Настройки → Шифрование."
                log_warn "Пути к сертификату:"
                log_warn "  $CERT"
                log_warn "  $KEY"
            fi
        fi

        # Hooks для авто-продления сертификата
        # certbot перед проверкой остановит AdGuard (освободит порт 80),
        # после проверки — запустит обратно
        mkdir -p /etc/letsencrypt/renewal-hooks/pre
        mkdir -p /etc/letsencrypt/renewal-hooks/post
        cat > /etc/letsencrypt/renewal-hooks/pre/adguard.sh <<'HOOK'
#!/bin/bash
# Останавливаем AdGuard, чтобы certbot занял порт 80 для проверки
/opt/AdGuardHome/AdGuardHome -s stop 2>/dev/null || true
sleep 2
HOOK
        cat > /etc/letsencrypt/renewal-hooks/post/adguard.sh <<'HOOK'
#!/bin/bash
# Поднимаем AdGuard после продления сертификата
sleep 2
/opt/AdGuardHome/AdGuardHome -s start 2>/dev/null || true
HOOK
        chmod +x /etc/letsencrypt/renewal-hooks/pre/adguard.sh
        chmod +x /etc/letsencrypt/renewal-hooks/post/adguard.sh
        log_info "Renewal-hooks установлены: сертификат будет продлеваться автоматически."

    else
        log_error "Certbot не смог выпустить сертификат."
        log_warn "AdGuard запускается без TLS..."
        "$INSTALL_DIR/AdGuardHome" -s start
        sleep 3
    fi
fi

# --- Финальный отчёт ---
IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "$IP_ADDR" ] && IP_ADDR="${SERVER_IP:-}"
[ -z "$IP_ADDR" ] && IP_ADDR="НЕИЗВЕСТНО"

echo
echo -e "${GREEN}${BOLD}================================================${NC}"
echo -e "${GREEN}${BOLD}  УСТАНОВКА ЗАВЕРШЕНА${NC}"
echo -e "${GREEN}${BOLD}================================================${NC}"
echo
echo "Веб-панель:"
if [ "$SSL_SUCCESS" = true ]; then
    echo "  https://$USER_DOMAIN"
    echo "  (или http://$IP_ADDR)"
else
    echo "  http://$IP_ADDR"
fi
echo
echo "DNS-сервер (укажите на устройствах):"
echo "  $IP_ADDR  (порт 53, можно не указывать)"
if [ "$SSL_SUCCESS" = true ]; then
    echo
    echo "Шифрованный DNS:"
    echo "  DoH:  https://$USER_DOMAIN/dns-query"
    echo "  DoT:  tls://$USER_DOMAIN"
    echo "  DoQ:  quic://$USER_DOMAIN"
fi
echo
echo "Учётные данные:"
echo "  Логин:  $ADMIN_USER"
echo "  Пароль: (тот, что вы ввели)"
echo
echo -e "${YELLOW}Команды управления:${NC}"
echo "  Статус:     $INSTALL_DIR/AdGuardHome -s status"
echo "  Перезапуск: $INSTALL_DIR/AdGuardHome -s restart"
echo "  Остановка:  $INSTALL_DIR/AdGuardHome -s stop"
echo "  Логи:       journalctl -u AdGuardHome -f"
echo
if [ "$SSL_SUCCESS" = true ]; then
    echo -e "${GREEN}Сертификат Let's Encrypt будет продлеваться автоматически${NC}"
    echo -e "${GREEN}(renewal-hooks сами остановят/поднимут AdGuard).${NC}"
fi
echo
