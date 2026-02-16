#!/bin/bash

# Отключаем немедленный выход при ошибке
set +e 

# Цвета для вывода
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
RED="\e[31m"
RESET="\e[0m"

# --- Функция ожидания APT ---
wait_for_apt() {
    if fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; then
        echo -e "${BLUE}[ИНФО]${RESET} Система занята обновлением. Ожидание освобождения apt..."
        while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; do
            sleep 5
        done
    fi
}

# --- 0. Запрос данных ---
echo -e "${CYAN}=== Сбор конфигурационных данных ===${RESET}"
echo -ne "${GREEN}[?]${RESET} Введите SECRET_KEY: "
read -r USER_SECRET_KEY
echo -ne "${GREEN}[?]${RESET} Введите URL Webhook: "
read -r USER_WEBHOOK_URL
echo -ne "${GREEN}[?]${RESET} Введите TOKEN (tk_...): "
read -r USER_TOKEN

if [ -z "$USER_SECRET_KEY" ] || [ -z "$USER_WEBHOOK_URL" ] || [ -z "$USER_TOKEN" ]; then
    echo -e "${RED}[ОШИБКА]${RESET} Данные не введены. Перезапустите скрипт."
    exit 1
fi

echo -e "\n${CYAN}=== Начало настройки системы ===${RESET}"

# --- 1. Обновление и софт ---
wait_for_apt
echo -ne "${BLUE}[1/9]${RESET} Проверка базового ПО... "
if dpkg -s nano fail2ban curl lsof &>/dev/null; then
    echo -e "${YELLOW}Установлено${RESET}"
else
    echo -e "${MAGENTA}Установка...${RESET}"
    sudo apt-get update >/dev/null
    sudo apt-get install -y nano fail2ban curl lsof >/dev/null
fi

# --- 2. BBR ---
echo -ne "${BLUE}[2/9]${RESET} Проверка BBR... "
if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo -e "${YELLOW}Активен${RESET}"
else
    echo -e "${MAGENTA}Настройка...${RESET}"
    echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf >/dev/null
    sudo sysctl -p >/dev/null
fi

# --- 3. Docker ---
echo -ne "${BLUE}[3/9]${RESET} Проверка Docker... "
if command -v docker &> /dev/null; then
    echo -e "${YELLOW}Установлен${RESET}"
else
    echo -e "${MAGENTA}Установка...${RESET}"
    sudo curl -fsSL https://get.docker.com | sh >/dev/null
fi

# --- 4. Настройка ноды ---
echo -ne "${BLUE}[4/9]${RESET} Синхронизация ноды... "
sudo mkdir -p /var/log/remnanode /opt/remnanode
COMPOSE_FILE="/opt/remnanode/docker-compose.yml"

get_current_key() {
    [ -f "$COMPOSE_FILE" ] && grep "SECRET_KEY=" "$COMPOSE_FILE" | cut -d'"' -f2
}

CURRENT_KEY=$(get_current_key)

if [ -f "$COMPOSE_FILE" ] && [ "$CURRENT_KEY" == "$USER_SECRET_KEY" ]; then
    echo -e "${YELLOW}Конфигурация актуальна${RESET}"
else
    echo -e "${MAGENTA}Обновление docker-compose.yml...${RESET}"
    sudo cat <<EOF > "$COMPOSE_FILE"
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    volumes:
      - "/var/log/remnanode:/var/log/remnanode"
    network_mode: host
    restart: always
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY="$USER_SECRET_KEY"
EOF
fi

# Запуск контейнера
if sudo docker ps --format '{{.Names}}' | grep -q "^remnanode$"; then
    echo -e "      ${CYAN}->${RESET} Контейнер запущен, пересборка (если были изменения)..."
else
    echo -e "      ${CYAN}->${RESET} Запуск контейнера..."
fi
cd /opt/remnanode && sudo docker compose up -d >/dev/null 2>&1

# --- 5. Настройка UFW ---
echo -ne "${BLUE}[5/9]${RESET} Настройка Firewall (UFW)... "
if sudo ufw status | grep -q "2222/tcp"; then
    echo -e "${YELLOW}Правила уже применены${RESET}"
else
    echo -e "${MAGENTA}Настройка портов и NAT...${RESET}"
    sudo ufw allow 22,443,9443,40000,8443,4443,3444,2222,8388,3443,2443,1443/tcp >/dev/null
    sudo sed -i 's/#net\/ipv4\/ip_forward=1/net\/ipv4\/ip_forward=1/g' /etc/ufw/sysctl.conf
    grep -q "net/ipv4/ip_forward=1" /etc/ufw/sysctl.conf || echo 'net/ipv4/ip_forward=1' >> /etc/ufw/sysctl.conf
    if ! grep -q "PREROUTING -p tcp --dport 443" /etc/ufw/before.rules; then
        echo -e "\n*nat\n:PREROUTING ACCEPT [0:0]\n-A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 9443\nCOMMIT" | sudo tee -a /etc/ufw/before.rules > /dev/null
    fi
    sudo ufw --force enable >/dev/null
fi

# --- 6. Установка WARP ---
echo -ne "${BLUE}[6/9]${RESET} Проверка Cloudflare WARP... "
WARP_CHECK=$(curl --socks5-hostname 127.0.0.1:40000 -m 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "warp=on" || true)
if [ "$WARP_CHECK" == "warp=on" ]; then
    echo -e "${YELLOW}Работает (Port 40000)${RESET}"
else
    echo -e "${MAGENTA}Установка/Перезапуск...${RESET}"
    cd ~
    printf "1\n1\n40000\n" | bash <(curl -fsSL https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh) w >/dev/null 2>&1
fi

# --- 7. Установка Блокера ---
echo -ne "${BLUE}[7/9]${RESET} Проверка T-Blocker... "
if systemctl is-active --quiet tblocker; then
    echo -e "${YELLOW}Запущен${RESET}"
else
    echo -e "${MAGENTA}Установка...${RESET}"
    wait_for_apt
    printf "/var/log/remnanode/access.log\ny\n1\n" | bash <(curl -fsSL git.new/install) >/dev/null 2>&1
fi

# --- 8. Вебхук Блокера ---
echo -ne "${BLUE}[8/9]${RESET} Проверка Webhook конфига... "
if [ -f "/opt/tblocker/config.yaml" ]; then
    if grep -q "WebhookURL: \"$USER_WEBHOOK_URL\"" /opt/tblocker/config.yaml; then
         echo -e "${YELLOW}Актуален${RESET}"
    else
         echo -e "${MAGENTA}Обновление данных...${RESET}"
         sudo sed -i '/SendWebhook:/d;/WebhookURL:/d;/WebhookTemplate:/d;/WebhookHeaders:/d;/Authorization:/d;/Content-Type:/d' /opt/tblocker/config.yaml
         sudo cat <<EOF >> /opt/tblocker/config.yaml
SendWebhook: true
WebhookURL: "$USER_WEBHOOK_URL"
WebhookTemplate: '{"username":"%s","ip":"%s","server":"%s","action":"%s","duration":%d,"timestamp":"%s"}'
WebhookHeaders:
  Authorization: "Bearer $USER_TOKEN"
  Content-Type: "application/json"
EOF
         sudo systemctl restart tblocker
    fi
else
    echo -e "${RED}Файл конфигурации не найден${RESET}"
fi

# --- 9. Настройка Logrotate ---
echo -ne "${BLUE}[9/9]${RESET} Проверка Logrotate... "
if [ -f "/etc/logrotate.d/remnanode" ]; then
    echo -e "${YELLOW}Настроен${RESET}"
else
    echo -e "${MAGENTA}Создание конфига...${RESET}"
    sudo bash -c 'cat > /etc/logrotate.d/remnanode <<EOF
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF'
fi

echo -e "\n${GREEN}=======================================${RESET}"
echo -e "${GREEN}   Настройка завершена успешно!${RESET}"
echo -e "${GREEN}=======================================${RESET}\n"
