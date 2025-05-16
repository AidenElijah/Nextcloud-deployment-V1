#!/bin/bash

set -e

# Parameters
STORAGE_ACCOUNT_NAME="ezyinm7lu4klq"
STORAGE_ACCOUNT_KEY="Kgc2Hn4IHKqa63aoQnxgVJJf3pet/F0pd7jCh0zgoBuExvu1gD627YWHkURVKUrcKqoca3oqk9rk+ASthXoL6Q=="
CONTAINER_NAME="nextclouddata"
MOUNT_POINT="/mnt/nextclouddata"

function usage() {
  echo "Gebruik: $0 --storage-account-name <name> --storage-account-key <key>"
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --storage-account-name) STORAGE_ACCOUNT_NAME="$2"; shift ;;
    --storage-account-key) STORAGE_ACCOUNT_KEY="$2"; shift ;;
    *) echo "Onbekende parameter: $1"; usage ;;
  esac
  shift
done

if [[ -z "$STORAGE_ACCOUNT_NAME" || -z "$STORAGE_ACCOUNT_KEY" ]]; then
  echo "Fout: zowel --storage-account-name als --storage-account-key moeten worden opgegeven."
  usage
fi

echo "🛠️ Start installatie van Nextcloud en configuratie van Blobfuse2..."

# Update en vereiste pakketten
sudo apt update && sudo apt upgrade -y

# Controleer op pending kernel upgrade en voer reboot uit indien nodig
KERNEL_RUNNING=$(uname -r)
KERNEL_INSTALLED=$(dpkg --status linux-image-azure | grep '^Version:' | awk '{print $2}' | cut -d'-' -f1)

if [[ "$KERNEL_RUNNING" != *"$KERNEL_INSTALLED"* ]]; then
  echo "⚠️ Er is een kernelupgrade pending. Het systeem wordt nu herstart om de nieuwe kernel te laden."
  sudo reboot
  # Het script stopt hier; na reboot moet het opnieuw gestart worden.
fi

sudo apt install -y apt-transport-https ca-certificates curl software-properties-common \
 apache2 mariadb-server unzip wget php php-mysql php-gd php-xml php-mbstring php-curl php-zip php-intl php-bcmath php-gmp php-imagick libfuse2 jq

# Installeer Blobfuse2 vanuit de officiële Microsoft repository
echo "➡️ Installeer Blobfuse2"
wget https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
sudo apt update
sudo apt install -y blobfuse2

# Blobfuse2 configuratie
mkdir -p ~/.blobfuse2
cat <<EOF > ~/.blobfuse2/connection.cfg
accountName: $STORAGE_ACCOUNT_NAME
accountKey: $STORAGE_ACCOUNT_KEY
EOF

cat <<EOF > ~/.blobfuse2/mount.json
{
  "version": 2,
  "logging": {
    "type": "syslog",
    "level": "LOG_DEBUG"
  },
  "components": [
    "wasb",
    "attr_cache"
  ],
  "wasb": {
    "account_name": "$STORAGE_ACCOUNT_NAME",
    "container_name": "$CONTAINER_NAME",
    "account_key": "$STORAGE_ACCOUNT_KEY"
  },
  "attr_cache": {
    "timeout_sec": 120
  }
}
EOF

# Mount directory aanmaken
sudo mkdir -p "$MOUNT_POINT"
sudo chown -R www-data:www-data "$MOUNT_POINT"

# Blobfuse2 mount uitvoeren
echo "➡️ Blobfuse2 mount uitvoeren..."
sudo blobfuse2 mount "$MOUNT_POINT" --config-file ~/.blobfuse2/mount.json &

sleep 5

if mountpoint -q "$MOUNT_POINT"; then
  echo "✅ Blobfuse2 succesvol gemount op $MOUNT_POINT"
else
  echo "❌ Mounten met Blobfuse2 mislukt"
  exit 1
fi

# Nextcloud downloaden en installeren
echo "➡️ Download en installatie van Nextcloud"
wget https://download.nextcloud.com/server/releases/latest.zip
unzip latest.zip
sudo mv nextcloud /var/www/nextcloud
sudo chown -R www-data:www-data /var/www/nextcloud

# MariaDB instellen
echo "➡️ MariaDB configureren"
sudo systemctl start mariadb
sudo mysql -e "CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
sudo mysql -e "CREATE USER IF NOT EXISTS 'nextclouduser'@'localhost' IDENTIFIED BY 'sterkwachtwoord123';"
sudo mysql -e "GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextclouduser'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# Apache configuratie
echo "➡️ Apache configuratie instellen"
cat <<EOF | sudo tee /etc/apache2/sites-available/nextcloud.conf
<VirtualHost *:80>
    ServerAdmin admin@example.com
    DocumentRoot /var/www/nextcloud
    Alias /nextcloud /var/www/nextcloud/

    <Directory /var/www/nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF

sudo a2ensite nextcloud.conf
sudo a2enmod rewrite headers env dir mime ssl
sudo systemctl reload apache2

echo "✅ Installatie voltooid. Open http://<VM-IP>/nextcloud om de configuratie te voltooien."
