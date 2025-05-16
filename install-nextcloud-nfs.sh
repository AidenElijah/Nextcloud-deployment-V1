#!/bin/bash

set -e

# Parameter verwerking
STORAGE_ACCOUNT_NAME=""
STORAGE_ACCOUNT_KEY=""
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

echo "Start installatie Nextcloud en mount Blobfuse..."

# Systeem update en benodigde pakketten installeren
sudo apt update && sudo apt upgrade -y
sudo apt install -y apache2 mariadb-server libapache2-mod-php \
 php php-mysql php-gd php-xml php-mbstring php-curl php-zip php-intl \
 php-bcmath php-gmp php-imagick unzip wget fuse blobfuse

# Blobfuse cache directory
CACHE_DIR="/tmp/blobfusecache"
mkdir -p $CACHE_DIR

# Maak mount point en stel rechten in
sudo mkdir -p "$MOUNT_POINT"
sudo chown -R www-data:www-data "$MOUNT_POINT"

# Blobfuse configuratiebestand aanmaken
CONFIG_FILE="/etc/blobfuse.cfg"
sudo bash -c "cat > $CONFIG_FILE <<EOF
accountName $STORAGE_ACCOUNT_NAME
accountKey $STORAGE_ACCOUNT_KEY
containerName $CONTAINER_NAME
EOF"

sudo chmod 600 $CONFIG_FILE

# Blobfuse mounten (achtergrond)
sudo blobfuse $MOUNT_POINT --config-file=$CONFIG_FILE --log-level=LOG_DEBUG --file-cache-timeout-in-seconds=120 &

sleep 5

if mountpoint -q $MOUNT_POINT; then
  echo "Blobfuse succesvol gemount op $MOUNT_POINT"
else
  echo "Mounten met Blobfuse mislukt"
  exit 1
fi

# Nextcloud downloaden en installeren
wget https://download.nextcloud.com/server/releases/latest.zip
unzip latest.zip
sudo mv nextcloud /var/www/nextcloud
sudo chown -R www-data:www-data /var/www/nextcloud

# MariaDB configureren
sudo systemctl start mariadb
sudo mysql -e "CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
sudo mysql -e "CREATE USER IF NOT EXISTS 'nextclouduser'@'localhost' IDENTIFIED BY 'sterkwachtwoord123';"
sudo mysql -e "GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextclouduser'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# Apache configuratie voor Nextcloud
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
