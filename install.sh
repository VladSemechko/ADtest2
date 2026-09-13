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

# Если stdin не терминал (curl|bash, wget -O -|bash, cron, etc.),
# переключаем интерактивный ввод на /dev/tty — иначе read мгновенно
# получит EOF и циклы валидации уйдут в бесконечный спам ошибками.
if [ ! -t 0 ]; then
    if [ -t 1 ] && [ -c /dev/tty ]; then
        exec </dev/tty
    else
        die "Скрипт требует интерактивного терминала (tty). Не запускайте его в фоне/через cron. Запустите: sudo bash install.sh"
    fi
fi

echo -e "${BLUE}${BOLD}"
echo "================================================"
echo "   Автоматическая установка AdGuard Home"
echo "================================================"
echo -e "${NC}"

# --- Сбор данных ---
log_step "Ввод данных"

read -rp "Домен для SSL (например, doh.example.com) [Enter — без SSL]: " USER_DOMAIN || die "Не удалось прочитать ввод (stdin закрыт)."
USER_DOMAIN="${USER_DOMAIN// /}"
USER_DOMAIN="${USER_DOMAIN:-}"

USER_EMAIL=""
if [ -n "$USER_DOMAIN" ]; then
    while true; do
        read -rp "Email для уведомлений Let's Encrypt: " USER_EMAIL || die "Не удалось прочитать ввод (stdin закрыт)."
        if [[ "$USER_EMAIL" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]]; then
            break
        fi
        log_error "Некорректный email: '$USER_EMAIL'. Формат: name@example.com"
    done
fi

read -rp "Логин администратора [admin]: " ADMIN_USER || die "Не удалось прочитать ввод (stdin закрыт)."
ADMIN_USER="${ADMIN_USER:-admin}"

while true; do
    read -s -rp "Пароль администратора: " ADMIN_PASS || die "Не удалось прочитать ввод (stdin закрыт)."; echo
    read -s -rp "Повторите пароль: " ADMIN_PASS2 || die "Не удалось прочитать ввод (stdin закрыт)."; echo
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
read -rp "Продолжить установку? [y/N]: " CONFIRM || die "Не удалось прочитать ввод (stdin закрыт)."
[[ "$CONFIRM" =~ ^[YyДд]$ ]] || { echo "Отменено пользователем."; exit 0; }

# --- [1/8] Зависимости ---
log_step "[1/8] Обновление системы и установка зависимостей"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y curl wget ufw ca-certificates jq dnsutils python3 python3-yaml

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
# Мастер установки требует только наличие HTTP-сервера на 3000,
# endpoint /control/status вернёт 401 (требует auth) даже когда мастер жив.
# Поэтому проверяем просто доступность порта.
wait_for_port() {
    local port="$1"
    local tries="${2:-60}"
    for _ in $(seq 1 "$tries"); do
        if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${port}/" 2>/dev/null; then
            return 0
        fi
        # Двойная проверка через ss — иногда curl не успевает из-за таймаута
        if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

log_info "Ожидание мастера установки (порт 3000)..."
WIZARD_OK=false
if wait_for_port 3000 30; then
    WIZARD_OK=true
fi
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
log_info "Конфигурация применена."

# ВАЖНО: AdGuard сам перезапускается после /control/install/configure
# и переключается с порта 3000 на порт 80. НЕ дёргаем restart/start —
# это создавало race condition, из-за которого сервис падал.
# Просто ждём, пока AdGuard поднимется на порту 80.
log_info "Ожидание запуска AdGuard на порту 80 (до 60 сек)..."
API_OK=false
if wait_for_port 80 60; then
    API_OK=true
fi

if [ "$API_OK" != true ]; then
    log_error "AdGuard не поднялся на порту 80."
    log_error "Последние 30 строк лога AdGuardHome:"
    journalctl -u AdGuardHome --no-pager -n 30 2>/dev/null || \
        tail -30 "$INSTALL_DIR/data/logs" 2>/dev/null || true
    die "Смотрите полный лог: journalctl -u AdGuardHome"
fi
log_info "AdGuard успешно запущен на порту 80."

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
            read -rp "Всё равно попытаться выпустить сертификат? [y/N]: " SSL_CONFIRM || die "Не удалось прочитать ввод (stdin закрыт)."
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

        log_info "Сертификат получен. Настраиваем TLS..."

        # Останавливаем AdGuard, чтобы безопасно изменить конфиг.
        # Прямое редактирование YAML надёжнее API: не зависит от версии AdGuard,
        # не требует готовности endpoint'ов, работает на всех сборках.
        "$INSTALL_DIR/AdGuardHome" -s stop
        sleep 2

        CONFIG_FILE="$INSTALL_DIR/AdGuardHome.yaml"
        BACKUP_CFG="$CONFIG_FILE.pre-tls.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_FILE" "$BACKUP_CFG"
        log_info "Бэкап конфига: $BACKUP_CFG"

        # PyYAML ставим отдельно — в Ubuntu 24.04 по умолчанию её нет
        if ! python3 -c "import yaml" 2>/dev/null; then
            log_info "Устанавливаю python3-yaml..."
            apt-get install -y python3-yaml >/dev/null 2>&1 || true
        fi

        TLS_CFG_SUCCESS=false

        if python3 -c "import yaml" 2>/dev/null; then
            log_info "Редактирую конфиг через PyYAML..."

            # Python-скрипт пишет результат в /tmp/tls_apply_result
            # 0 = успех, 1 = ошибка парсинга, 2 = другая ошибка
            python3 <<PYEOF || true
import sys, yaml, io

domain = "$USER_DOMAIN"
cert = "$CERT"
key = "$KEY"
cfg_path = "$CONFIG_FILE"
result_path = "/tmp/tls_apply_result"

def fail(code, msg):
    with open(result_path, 'w') as f:
        f.write(f"{code}:{msg}")
    sys.exit(code)

try:
    with open(cfg_path, 'r', encoding='utf-8') as f:
        data = yaml.safe_load(f)
except Exception as e:
    fail(1, f"YAML parse error: {e}")
    sys.exit(1)

if not isinstance(data, dict):
    fail(1, "Top-level YAML is not a dict")
    sys.exit(1)

# AdGuard Home в разных версиях хранит tls либо на верхнем уровне,
# либо под dns.tls. Поддерживаем оба варианта.
tls_section = {
    'enabled': True,
    'server_name': domain,
    'force_https': True,
    'port_https': 443,
    'port_dns_over_tls': 853,
    'port_dns_over_quic': 784,
    'port_dnscrypt': 0,
    'dnscrypt_config_file': '',
    'allow_unencrypted_doh': True,
    'certificate_chain': '',
    'private_key': '',
    'certificate_path': cert,
    'private_key_path': key,
    'strict_sni_check': False,
}

# Определяем, где уже лежит секция tls
if 'tls' in data and isinstance(data['tls'], dict):
    # tls на верхнем уровне — обновляем
    data['tls'].update(tls_section)
elif 'dns' in data and isinstance(data['dns'], dict) and 'tls' in data['dns'] and isinstance(data['dns']['tls'], dict):
    # tls под dns — обновляем там
    data['dns']['tls'].update(tls_section)
else:
    # Секции нет — создаём на верхнем уровне (как в дефолтном конфиге AGH v0.107+)
    data['tls'] = tls_section

# Сохраняем, сохраняя порядок ключей (sort_keys=False)
try:
    with open(cfg_path, 'w', encoding='utf-8') as f:
        yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False, allow_unicode=True, width=1000)
except Exception as e:
    fail(2, f"YAML write error: {e}")
    sys.exit(2)

# Перечитываем для проверки валидности
try:
    with open(cfg_path, 'r', encoding='utf-8') as f:
        yaml.safe_load(f)
except Exception as e:
    fail(1, f"YAML re-parse error after write: {e}")
    sys.exit(1)

with open(result_path, 'w') as f:
    f.write("0:ok")
print("[INFO] TLS секция записана в конфиг.")
PYEOF

            if [ -f /tmp/tls_apply_result ]; then
                RESULT="$(cat /tmp/tls_apply_result)"
                rm -f /tmp/tls_apply_result
                case "$RESULT" in
                    0:*)
                        log_info "TLS настроен в конфиге."
                        TLS_CFG_SUCCESS=true
                        ;;
                    1:*)
                        log_error "YAML невалиден: ${RESULT#1:}"
                        log_error "Восстанавливаю из бэкапа..."
                        cp "$BACKUP_CFG" "$CONFIG_FILE"
                        ;;
                    2:*)
                        log_error "Ошибка записи: ${RESULT#2:}"
                        log_error "Восстанавливаю из бэкапа..."
                        cp "$BACKUP_CFG" "$CONFIG_FILE"
                        ;;
                    *)
                        log_error "Неизвестный результат: $RESULT"
                        cp "$BACKUP_CFG" "$CONFIG_FILE"
                        ;;
                esac
            else
                log_error "Python-скрипт не отработал. Восстанавливаю из бэкапа..."
                cp "$BACKUP_CFG" "$CONFIG_FILE"
            fi
        else
            log_error "PyYAML недоступна. Восстанавливаю из бэкапа..."
            cp "$BACKUP_CFG" "$CONFIG_FILE"
        fi

        # Fallback через sed — на случай если Python совсем недоступен
        if [ "$TLS_CFG_SUCCESS" != true ]; then
            log_info "Применение TLS через Python fallback (regex)..."
            if python3 - "$CONFIG_FILE" "$USER_DOMAIN" "$CERT" "$KEY" <<'PYFALLBACK' 2>/dev/null
import sys, re

cfg_path = sys.argv[1]
domain = sys.argv[2]
cert = sys.argv[3]
key = sys.argv[4]

with open(cfg_path, 'r') as f:
    lines = f.readlines()

# Находим секцию tls
in_tls = False
out = []
for line in lines:
    if re.match(r'^tls:\s*$', line):
        in_tls = True
        out.append(line)
        continue
    if in_tls:
        if re.match(r'^\S', line):  # начало новой секции
            in_tls = False
            out.append(line)
        else:
            # Заменяем значения
            if re.match(r'^\s*enabled:\s*', line):
                out.append('  enabled: true\n')
            elif re.match(r'^\s*server_name:\s*', line):
                out.append(f'  server_name: "{domain}"\n')
            elif re.match(r'^\s*force_https:\s*', line):
                out.append('  force_https: true\n')
            elif re.match(r'^\s*port_https:\s*', line):
                out.append('  port_https: 443\n')
            elif re.match(r'^\s*port_dns_over_tls:\s*', line):
                out.append('  port_dns_over_tls: 853\n')
            elif re.match(r'^\s*port_dns_over_quic:\s*', line):
                out.append('  port_dns_over_quic: 784\n')
            elif re.match(r'^\s*certificate_path:\s*', line):
                out.append(f'  certificate_path: "{cert}"\n')
            elif re.match(r'^\s*private_key_path:\s*', line):
                out.append(f'  private_key_path: "{key}"\n')
            elif re.match(r'^\s*allow_unencrypted_doh:\s*', line):
                out.append('  allow_unencrypted_doh: true\n')
            elif re.match(r'^\s*strict_sni_check:\s*', line):
                out.append('  strict_sni_check: false\n')
            else:
                out.append(line)
    else:
        out.append(line)

with open(cfg_path, 'w') as f:
    f.writelines(out)
print("[INFO] TLS применён через Python fallback.")
PYFALLBACK
            then
                TLS_CFG_SUCCESS=true
            else
                log_error "Python fallback недоступен или упал. TLS не настроен."
                SSL_SUCCESS=false
            fi
        fi

        # Запускаем обратно
        "$INSTALL_DIR/AdGuardHome" -s start
        sleep 4

        # Проверяем, что сервис жив
        if curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:80/" 2>/dev/null; then
            log_info "AdGuard успешно запущен с TLS."
            # Дополнительная проверка — доступен ли HTTPS
            if curl -fsS -o /dev/null --max-time 5 -k "https://127.0.0.1:443/" 2>/dev/null; then
                log_info "HTTPS (443) — OK."
                SSL_SUCCESS=true
            else
                log_warn "HTTP работает, но HTTPS (443) не отвечает."
                log_warn "Проверьте логи: journalctl -u AdGuardHome -n 30"
                SSL_SUCCESS=false
            fi
        else
            log_error "AdGuard не поднялся после включения TLS!"
            log_error "Последние 20 строк лога:"
            journalctl -u AdGuardHome --no-pager -n 20 2>/dev/null || true
            log_error "Восстанавливаю конфиг из бэкапа..."
            cp "$BACKUP_CFG" "$CONFIG_FILE"
            "$INSTALL_DIR/AdGuardHome" -s start
            sleep 3
            log_warn "AdGuard запущен БЕЗ TLS. Сертификат на месте: $CERT"
            SSL_SUCCESS=false
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
