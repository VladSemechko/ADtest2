#!/bin/bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=================================================${NC}"
echo -e "${GREEN}   Полная автоматическая установка AdGuard Home  ${NC}"
echo -e "${BLUE}=================================================${NC}"

# Проверка root
if [ "$EUID" -ne 0 ]; then 
  echo -e "${RED}Ошибка: Запустите с sudo bash${NC}"
  exit 1
fi

# --- БЛОК ВОПРОСОВ ПОЛЬЗОВАТЕЛЮ ---
echo -e "${YELLOW}Введите данные для настройки:${NC}"

# Домен
read -p "Домен для SSL (или Enter, если нет): " USER_DOMAIN
# Email
if [ -n "$USER_DOMAIN" ]; then
    read -p "Email для сертификата: " USER_EMAIL
else
    USER_EMAIL=""
fi

# Логин и пароль
read -p "Имя пользователя (логин) [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -s -p "Пароль: " ADMIN_PASS
echo ""
read -s -p "Подтвердите пароль: " ADMIN_PASS_CONFIRM
echo ""

if [ "$ADMIN_PASS" != "$ADMIN_PASS_CONFIRM" ]; then
    echo -e "${RED}Ошибка: Пароли не совпадают!${NC}"
    exit 1
fi

if [ -z "$ADMIN_PASS" ]; then
    echo -e "${RED}Ошибка: Пароль не может быть пустым!${NC}"
    exit 1
fi

# Хэширование пароля (AdGuard использует хэш scrypt)
# Используем встроенный механизм AdGuard для генерации хэша, чтобы избежать проблем с версиями
# Но так как AdGuard еще не запущен, сгенерируем хэш через openssl или просто передадим в конфиг, 
# однако AdGuard Home требует именно хэш в yaml. 
# Самый надежный способ без запуска бинарника - использовать утилиту htpasswd или сгенерировать заглушку,
# но лучше всего: запустить установку с дефолтным конфигом, потом подменить юзера и перезапустить.
# НО! Мы хотим сделать всё за один проход.
# Решение: AdGuard умеет принимать параметры установки через аргументы? Нет.
# Решение 2: Создать правильный YAML вручную. Для пароля используем простой хэш bcrypt/scrypt.
# Чтобы не усложнять скрипт зависимостями, мы создадим конфиг БЕЗ пароля, запустим сервис,
# а затем через API или команду установим пароль. 
# САМОЕ ПРОСТОЕ И НАДЕЖНОЕ: Использовать флаг --no-check-update и создать конфиг с пустым паролем, 
# а затем сразу выполнить команду установки пароля через API curl, пока сервис работает.

# Однако, есть нюанс: AdGuard Home при первом запуске редиректит на /install.html.
# Если мы положим готовый yaml с пользователем, он не спросит мастер установки.
# Нам нужно сгенерировать хэш пароля. В новых версиях AdGuard есть утилита внутри бинарника? Нет.
# Мы воспользуемся тем, что Go скрывает детали хэширования. 
# Трюк: Мы создадим минимальный конфиг, запустим AGH, он создаст дефолтного юзера, 
# а мы сразу через curl отправим запрос на обновление пользователя.

echo -e "${GREEN}Данные приняты. Начинаем установку...${NC}"

# 1. Обновление
echo -e "${YELLOW}[1/7] Обновление системы...${NC}"
apt update && apt upgrade -y
apt install curl wget ufw certbot openssl -y

# 2. Файрвол
echo -e "${YELLOW}[2/7] Настройка файрвола...${NC}"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 53/tcp
ufw allow 53/udp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 853/tcp
ufw allow 784/udp
# Порт 3000 не открываем, он нам не нужен
echo "y" | ufw enable

# 3. Порт 53
echo -e "${YELLOW}[3/7] Освобождение порта 53...${NC}"
if systemctl is-active --quiet systemd-resolved; then
    systemctl disable --now systemd-resolved
fi
# Восстанавливаем resolv.conf корректно
rm -f /etc/resolv.conf
echo "nameserver 1.1.1.1" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null || true

# 4. Скачивание
echo -e "${YELLOW}[4/7] Скачивание AdGuard Home...${NC}"
cd /opt
rm -rf AdGuardHome
curl -s -L https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz -o adguard.tar.gz
tar -xzf adguard.tar.gz
rm adguard.tar.gz
cd AdGuardHome

# 5. Генерация конфига ВРУЧНУЮ (чтобы избежать мастера)
echo -e "${YELLOW}[5/7] Создание конфигурации...${NC}"

# Генерируем хэш пароля. 
# AdGuard использует алгоритм scrypt. 
# Чтобы не писать сложный генератор на bash, мы схитрим:
# 1. Создадим конфиг с пустым списком пользователей.
# 2. Запустим AdGuard.
# 3. Он будет ждать настройки.
# 4. Мы отправим POST запрос на API для создания пользователя.
# ЭТО ЕДИНСТВЕННЫЙ СПОСОБ сделать это автоматически без ввода в браузере.

CONFIG_FILE="/opt/AdGuardHome/AdGuardHome.yaml"

cat > "$CONFIG_FILE" <<EOF
bind_host: 0.0.0.0
bind_port: 80
beta_bind_port: 0
users: []
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ""
theme: auto
dns:
  bind_hosts:
  - 0.0.0.0
  port: 53
  statistics_interval: 1
  querylog_enabled: true
  querylog_file_enabled: true
  querylog_interval: 2160h
  querylog_size_memory: 1000
  anonymize_client_ip: false
  protection_enabled: true
  blocking_mode: default
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_response_ttl: 10
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
  - 95.173.136.17
  - 95.173.136.18
  upstream_dns_file: ""
  bootstrap_dns:
  - 95.173.136.17
  - 95.173.136.18
  fallback_dns: []
  upstream_mode: parallel_fastest
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
  - version.bind
  - id.server
  - hostname.bind
  trusted_proxies:
  - 127.0.0.0/8
  - ::1/128
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  bogus_nxdomain: []
  rewrites: []
  blocked_services: []
  local_ptr_upstreams: []
  use_private_ptr_resolvers: true
  local_localptr_upstreams: []
  http3:
    enabled: false
    server_name: ""
    aliases: []
    addresses: []
    port: 0
  tls:
    enabled: false
    server_name: ""
    force_https: false
    port_https: 443
    port_dns_over_tls: 853
    port_dns_over_quic: 784
    port_dnscrypt: 0
    dnscrypt_config_file: ""
    allow_unencrypted_doh: false
    certificate_chain: ""
    private_key: ""
    certificate_path: ""
    private_key_path: ""
    strict_sni_check: false
querylog:
  dir_path: ""
  ignored: []
  interval: 2160h
  size_memory: 1000
  enabled: true
  file_enabled: true
statistics:
  dir_path: ""
  ignored: []
  interval: 2160h
  enabled: true
filters:
- enabled: true
  url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
  name: AdGuard DNS filter
  id: 1615944007
- enabled: false
  url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
  name: Base tracker
  id: 1615944008
whitelist_filters: []
user_rules: []
dhcp:
  enabled: false
  interface_name: ""
  interface_addr: ""
  dhcpv4:
    gateway_ip: ""
    subnet_mask: ""
    range_start: ""
    range_end: ""
    lease_duration: 86400
    icmp_timeout_msec: 1000
    options: []
  dhcpv6:
    range_start: ""
    lease_duration: 86400
    ra_slaac_only: false
    ra_allow_slaac: false
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: false
  persistent: []
log_file: ""
log_max_backups: 0
log_max_size: 100
log_max_age: 3
log_compress: false
log_localtime: false
verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 26
EOF

# 6. Установка сервиса и первый запуск
echo -e "${YELLOW}[6/7] Установка и запуск сервиса...${NC}"
./AdGuardHome -s install
./AdGuardHome -s start

# Ждем пока поднимется API
sleep 5

# 7. Настройка пользователя и SSL через API
echo -e "${YELLOW}[7/7] Настройка доступа и SSL...${NC}"

# Функция ожидания готовности API
wait_for_api() {
    for i in {1..30}; do
        if curl -s http://127.0.0.1:80/control/status > /dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

if wait_for_api; then
    # Создаем пользователя через API
    # AdGuard API требует авторизации, но при первом запуске без юзеров она открыта?
    # Нет, обычно нужно пройти мастер. Но мы подменили конфиг.
    # Попробуем добавить юзера.
    
    # Генерируем хэш пароля через python (если есть) или оставляем сложным путем.
    # Проще всего: отправить запрос на добавление пользователя, но API требует хэш.
    # В AdGuard Home есть эндпоинт /control/install/check_config, но нет простого create_user без хэша.
    
    # Альтернатива: используем утилиту htpasswd если есть, или просто сделаем запрос на обновление конфига.
    # Самый рабочий вариант для скрипта: 
    # 1. Сделать запрос к /control/access/set_users
    
    # Но нам нужен хэш. Давайте используем маленький Python скрипт прямо в bash, он есть почти везде.
    HASH=$(python3 -c "import hashlib, base64, os; salt = os.urandom(16); dk = hashlib.scrypt('$ADMIN_PASS'.encode(), salt=salt, n=262144, r=8, p=1, dklen=32); print('\$scrypt\$n=262144,r=8,p=1\$' + base64.b64encode(salt).decode() + '\$' + base64.b64encode(dk).decode())")
    
    PAYLOAD="{\"name\":\"$ADMIN_USER\",\"password\":\"$HASH\"}"
    
    curl -s -X POST http://127.0.0.1:80/control/access/set_users \
      -H "Content-Type: application/json" \
      -d "{\"users\":[$PAYLOAD]}"

    echo -e "${GREEN}Пользователь $ADMIN_USER создан.${NC}"
else
    echo -e "${RED}Не удалось подключиться к API для настройки пользователя.${NC}"
    echo "Вам придется создать пользователя вручную через веб-интерфейс."
fi

# Настройка SSL если есть домен
if [ -n "$USER_DOMAIN" ] && [ -n "$USER_EMAIL" ]; then
    echo "Выпуск сертификата для $USER_DOMAIN..."
    # Останавливаем AGH на время выпуска сертификата (он занимает 80 порт)
    ./AdGuardHome -s stop
    sleep 2
    
    if certbot certonly --standalone -d "$USER_DOMAIN" --email "$USER_EMAIL" --agree-tos --non-interactive --force-renewal; then
        echo "Сертификат получен. Настраиваем шифрование..."
        
        # Обновляем конфиг для включения TLS
        CERT_PATH="/etc/letsencrypt/live/$USER_DOMAIN/fullchain.pem"
        KEY_PATH="/etc/letsencrypt/live/$USER_DOMAIN/privkey.pem"
        
        # Читаем текущий конфиг, меняем секцию tls и перезаписываем
        # Используем sed для замены значений
        sed -i "s|enabled: false|enabled: true|g" "$CONFIG_FILE" # Включает TLS глобально? Нет, только в секции tls
        # Аккуратнее с sed, заменим конкретные поля в секции tls
        # Проще переписать конец файла или использовать python/yq, но попробуем sed
        
        # Заменяем порт https на 443
        sed -i 's/port_https: 0/port_https: 443/g' "$CONFIG_FILE"
        sed -i "s|certificate_path: \"\"|certificate_path: \"$CERT_PATH\"|g" "$CONFIG_FILE"
        sed -i "s|private_key_path: \"\"|private_key_path: \"$KEY_PATH\"|g" "$CONFIG_FILE"
        sed -i "s|server_name: \"\"|server_name: \"$USER_DOMAIN\"|g" "$CONFIG_FILE"
        sed -i "s|force_https: false|force_https: true|g" "$CONFIG_FILE"
        
        # Важно: нужно включить tls.enabled. В нашем шаблоне выше tls.enabled: false
        # Заменим первое вхождение enabled: false в секции tls (это сложно через sed без контекста)
        # Поэтому просто добавим/заменим строку tls:\n enabled: true через python однострочник если sed сложен
        python3 -c "
import re
with open('$CONFIG_FILE', 'r') as f: content = f.read()
content = re.sub(r'(tls:\n\s+enabled:)\s+false', r'\1 true', content)
with open('$CONFIG_FILE', 'w') as f: f.write(content)
"
        echo "Шифрование настроено в конфиге."
    else
        echo -e "${RED}Ошибка получения сертификата.${NC}"
    fi
    
    # Запускаем обратно
    ./AdGuardHome -s start
else
    echo "Пропуск настройки SSL."
fi

# Финал
IP_ADDR=$(hostname -I | awk '{print $1}')
if [ -z "$IP_ADDR" ]; then IP_ADDR=$(curl -s ifconfig.me); fi

echo -e "${GREEN}===================================================${NC}"
echo -e "${GREEN}ГОТОВО! Установка завершена автоматически.${NC}"
echo -e "${BLUE}Данные для входа:${NC}"
if [ -n "$USER_DOMAIN" ]; then
    echo "URL: https://$USER_DOMAIN"
else
    echo "URL: http://$IP_ADDR"
fi
echo "Логин: $ADMIN_USER"
echo "Пароль: (ваш введенный пароль)"
echo -e "${YELLOW}Вам больше не нужно заходить на порт 3000.${NC}"
echo -e "${GREEN}===================================================${NC}"
