#!/bin/bash

# Остановка при любой ошибке
set -e

# --- 0. Запрос данных у пользователя ---
echo -e "\e[32m[?]\e[0m Пожалуйста, введите SECRET_KEY для ноды:"
read -r USER_SECRET_KEY

echo -e "\e[32m[?]\e[0m Пожалуйста, введите URL Webhook (полностью с https://):"
read -r USER_WEBHOOK_URL

echo -e "\e[32m[?]\e[0m Пожалуйста, введите TOKEN (только значение tk_...):"
read -r USER_TOKEN

if [ -z "$USER_SECRET_KEY" ] || [ -z "$USER_WEBHOOK_URL" ] || [ -z "$USER_TOKEN" ]; then
    echo -e "\e[31m[!]\e[0m Ошибка: Все поля должны быть заполнены. Перезапустите скрипт."
    exit 1
fi

echo "--- 1. Обновление системы и установка софта ---"
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y nano fail2ban curl

echo "--- 2. Включение BBR ---"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p
fi

echo "--- 3. Установка Docker ---"
if ! command -v docker &> /dev/null; then
    sudo curl -fsSL https://get.docker.com | sh
fi

echo "--- 4. Настройка ноды (Docker Compose) ---"
sudo mkdir -p /var/log/remnanode /opt/remnanode
cd /opt/remnanode

sudo cat <<EOF > docker-compose.yml
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

sudo docker compose up -d

echo "--- 5. Настройка UFW ---"
sudo ufw allow 22,443,9443,40000,8443,4443,3444,2222,8388,3443,2443,1443/tcp
sudo sed -i 's/#net\/ipv4\/ip_forward=1/net\/ipv4\/ip_forward=1/g' /etc/ufw/sysctl.conf
if ! grep -q "net/ipv4/ip_forward=1" /etc/ufw/sysctl.conf; then
    echo 'net/ipv4/ip_forward=1' >> /etc/ufw/sysctl.conf
fi

if ! grep -q "PREROUTING -p tcp --dport 443" /etc/ufw/before.rules; then
    echo -e "\n*nat\n:PREROUTING ACCEPT [0:0]\n-A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 9443\nCOMMIT" | sudo tee -a /etc/ufw/before.rules > /dev/null
fi
sudo ufw --force enable

echo "--- 6. Установка WARP ---"
cd ~
printf "1\n1\n40000\n" | bash <(curl -fsSL https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh) w

echo "--- 7. Установка Блокера ---"
printf "/var/log/remnanode/access.log\ny\n1\n" | bash <(curl -fsSL git.new/install)

echo "--- 8. Настройка конфига Блокера ---"
sudo cat <<EOF >> /opt/tblocker/config.yaml
SendWebhook: true
WebhookURL: "$USER_WEBHOOK_URL"
WebhookTemplate: '{"username":"%s","ip":"%s","server":"%s","action":"%s","duration":%d,"timestamp":"%s"}'
WebhookHeaders:
  Authorization: "Bearer $USER_TOKEN"
  Content-Type: "application/json"
EOF

sudo systemctl restart tblocker

echo "--- 9. Настройка Logrotate ---"
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

echo -e "\n\e[32m=======================================\e[0m"
echo -e "\e[32mУстановка завершена успешно!\e[0m"
echo -e "\e[32m=======================================\e[0m"
