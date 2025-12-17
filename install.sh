#!/bin/bash

set -e

echo "شروع نصب و کانفیگ Marzban Emergency Service..."

# --- آپدیت سیستم و نصب پیش نیازها ---
echo "در حال آپدیت سیستم..."
sudo apt update -y
sudo apt upgrade -y

echo "نصب پیش نیازها..."
sudo apt install -y curl wget git unzip python3-pip python3-venv nginx docker.io docker-compose

# فعال کردن و استارت Docker
sudo systemctl enable docker
sudo systemctl start docker

# --- گرفتن اطلاعات از کاربر ---
read -p "آدرس پنل (مثلا example.com): " PANEL_ADDRESS
read -p "پورت پنل: " PANEL_PORT
read -p "نام کاربری ادمین: " ADMIN_USER
read -sp "پسورد ادمین: " ADMIN_PASS
echo
read -p "مسیر ذخیره فایل‌ سرتیفیکت (cert و key): " CERT_PATH
read -p "مسیر ذخیره فایل‌ پرایوت کی (cert و key): " PRIVKEY_PATH

# --- ساخت مسیرها ---
APP_DIR="/opt/marzban/marzban-emergency"
sudo mkdir -p "$APP_DIR"
sudo mkdir -p /var/lib/marzban
sudo mkdir -p /var/lib/marzban/templates/subscription/

# --- دانلود فایل‌ها از گیت‌هاب ---
echo "در حال دانلود فایل‌ها..."
sudo wget -O "$APP_DIR/Dockerfile" "https://raw.githubusercontent.com/younex65/Marzban-Emergeny-Charge2/refs/heads/main/Dockerfile"
sudo wget -O "$APP_DIR/main.py" "https://raw.githubusercontent.com/younex65/Marzban-Emergeny-Charge2/refs/heads/main/main.py"

# نصب پیش نیازهای پایتون main.py
sudo pip3 install fastapi uvicorn requests pydantic

# --- ساخت فایل .env ---
ENV_FILE="$APP_DIR/.env"
echo "در حال ساخت فایل .env..."
sudo bash -c "cat > $ENV_FILE <<EOL
MARZBAN_BASE_URL=https://127.0.0.1:$PANEL_PORT
MARZBAN_ADMIN_USERNAME=$ADMIN_USER
MARZBAN_ADMIN_PASSWORD=$ADMIN_PASS
MARZBAN_VERIFY_SSL=false
EOL"

# --- ویرایش docker-compose.yml ---
COMPOSE_FILE="/opt/marzban/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ساخت فایل docker-compose.yml جدید..."
    sudo bash -c "cat > $COMPOSE_FILE <<EOL
version: '3'
services:
  marzban:
    image: gozargah/marzban:latest
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - /var/lib/marzban:/var/lib/marzban

  marzban-emergency:
    build: ./marzban-emergency
    restart: always
    env_file: ./marzban-emergency/.env
    network_mode: host
    volumes:
      - ./marzban-emergency:/app
      - /var/lib/marzban:/var/lib/marzban
EOL"
else
    echo "ویرایش docker-compose.yml موجود..."
    # اضافه کردن سرویس marzban-emergency اگر وجود ندارد
    if ! grep -q "marzban-emergency:" "$COMPOSE_FILE"; then
        sudo sed -i '/services:/a \
  marzban-emergency:\n    build: ./marzban-emergency\n    restart: always\n    env_file: ./marzban-emergency/.env\n    network_mode: host\n    volumes:\n      - ./marzban-emergency:/app\n      - /var/lib/marzban:/var/lib/marzban' "$COMPOSE_FILE"
    fi
fi

# --- بالا آوردن داکر ---
echo "در حال بالا آوردن کانتینرها..."
cd /opt/marzban
sudo docker-compose up -d

# --- کانفیگ Nginx ---
NGINX_CONF="/etc/nginx/conf.d/marzban-emergency.conf"
sudo bash -c "cat > $NGINX_CONF <<EOL
server {
    listen 80;
    server_name $PANEL_ADDRESS;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $PANEL_ADDRESS;

    ssl_certificate     $CERT_PATH;
    ssl_certificate_key $PRIVKEY_PATH;

    client_max_body_size 50M;
    proxy_read_timeout   300;
    proxy_connect_timeout 300;
    proxy_send_timeout   300;

    location / {
        proxy_pass https://127.0.0.1:$PANEL_PORT;
        proxy_ssl_verify off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location /emergency/ {
        proxy_pass http://127.0.0.1:5010/emergency/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOL"

# ریستارت Nginx
echo "ریستارت Nginx..."
sudo systemctl restart nginx

# --- دانلود template ---
sudo wget -O /var/lib/marzban/templates/subscription/index.html "https://raw.githubusercontent.com/younex65/Marzban-Emergeny-Charge2/refs/heads/main/index.html"

# --- ریستارت Marzban ---
echo "ریستارت Marzban..."
marzban restart

echo "تمام شد! سرویس Marzban Emergency آماده استفاده است."
echo "برای مشاهده لاگ‌ها: sudo docker-compose logs -f marzban"
