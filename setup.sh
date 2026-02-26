#!/bin/bash

# Отключаем немедленный выход при ошибке
set +e 

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
RED='\033[0;31m'
RESET='\033[0m'

wait_for_apt() {
    if fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; then
        echo -e "${BLUE}[ИНФО]${RESET} Ожидание освобождения apt..."
        while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; do
            sleep 5
        done
    fi
}

# --- 0. Сбор данных ---
echo -e "${CYAN}=== Сбор конфигурационных данных ===${RESET}"
echo -ne "${GREEN}[?]${RESET} Введите SECRET_KEY: "
read -r USER_SECRET_KEY
echo -ne "${GREEN}[?]${RESET} Введите URL Webhook: "
read -r USER_WEBHOOK_URL
echo -ne "${GREEN}[?]${RESET} Введите TOKEN: "
read -r USER_TOKEN

echo -e "\n${CYAN}=== Начало настройки системы ===${RESET}"

# --- 1. Базовое ПО и исправление зависимостей ---
wait_for_apt
echo -e "${BLUE}[1/9] Проверка системных пакетов...${RESET}"
sudo apt-get update
sudo apt --fix-broken install -y
sudo apt-get install -y nano fail2ban curl lsof

# --- 2. Оптимизация сетевых параметров ядра ---
echo -e "\n${BLUE}[2/9] Применение сетевых настроек (BBR, Conntrack)...${RESET}"
sudo bash -c 'cat >> /etc/sysctl.conf <<EOF

# Настройки для VPN ноды
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.netfilter.nf_conntrack_max = 500000
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 20000
EOF'
sudo sysctl -p

# --- 3. Docker ---
echo -e "\n${BLUE}[3/9] Проверка Docker...${RESET}"
command -v docker &> /dev/null || sudo curl -fsSL https://get.docker.com | sh

# --- 4. Настройка ноды Remnanode ---
echo -e "\n${BLUE}[4/9] Настройка контейнера ноды...${RESET}"
sudo mkdir -p /var/log/remnanode /opt/remnanode
COMPOSE_FILE="/opt/remnanode/docker-compose.yml"
sudo cat <<EOF > "$COMPOSE_FILE"
services:
  remnanode:
    container_name: remnanode
    image: remnawave/node:latest
    volumes:
      - "/var/log/remnanode:/var/log/remnanode"
    network_mode: host
    restart: always
    environment:
      - NODE_PORT=2222
      - SECRET_KEY="$USER_SECRET_KEY"
EOF
cd /opt/remnanode && sudo docker compose up -d

# --- 5. Настройка Firewall (UFW) через ЦИКЛ ---
echo -e "\n${BLUE}[5/9] Настройка UFW...${RESET}"
sudo apt-get install -y ufw

# Список всех нужных портов
PORTS=(22 443 9443 40000 8443 4443 3444 2222 8388 3443 2443 1443 10970 18182 22230 10120)

for port in "${PORTS[@]}"; do
    sudo ufw allow "$port"/tcp > /dev/null
done
sudo ufw allow 51820/udp > /dev/null # Порт для WireGuard/WARP

# Настройка форвардинга и NAT
sudo sed -i 's/#net\/ipv4\/ip_forward=1/net\/ipv4\/ip_forward=1/g' /etc/ufw/sysctl.conf
grep -q "net/ipv4/ip_forward=1" /etc/ufw/sysctl.conf || echo 'net/ipv4/ip_forward=1' | sudo tee -a /etc/ufw/sysctl.conf

if ! grep -q "PREROUTING -p tcp --dport 443" /etc/ufw/before.rules; then
    echo -e "\n*nat\n:PREROUTING ACCEPT [0:0]\n-A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 9443\nCOMMIT" | sudo tee -a /etc/ufw/before.rules > /dev/null
fi
sudo ufw --force enable

# --- 6. Установка T-Blocker ---
echo -e "\n${BLUE}[6/9] Установка T-Blocker...${RESET}"
if ! systemctl is-active --quiet tblocker; then
    printf "/var/log/remnanode/access.log\ny\n1\n" | bash <(curl -fsSL git.new/install)
fi

# --- 7. Настройка Webhook для Блокера ---
echo -e "\n${BLUE}[7/9] Настройка Webhook...${RESET}"
if [ -f "/opt/tblocker/config.yaml" ]; then
    sudo sed -i '/SendWebhook:/d;/WebhookURL:/d;/WebhookTemplate:/d;/WebhookHeaders:/d;/Authorization:/d;/Content-Type:/d' /opt/tblocker/config.yaml
    sudo bash -c "cat <<EOF >> /opt/tblocker/config.yaml
SendWebhook: true
WebhookURL: \"$USER_WEBHOOK_URL\"
WebhookTemplate: '{\"username\":\"%s\",\"ip\":\"%s\",\"server\":\"%s\",\"action\":\"%s\",\"duration\":%d,\"timestamp\":\"%s\"}'
WebhookHeaders:
  Authorization: \"Bearer $USER_TOKEN\"
  Content-Type: \"application/json\"
EOF"
    sudo systemctl restart tblocker
fi

# --- 8. Logrotate ---
echo -e "\n${BLUE}[8/9] Настройка Logrotate...${RESET}"
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

# --- 9. WARP Native (ФИНАЛЬНЫЙ ШАГ) ---
echo -e "\n${BLUE}[9/9] Установка WARP Native (Интерактивно)...${RESET}"

# Запуск инсталлера
bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh)

echo -e "\n${GREEN}=======================================${RESET}"
echo -e "${GREEN}    Все задачи выполнены!${RESET}"
echo -e "${GREEN}=======================================${RESET}\n"
