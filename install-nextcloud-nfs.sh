#!/bin/bash

# Exit bij fout
set -e

# Variabelen
NEXTCLOUD_DIR="/var/www/nextcloud"
STORAGE_ACCOUNT_NAME="ezyinm7lu4klq"
CONTAINER_NAME="nextclouddata"
MOUNT_POINT="/mnt/nextclouddata"
RESOURCE_GROUP="myResourceGroup"
LOCATION="westeurope"

# Updates en vereisten
sudo apt update && sudo apt upgrade -y
sudo apt install -y apache2 mariadb-server libapache2-mod-php \
 php php-mysql php-gd php-xml php-mbstring php-curl php-zip php-intl \
 php-bcmath php-gmp php-imagick unzip wget fuse

# Blobfuse installeren
if ! command -v blobfuse &> /dev/null
then
    wget https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
    sudo dpkg -i packages-microsoft-prod.deb
    sudo apt update
    sudo apt install -y blobfuse
fi

# Maak een directory voor Blobfuse cache
CACHE_DIR="/tmp/blobfusecache"
mkdir -p $CACHE_DIR

# Haal storage account key op
STORAGE_ACCOUNT_KEY=$(az storage account keys list --resource-group $RESOURCE_GROUP --account-name $STORAGE_ACCOUNT_NAME --query '[0].value' -o tsv)

# Maak de mount directory aan en eigendom
sudo mkdir -p "$MOUNT_POINT"
sudo chown -R www-data:www-data "$MOUNT_POINT"

# Maak Blobfuse configuratiebestand aan (met credentials)
CONFIG_FILE="/etc/blobfuse.cfg"
sudo bash -c "cat > $CONFIG_FILE <<EOF
accountName $STORAGE_ACCOUNT_NAME
accountKey $STORAGE_ACCOUNT_KEY
containerName $CONTAINER_NAME
EOF"

sudo chmod 600 $CONFIG_FILE

# Mount Blobfuse (kan ook in fstab, maar hier voor direct mounten)
sudo blobfuse $MOUNT_POINT --config-file=$CONFIG_FILE --log-level=LOG_DEBUG --file-cache-timeout-in-seconds=120 &

# Controleer of gemount
sleep 5
if mountpoint -q $MOUNT_POINT; then
    echo "Blobfuse succesvol gemount op $MOUNT_POINT"
else
    echo "Mounten met Blobfuse mislukt"
    exit 1
fi

# Nextcloud downloaden
wget https://download.nextcloud.com/server/releases/latest.zip
unzip latest.zip
sudo mv nextcloud "$NEXTCLOUD_DIR"
sudo chown -R www-data:www-data "$NEXTCLOUD_DIR"

# MariaDB database en gebruiker aanmaken voor Nextcloud
sudo mysql -e "CREATE DATABASE nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
sudo mysql -e "CREATE USER 'nextclouduser'@'localhost' IDENTIFIED BY 'sterkwachtwoord123';"
sudo mysql -e "GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextclouduser'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# Apache configureren
cat <<EOF | sudo tee /etc/apache2/sites-available/nextcloud.conf
<VirtualHost *:80>
    ServerAdmin admin@example.com
    DocumentRoot $NEXTCLOUD_DIR
    Alias /nextcloud "$NEXTCLOUD_DIR/"

    <Directory $NEXTCLOUD_DIR/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF

# Apache modules activeren en herstarten
sudo a2ensite nextcloud.conf
sudo a2enmod rewrite headers env dir mime ssl
sudo systemctl reload apache2

echo "✅ Installatie voltooid. Open http://<VM-IP>/ om Nextcloud te configureren via de browser."
