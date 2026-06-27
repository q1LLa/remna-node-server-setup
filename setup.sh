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

echo -e "\n${CYAN}=== Начало настройки системы ===${RESET}"

# --- 1. Базовое ПО и исправление зависимостей ---
wait_for_apt
echo -e "${BLUE}[1/7] Проверка системных пакетов...${RESET}"
sudo apt-get update
sudo apt --fix-broken install -y
sudo apt-get install -y nano fail2ban curl lsof

# --- 2. Оптимизация сетевых параметров ядра ---
echo -e "\n${BLUE}[2/7] Применение сетевых настроек (BBR, Conntrack)...${RESET}"
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
echo -e "\n${BLUE}[3/7] Проверка Docker...${RESET}"
command -v docker &> /dev/null || sudo curl -fsSL https://get.docker.com | sh

# --- 4. Настройка ноды Remnanode ---
echo -e "\n${BLUE}[4/7] Настройка контейнера ноды...${RESET}"
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
    cap_add:
      - NET_ADMIN
    environment:
      - NODE_PORT=2222
      - SECRET_KEY="$USER_SECRET_KEY"
EOF
cd /opt/remnanode && sudo docker compose up -d

# --- 5. Настройка Firewall (UFW) через ЦИКЛ ---
echo -e "\n${BLUE}[5/7] Настройка UFW...${RESET}"
sudo apt-get install -y ufw

# Сброс настроек по умолчанию (безопасность)
sudo ufw default deny incoming > /dev/null
sudo ufw default allow outgoing > /dev/null

# Список всех нужных портов
PORTS=(22 443 9443 40000 8443 4443 3444 2222 8388 3443 2443 1443 10970 18182 22230 10120)

for port in "${PORTS[@]}"; do
    sudo ufw allow "$port"/tcp > /dev/null
done

# Включение UFW (флаг --force нужен, чтобы скрипт не задавал интерактивный вопрос)
echo -e "${YELLOW}[ИНФО]${RESET} Включение файрвола UFW..."
sudo ufw --force enable

# --- 6. Logrotate ---
echo -e "\n${BLUE}[6/7] Настройка Logrotate...${RESET}"
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

# --- ФИНАЛ ОСНОВНОГО СКРИПТА ---
echo -e "\n${GREEN}=======================================${RESET}"
echo -e "${GREEN}    Базовая настройка завершена!${RESET}"
echo -e "${GREEN}=======================================${RESET}\n"

# --- 7. WARP Native (ФИНАЛЬНЫЙ ШАГ - Интерактивно) ---
echo -e "${BLUE}[7/7] Запуск установки WARP Native...${RESET}"
echo -e "${YELLOW}(После завершения установки WARP настройка будет полностью закончена)${RESET}"
bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh)
