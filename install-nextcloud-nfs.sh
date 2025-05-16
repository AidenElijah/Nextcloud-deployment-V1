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
 php-bcmath php-gmp php-imagick unzip wget nfs-common

# Nextcloud downloaden
wget https://download.nextcloud.com/server/releases/latest.zip
unzip latest.zip
sudo mv nextcloud "$NEXTCLOUD_DIR"
sudo chown -R www-data:www-data "$NEXTCLOUD_DIR"

# NFS mount directory aanmaken
sudo mkdir -p "$MOUNT_POINT"
sudo chown -R www-data:www-data "$MOUNT_POINT"

# NFS mount configureren
echo "$STORAGE_ACCOUNT_NAME.blob.core.windows.net:/$CONTAINER_NAME $MOUNT_POINT nfs vers=3,proto=tcp,nolock,hard,timeo=600,retrans=2 0 0" | sudo tee -a /etc/fstab
sudo mount -a

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
