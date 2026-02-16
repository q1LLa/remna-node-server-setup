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
echo -e "${BLUE}[1/9] Проверка базового ПО...${RESET}"
if dpkg -s nano fail2ban curl lsof &>/dev/null; then
    echo -e "${YELLOW}Базовый софт уже установлен.${RESET}"
else
    echo -e "${MAGENTA}Установка системных пакетов...${RESET}"
    sudo apt-get update
    sudo apt-get install -y nano fail2ban curl lsof
fi

# --- 2. BBR ---
echo -e "\n${BLUE}[2/9] Проверка BBR...${RESET}"
if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo -e "${YELLOW}BBR уже активен.${RESET}"
else
    echo -e "${MAGENTA}Включение BBR...${RESET}"
    echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p
fi

# --- 3. Docker ---
echo -e "\n${BLUE}[3/9] Проверка Docker...${RESET}"
if command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker уже установлен.${RESET}"
else
    echo -e "${MAGENTA}Установка Docker...${RESET}"
    sudo curl -fsSL https://get.docker.com | sh
fi

# --- 4. Настройка ноды ---
echo -e "\n${BLUE}[4/9] Настройка ноды и Docker Compose...${RESET}"
sudo mkdir -p /var/log/remnanode /opt/remnanode
COMPOSE_FILE="/opt/remnanode/docker-compose.yml"

get_current_key() {
    [ -f "$COMPOSE_FILE" ] && grep "SECRET_KEY=" "$COMPOSE_FILE" | cut -d'"' -f2
}

CURRENT_KEY=$(get_current_key)

if [ -f "$COMPOSE_FILE" ] && [ "$CURRENT_KEY" == "$USER_SECRET_KEY" ]; then
    echo -e "${YELLOW}Конфигурация актуальна, ключ совпадает.${RESET}"
else
    echo -e "${MAGENTA}Запись конфигурации в $COMPOSE_FILE...${RESET}"
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

echo -e "${CYAN}Запуск контейнера remnanode...${RESET}"
cd /opt/remnanode && sudo docker compose up -d

# --- 5. Настройка UFW ---
echo -e "\n${BLUE}[5/9] Настройка Firewall (UFW)...${RESET}"
if sudo ufw status | grep -q "2222/tcp"; then
    echo -e "${YELLOW}Правила UFW уже настроены.${RESET}"
else
    echo -e "${MAGENTA}Применение правил UFW и NAT...${RESET}"
    sudo ufw allow 22,443,9443,40000,8443,4443,3444,2222,8388,3443,2443,1443/tcp
    sudo sed -i 's/#net\/ipv4\/ip_forward=1/net\/ipv4\/ip_forward=1/g' /etc/ufw/sysctl.conf
    grep -q "net/ipv4/ip_forward=1" /etc/ufw/sysctl.conf || echo 'net/ipv4/ip_forward=1' >> /etc/ufw/sysctl.conf
    if ! grep -q "PREROUTING -p tcp --dport 443" /etc/ufw/before.rules; then
        echo -e "\n*nat\n:PREROUTING ACCEPT [0:0]\n-A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 9443\nCOMMIT" | sudo tee -a /etc/ufw/before.rules > /dev/null
    fi
    sudo ufw --force enable
fi

# --- 6. Установка WARP ---
echo -e "\n${BLUE}[6/9] Проверка Cloudflare WARP...${RESET}"
WARP_CHECK=$(curl --socks5-hostname 127.0.0.1:40000 -m 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "warp=on" || true)
if [ "$WARP_CHECK" == "warp=on" ]; then
    echo -e "${YELLOW}WARP активен на порту 40000.${RESET}"
else
    echo -e "${MAGENTA}Установка или перезапуск WARP...${RESET}"
    cd ~
    printf "1\n1\n40000\n" | bash <(curl -fsSL https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh) w
fi

# --- 7. Установка Блокера ---
echo -e "\n${BLUE}[7/9] Проверка T-Blocker...${RESET}"
if systemctl is-active --quiet tblocker; then
    echo -e "${YELLOW}Служба tblocker уже запущена.${RESET}"
else
    echo -e "${MAGENTA}Запуск установки T-Blocker...${RESET}"
    wait_for_apt
    printf "/var/log/remnanode/access.log\ny\n1\n" | bash <(curl -fsSL git.new/install)
fi

# --- 8. Вебхук Блокера ---
echo -e "\n${BLUE}[8/9] Проверка конфигурации Webhook...${RESET}"
if [ -f "/opt/tblocker/config.yaml" ]; then
    if grep -q "WebhookURL: \"$USER_WEBHOOK_URL\"" /opt/tblocker/config.yaml; then
         echo -e "${YELLOW}Webhook в конфиге актуален.${RESET}"
    else
         echo -e "${MAGENTA}Обновление данных Webhook в config.yaml...${RESET}"
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
    echo -e "${RED}[ВНИМАНИЕ] Файл конфигурации /opt/tblocker/config.yaml не найден.${RESET}"
fi

# --- 9. Настройка Logrotate ---
echo -e "\n${BLUE}[9/9] Настройка Logrotate...${RESET}"
if [ -f "/etc/logrotate.d/remnanode" ]; then
    echo -e "${YELLOW}Logrotate для ноды уже настроен.${RESET}"
else
    echo -e "${MAGENTA}Создание конфигурации Logrotate...${RESET}"
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
