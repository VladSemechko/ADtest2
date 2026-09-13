#!/bin/bash

# AdGuard Home Auto-Installer Script
# Автоматическая установка и настройка AdGuard Home на Ubuntu

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  AdGuard Home Auto-Installer Script  ${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Функция для вывода сообщений
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка запуска от root
if [ "$EUID" -ne 0 ]; then
    log_error "Скрипт должен быть запущен от root (sudo)"
    exit 1
fi

# Запрос данных у пользователя
echo -e "${YELLOW}=== Необходимые данные ===${NC}"
echo ""

# Домен для шифрования (опционально)
read -p "Введите домен для шифрования DNS (или нажмите Enter для пропуска): " DOMAIN_NAME

# Если домен введен, запрашиваем email для Let's Encrypt
if [ -n "$DOMAIN_NAME" ]; then
    read -p "Введите Email для уведомлений Let's Encrypt: " LETS_EMAIL
fi

echo ""
log_info "Начинаю установку..."
echo ""

# Шаг 1: Обновление системы
log_info "Обновление системы..."
apt update && apt upgrade -y

# Установка базовых утилит
log_info "Установка базовых утилит..."
apt install -y curl wget ufw certbot

# Шаг 2: Настройка файрвола UFW
log_info "Настройка файрвола UFW..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp      # SSH
ufw allow 53/tcp      # DNS TCP
ufw allow 53/udp      # DNS UDP
ufw allow 80/tcp      # HTTP (Let's Encrypt)
ufw allow 3000/tcp    # Adguard (временный)
ufw allow 443/tcp     # DoH
ufw allow 853/tcp     # DoT
ufw allow 784/udp     # DoQ

# Включаем UFW только если он еще не включен
if ! ufw status | grep -q "Status: active"; then
    echo "y" | ufw enable
fi

log_info "Файрвол настроен"

# Шаг 3: Проверка и освобождение порта 53
log_info "Проверка порта 53..."
if ss -tuln | grep -q ":53 "; then
    log_warn "Порт 53 занят, освобождаю..."
    systemctl disable systemd-resolved --now
    rm -f /etc/resolv.conf
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    log_info "Порт 53 освобожден"
else
    log_info "Порт 53 свободен"
fi

# Шаг 4: Скачивание и установка AdGuard Home
log_info "Скачивание AdGuard Home..."
cd /opt

# Проверяем, существует ли уже AdGuardHome
if [ -d "/opt/AdGuardHome" ]; then
    log_warn "AdGuard Home уже установлен в /opt/AdGuardHome"
    read -p "Хотите переустановить? (y/n): " REINSTALL
    if [ "$REINSTALL" = "y" ]; then
        systemctl stop AdGuardHome 2>/dev/null || true
        rm -rf /opt/AdGuardHome
    else
        log_info "Пропускаю установку, перехожу к настройке"
        cd /opt/AdGuardHome
    fi
fi

if [ ! -d "/opt/AdGuardHome" ]; then
    curl -s -L https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz -o adguard.tar.gz
    tar -xzf adguard.tar.gz
    rm adguard.tar.gz
    cd AdGuardHome
    
    log_info "Установка AdGuard Home как сервиса..."
    ./AdGuardHome -s install
    
    log_info "Запуск AdGuard Home..."
    ./AdGuardHome -s start
fi

# Проверка статуса
log_info "Проверка статуса сервиса..."
./AdGuardHome -s status

# Получение IP адреса сервера
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Первоначальная настройка required  ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
log_info "Откройте в браузере: http://${SERVER_IP}:3000"
echo ""
echo "Выполните следующие действия в веб-интерфейсе:"
echo "  1. Пройдите мастер первоначальной настройки"
echo "  2. Укажите порт веб-интерфейса: 80"
echo "  3. Укажите порт DNS сервера: 53"
echo "  4. Завершите настройку"
echo ""
read -p "Нажмите Enter после завершения настройки в веб-интерфейсе..."

# Перезапуск сервиса для применения настроек
log_info "Перезапуск AdGuard Home..."
./AdGuardHome -s restart

# Удаление временного правила UFW
log_info "Удаление временного правила для порта 3000..."
ufw delete allow 3000/tcp || true
ufw reload

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Базовая настройка завершена!         ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
log_info "Панель управления: http://${SERVER_IP}/"
log_info "DNS сервер: ${SERVER_IP}:53 (или просто ${SERVER_IP})"
echo ""

# Шаг с шифрованием (если домен указан)
if [ -n "$DOMAIN_NAME" ]; then
    echo -e "${YELLOW}=== Настройка шифрования DNS ===${NC}"
    echo ""
    log_info "Домен: ${DOMAIN_NAME}"
    
    # Проверка DNS записи
    log_warn "Убедитесь, что в DNS записях вашего домена A-запись указывает на IP: ${SERVER_IP}"
    read -p "Нажмите Enter для продолжения или Ctrl+C для отмены..."
    
    # Остановка AdGuard Home для выпуска сертификата
    log_info "Остановка AdGuard Home для выпуска сертификата..."
    ./AdGuardHome -s stop
    
    # Выпуск сертификата
    log_info "Выпуск SSL сертификата через Let's Encrypt..."
    if [ -n "$LETS_EMAIL" ]; then
        certbot certonly --standalone -d "${DOMAIN_NAME}" --email "${LETS_EMAIL}" --agree-tos --non-interactive
    else
        certbot certonly --standalone -d "${DOMAIN_NAME}"
    fi
    
    # Запуск AdGuard Home
    log_info "Запуск AdGuard Home..."
    ./AdGuardHome -s start
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Сертификат успешно выпущен!          ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    log_info "Пути к сертификатам:"
    echo "  Полный сертификат: /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem"
    echo "  Приватный ключ: /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem"
    echo ""
    echo "Теперь в панели управления AdGuard Home перейдите в:"
    echo "  Настройки > Шифрование"
    echo ""
    echo "И настройте следующие параметры:"
    echo "  ✓ Включить шифрование"
    echo "  ✓ Доменное имя: ${DOMAIN_NAME}"
    echo "  ✓ Автоматически перенаправлять на HTTPS"
    echo "  ✓ Путь к полному сертификату: /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem"
    echo "  ✓ Путь к приватному ключу: /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem"
    echo ""
else
    echo -e "${YELLOW}=== Шифрование пропущено ===${NC}"
    echo ""
    echo "Для настройки шифрования в будущем вам понадобится:"
    echo "  1. Домен с A-записью на IP вашего сервера"
    echo "  2. Выполнить команду: sudo certbot certonly --standalone -d yourdomain.com"
    echo "  3. Настроить в панели AdGuard Home: Настройки > Шифрование"
    echo ""
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Установка завершена успешно!         ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
log_info "Полезные команды:"
echo "  Статус сервиса: sudo /opt/AdGuardHome/AdGuardHome -s status"
echo "  Перезапуск: sudo /opt/AdGuardHome/AdGuardHome -s restart"
echo "  Остановка: sudo /opt/AdGuardHome/AdGuardHome -s stop"
echo "  Запуск: sudo /opt/AdGuardHome/AdGuardHome -s start"
echo "  Логи: journalctl -u AdGuardHome -f"
echo ""
log_info "Не забудьте настроить DNS на ваших устройствах: ${SERVER_IP}"
echo ""
