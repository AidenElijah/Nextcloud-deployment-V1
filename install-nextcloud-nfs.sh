#!/bin/bash

# Exit script bij fout en traceer uitvoer
set -euo pipefail
IFS=$'\n\t'

# --- Configuratievariabelen (pas aan of geef door als parameters) ---
NEXTCLOUD_DIR="/var/www/nextcloud"
STORAGE_ACCOUNT_NAME="ezyinm7lu4klq"
CONTAINER_NAME="nextclouddata"
MOUNT_POINT="/mnt/nextclouddata"
RESOURCE_GROUP="myResourceGroup"
LOCATION="westeurope"
DB_NAME="nextcloud"
DB_USER="nextclouduser"
DB_PASS="${1:-sterkwachtwoord123}"  # wachtwoord via eerste argument, default als fallback

# Controleer vereiste commando's
function check_command {
  if ! command -v "$1" &> /dev/null; then
    echo "Fout: Vereist commando '$1' is niet geïnstalleerd of niet in PATH."
    exit 1
  fi
}

check_command az
check_command wget
check_command mysql

echo "✅ Vereiste tools aanwezig."

# Systeem updaten en benodigde pakketten installeren
sudo apt update && sudo apt upgrade -y
sudo apt install -y apache2 mariadb-server libapache2-mod-php \
php php-mysql php-gd php-xml php-mbstring php-curl php-zip php-intl \
php-bcmath php-gmp php-imagick unzip wget fuse

# Blobfuse installeren indien nog niet geïnstalleerd
if ! command -v blobfuse &> /dev/null
then
    echo "Blobfuse niet gevonden, installatie wordt gestart..."
    wget https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
    sudo dpkg -i packages-microsoft-prod.deb
    rm -f packages-microsoft-prod.deb
    sudo apt update
    sudo apt install -y blobfuse
    echo "Blobfuse is succesvol geïnstalleerd."
else
    echo "Blobfuse is al geïnstalleerd."
fi

# Cache directory voor Blobfuse aanmaken
CACHE_DIR="/tmp/blobfusecache"
mkdir -p "$CACHE_DIR"

# Storage account key ophalen via Azure CLI
echo "Ophalen storage account key..."
STORAGE_ACCOUNT_KEY=$(az storage account keys list --resource-group "$RESOURCE_GROUP" --account-name "$STORAGE_ACCOUNT_NAME" --query '[0].value' -o tsv)

if [ -z "$STORAGE_ACCOUNT_KEY" ]; then
  echo "Fout: Storage account key kon niet worden opgehaald."
  exit 1
fi

# Blobfuse configuratiebestand aanmaken
CONFIG_FILE="/etc/blobfuse.cfg"
sudo bash -c "cat > $CONFIG_FILE <<EOF
accountName $STORAGE_ACCOUNT_NAME
accountKey $STORAGE_ACCOUNT_KEY
containerName $CONTAINER_NAME
EOF"

sudo chmod 600 "$CONFIG_FILE"
echo "Blobfuse configuratiebestand aangemaakt."

# Mount directory aanmaken en juiste rechten toewijzen
sudo mkdir -p "$MOUNT_POINT"
sudo chown -R www-data:www-data "$MOUNT_POINT"

# Mounten Blobfuse (foreground voor betere controle)
echo "Mounten van Blobfuse op $MOUNT_POINT..."
sudo blobfuse "$MOUNT_POINT" --config-file="$CONFIG_FILE" --log-level=LOG_DEBUG --file-cache-timeout-in-seconds=120

# Controleer of Blobfuse succesvol is gemount
if mountpoint -q "$MOUNT_POINT"; then
    echo "Blobfuse succesvol gemount op $MOUNT_POINT"
else
    echo "Fout: Blobfuse mount mislukt."
    exit 1
fi

# Nextcloud downloaden en installeren
echo "Downloaden en uitpakken Nextcloud..."
wget https://download.nextcloud.com/server/releases/latest.zip -O latest.zip
unzip -o latest.zip
rm -f latest.zip

sudo mv nextcloud "$NEXTCLOUD_DIR"
sudo chown -R www-data:www-data "$NEXTCLOUD_DIR"

# Database en gebruiker aanmaken voor Nextcloud
echo "Configureren MariaDB database en gebruiker..."
sudo mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
sudo mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
sudo mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# Apache configuratie voor Nextcloud aanmaken
echo "Configureren Apache voor Nextcloud..."
sudo bash -c "cat > /etc/apache2/sites-available/nextcloud.conf <<EOF
<VirtualHost *:80>
    ServerAdmin admin@example.com
    DocumentRoot $NEXTCLOUD_DIR
    Alias /nextcloud $NEXTCLOUD_DIR/

    <Directory $NEXTCLOUD_DIR/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF"

sudo a2ensite nextcloud.conf
sudo a2enmod rewrite headers env dir mime ssl
sudo systemctl reload apache2

# Optioneel: HTTPS instellen met Certbot (indien domein beschikbaar)
# echo "Overweeg HTTPS te configureren met Certbot (Let's Encrypt)."

echo "✅ Installatie voltooid. Open http://<VM-IP>/nextcloud om Nextcloud via de browser te configureren."
