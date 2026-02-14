#!/bin/bash

# Отключаем немедленный выход при ошибке, чтобы контролировать логику
set +e 

# --- Функция ожидания APT ---
wait_for_apt() {
    echo -e "\e[34m[ИНФО]\e[0m Проверка блокировок apt..."
    while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; do
        echo "Система занята обновлением. Ожидание 10 секунд..."
        sleep 10
    done
}

# --- 0. Запрос данных ---
echo -e "\e[32m[?]\e[0m Введите SECRET_KEY:"
read -r USER_SECRET_KEY
echo -e "\e[32m[?]\e[0m Введите URL Webhook:"
read -r USER_WEBHOOK_URL
echo -e "\e[32m[?]\e[0m Введите TOKEN (tk_...):"
read -r USER_TOKEN

if [ -z "$USER_SECRET_KEY" ] || [ -z "$USER_WEBHOOK_URL" ] || [ -z "$USER_TOKEN" ]; then
    echo -e "\e[31m[ОШИБКА]\e[0m Данные не введены."
    exit 1
fi

# --- 1. Обновление и софт ---
wait_for_apt
echo "--- 1. Обновление системы и проверка софта ---"
sudo apt-get update
if dpkg -s nano fail2ban curl lsof &>/dev/null; then
    echo -e "\e[33m[ПРОПУСК]\e[0m Базовый софт уже установлен."
else
    sudo apt-get install -y nano fail2ban curl lsof
fi

# --- 2. BBR ---
echo "--- 2. Проверка BBR ---"
if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo -e "\e[33m[ПРОПУСК]\e[0m BBR уже активен."
else
    echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p
fi

# --- 3. Docker ---
echo "--- 3. Проверка Docker ---"
if command -v docker &> /dev/null; then
    echo -e "\e[33m[ПРОПУСК]\e[0m Docker уже установлен."
else
    sudo curl -fsSL https://get.docker.com | sh
fi

# --- 4. Настройка ноды ---
echo "--- 4. Настройка ноды и Docker Compose ---"
sudo mkdir -p /var/log/remnanode /opt/remnanode
COMPOSE_FILE="/opt/remnanode/docker-compose.yml"

# Функция для получения текущего ключа из файла (вырезаем кавычки и пробелы)
get_current_key() {
    [ -f "$COMPOSE_FILE" ] && grep "SECRET_KEY=" "$COMPOSE_FILE" | cut -d'"' -f2
}

CURRENT_KEY=$(get_current_key)

if [ -f "$COMPOSE_FILE" ] && [ "$CURRENT_KEY" == "$USER_SECRET_KEY" ]; then
    echo -e "\e[33m[ПРОПУСК]\e[0m docker-compose.yml существует и ключ полностью совпадает."
else
    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "\e[35m[ВНИМАНИЕ]\e[0m Ключ в файле отсутствует или отличается! Перезаписываю..."
    else
        echo "Создание нового docker-compose.yml..."
    fi
    
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

# Проверка запущенного контейнера
if sudo docker ps --format '{{.Names}}' | grep -q "^remnanode$"; then
    echo -e "\e[33m[ПРОПУСК]\e[0m Контейнер remnanode уже запущен. Обновление контейнера..."
    cd /opt/remnanode && sudo docker compose up -d
else
    cd /opt/remnanode && sudo docker compose up -d
fi

# --- 5. Настройка UFW ---
echo "--- 5. Настройка UFW ---"
if sudo ufw status | grep -q "2222/tcp"; then
    echo -e "\e[33m[ПРОПУСК]\e[0m Правила UFW уже настроены."
else
    sudo ufw allow 22,443,9443,40000,8443,4443,3444,2222,8388,3443,2443,1443/tcp
    sudo sed -i 's/#net\/ipv4\/ip_forward=1/net\/ipv4\/ip_forward=1/g' /etc/ufw/sysctl.conf
    grep -q "net/ipv4/ip_forward=1" /etc/ufw/sysctl.conf || echo 'net/ipv4/ip_forward=1' >> /etc/ufw/sysctl.conf
    if ! grep -q "PREROUTING -p tcp --dport 443" /etc/ufw/before.rules; then
        echo -e "\n*nat\n:PREROUTING ACCEPT [0:0]\n-A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 9443\nCOMMIT" | sudo tee -a /etc/ufw/before.rules > /dev/null
    fi
    sudo ufw --force enable
fi

# --- 6. Установка WARP ---
echo "--- 6. Проверка WARP ---"
WARP_CHECK=$(curl --socks5-hostname 127.0.0.1:40000 -m 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "warp=on" || true)
if [ "$WARP_CHECK" == "warp=on" ]; then
    echo -e "\e[33m[ПРОПУСК]\e[0m WARP уже работает и активен на порту 40000."
else
    echo "Установка/перенастройка WARP..."
    cd ~
    printf "1\n1\n40000\n" | bash <(curl -fsSL https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh) w
fi

# --- 7. Установка Блокера ---
echo "--- 7. Проверка Блокера ---"
if systemctl is-active --quiet tblocker; then
    echo -e "\e[33m[ПРОПУСК]\e[0m Служба tblocker уже запущена."
else
    wait_for_apt
    printf "/var/log/remnanode/access.log\ny\n1\n" | bash <(curl -fsSL git.new/install)
fi

# Настройка конфига (проверка Webhook)
if [ -f "/opt/tblocker/config.yaml" ]; then
    if grep -q "WebhookURL: \"$USER_WEBHOOK_URL\"" /opt/tblocker/config.yaml; then
         echo -e "\e[33m[ПРОПУСК]\e[0m Конфиг Блокера уже содержит актуальный Webhook."
    else
         echo "Обновление Webhook в конфиге Блокера..."
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
fi

# --- 9. Настройка Logrotate ---
echo "--- 9. Настройка Logrotate ---"
if [ -f "/etc/logrotate.d/remnanode" ]; then
    echo -e "\e[33m[ПРОПУСК]\e[0m Logrotate для remnanode уже настроен."
else
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
    echo "Logrotate настроен."
fi

echo -e "\n\e[32m=======================================\e[0m"
echo -e "\e[32mПроверка и установка завершены успешно!\e[0m"
echo -e "\e[32m=======================================\e[0m"
