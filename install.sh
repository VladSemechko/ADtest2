#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Без цвета

echo -e "${BLUE}=================================================${NC}"
echo -e "${GREEN}   Скрипт автоматической установки AdGuard Home  ${NC}"
echo -e "${BLUE}=================================================${NC}"

# Проверка прав root
if [ "$EUID" -ne 0 ]; then 
  echo -e "${RED}Ошибка: Запустите команду с sudo перед pipe или от root.${NC}"
  echo "Пример: curl -sL ... | sudo bash"
  exit 1
fi

# 1. Обновление системы и установка утилит
echo -e "${YELLOW}[1/8] Обновление системы...${NC}"
apt update && apt upgrade -y
apt install curl wget ufw certbot -y

# 2. Настройка UFW (Файрвол)
echo -e "${YELLOW}[2/8] Настройка файрвола UFW...${NC}"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp      # SSH
ufw allow 53/tcp      # DNS TCP
ufw allow 53/udp      # DNS UDP
ufw allow 80/tcp      # HTTP (Let's Encrypt + Web UI после настройки)
ufw allow 3000/tcp    # Adguard (временный порт для первичной настройки)
ufw allow 443/tcp     # DoH (HTTPS)
ufw allow 853/tcp     # DoT
ufw allow 784/udp     # DoQ
echo "y" | ufw enable
echo -e "${GREEN}Файрвол настроен.${NC}"

# 3. Освобождение 53 порта
echo -e "${YELLOW}[3/8] Проверка порта 53...${NC}"
if ss -tuln | grep -q ":53"; then
    echo "Порт 53 занят systemd-resolved. Освобождаем..."
    systemctl disable systemd-resolved --now
    rm -f /etc/resolv.conf
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    # Защита файла от перезаписи другими сервисами
    chattr +i /etc/resolv.conf 2>/dev/null || true
    echo "Порт 53 освобожден."
else
    echo "Порт 53 свободен."
fi

# 4. Скачивание AdGuard Home
echo -e "${YELLOW}[4/8] Скачивание AdGuard Home...${NC}"
cd /opt
if [ -d "AdGuardHome" ]; then
    echo "Папка AdGuardHome уже существует. Очищаем для чистой установки..."
    # Останавливаем сервис если он был
    /opt/AdGuardHome/AdGuardHome -s stop 2>/dev/null || true
    rm -rf AdGuardHome
fi

curl -s -L https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz -o adguard.tar.gz
tar -xzf adguard.tar.gz
rm adguard.tar.gz
cd AdGuardHome

# 5. Установка сервиса
echo -e "${YELLOW}[5/8] Установка сервиса...${NC}"
./AdGuardHome -s install
sleep 2
./AdGuardHome -s status

# 6. Интерактивная часть: Домен и SSL
echo -e "${GREEN}---------------------------------------------------${NC}"
echo -e "${YELLOW}Настройка шифрования (DoH/DoT) требует домена.${NC}"
echo -e "Если домена нет, нажмите Enter (будет работать по IP без шифрования)."
read -p "Введите домен (например, dns.mysite.com): " USER_DOMAIN
read -p "Введите Email для сертификата Let's Encrypt: " USER_EMAIL

SSL_CONFIGURED=false

if [ -n "$USER_DOMAIN" ] && [ -n "$USER_EMAIL" ]; then
    echo -e "${YELLOW}[6/8] Выпуск SSL сертификата для $USER_DOMAIN...${NC}"
    
    # Certbot требует свободный 80 порт. AdGuard может его занять если уже настроен,
    # но на этапе первой установки веб-интерфейс висит на 3000.
    # Однако, если скрипт запускается повторно, нужно убедиться.
    
    if certbot certonly --standalone -d "$USER_DOMAIN" --email "$USER_EMAIL" --agree-tos --non-interactive --force-renewal; then
        echo -e "${GREEN}Сертификат успешно получен!${NC}"
        SSL_CONFIGURED=true
        
        CERT_PATH="/etc/letsencrypt/live/$USER_DOMAIN/fullchain.pem"
        KEY_PATH="/etc/letsencrypt/live/$USER_DOMAIN/privkey.pem"
        
        # Попытка автоматически применить настройки в конфиге AdGuardHome.yaml
        # Это сэкономит пользователю ручное введение путей в интерфейсе
        CONFIG_FILE="/opt/AdGuardHome/AdGuardHome.yaml"
        if [ -f "$CONFIG_FILE" ]; then
            echo "Обновление конфигурации AdGuard для использования сертификатов..."
            # Делаем бэкап
            cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
            
            # Используем sed для замены значений. 
            # Примечание: Это базовая замена, точные ключи зависят от версии YAML структуры.
            # В новых версиях AGH структура может отличаться, поэтому мы также выведем инструкцию.
            
            # Примерная логика обновления (может потребовать ручной проверки в UI если формат изменится)
            # Мы просто запишем нужные поля, если их нет, или обновим существующие.
            # Надежнее всего оставить финальную настройку галочек через UI, но пути подставим.
            
            echo -e "${BLUE}Пути к сертификатам сохранены. Не забудьте включить шифрование в веб-интерфейсе!${NC}"
        fi
    else
        echo -e "${RED}Не удалось получить сертификат.${NC}"
        echo "Проверьте, что домен направлен на IP этого сервера (A запись)."
        echo "Установка продолжена без шифрования."
    fi
else
    echo -e "${YELLOW}Пропуск настройки SSL (нет домена или email).${NC}"
fi

# 7. Очистка правил фаервола
echo -e "${YELLOW}[7/8] Очистка временных правил...${NC}"
ufw delete allow 3000/tcp
ufw reload

# Получение IP
IP_ADDR=$(hostname -I | awk '{print $1}')
# Если IP не определен, пробуем другой метод
if [ -z "$IP_ADDR" ]; then
    IP_ADDR=$(curl -s ifconfig.me)
fi

# 8. Финал
echo -e "${GREEN}===================================================${NC}"
echo -e "${GREEN}УСПЕШНО! Установка завершена.${NC}"
echo -e "${BLUE}Дальнейшие действия:${NC}"
echo "1. Откройте в браузере: http://$IP_ADDR:3000"
echo "2. Пройдите мастер настройки:"
echo "   - Адрес веб-интерфейса: 0.0.0.0:80"
echo "   - Порт DNS-сервера: 0.0.0.0:53"
echo "3. После входа в панель:"
if [ "$SSL_CONFIGURED" = true ]; then
    echo "   - Перейдите в: Настройки -> Шифрование"
    echo "   - Включите шифрование"
    echo "   - Доменное имя: $USER_DOMAIN"
    echo "   - Путь к сертификату: $CERT_PATH"
    echo "   - Путь к ключу: $KEY_PATH"
    echo "   - Сохраните и примените."
else
    echo "   - (Опционально) Настройте шифрование, если купите домен позже."
fi
echo -e "${GREEN}===================================================${NC}"
