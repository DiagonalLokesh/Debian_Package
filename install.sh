#!/bin/bash
set -e

# Install required packages
apt-get update
apt-get install -y dos2unix e2fsprogs openssl

echo "Starting installation process..."

if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <mongodb_username> <mongodb_password>"
    exit 1
fi

MONGODB_ADMIN=$1
MONGODB_PASSWORD=$2

# Install MongoDB and dependencies
apt-get update
apt-get install -y gnupg curl
curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | \
   sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg \
   --dearmor
echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] http://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main" | tee /etc/apt/sources.list.d/mongodb-org-8.0.list
apt-get update
apt-get install -y mongodb-org

# Set up installation directory
INSTALL_DIR="/opt/.forget_api"
mkdir -p "$INSTALL_DIR"

# Download and extract package
LATEST_DEB=$(curl -s https://api.github.com/repos/DiagonalLokesh/Debian_Package/releases/latest | grep "browser_download_url.*deb" | cut -d '"' -f 4)
if [ -z "$LATEST_DEB" ]; then
    echo "Error: Could not find latest release"
    exit 1
fi
echo "Downloading latest version from: $LATEST_DEB"
wget "$LATEST_DEB" -O latest.deb
dpkg -x latest.deb "$INSTALL_DIR"
dpkg -e latest.deb "$INSTALL_DIR/DEBIAN"

# Set directory and file permissions
chmod 700 "$INSTALL_DIR"
find "$INSTALL_DIR" -type f -exec chmod 500 {} \;
find "$INSTALL_DIR" -type d -exec chmod 500 {} \;

# Make files immutable after setting permissions
chattr +i "$INSTALL_DIR"
find "$INSTALL_DIR" -type f -exec chattr +i {} \;
find "$INSTALL_DIR" -type d -exec chattr +i {} \;

# Configure MongoDB
mkdir -p /etc/mongod/
cat > /etc/mongod.conf << EOF
storage:
  dbPath: /var/lib/mongodb
systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true
net:
  port: 27017
  bindIp: 127.0.0.1
security:
  authorization: disabled
EOF

mkdir -p /var/lib/mongodb /var/log/mongodb
chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb
chmod 755 /var/lib/mongodb /var/log/mongodb

systemctl daemon-reload
systemctl start mongod
systemctl enable mongod
systemctl restart mongod
sleep 5

# Set up MongoDB users
mongosh admin --eval "
  db.createUser({
    user: '$MONGODB_ADMIN',
    pwd: '$MONGODB_PASSWORD',
    roles: [ { role: 'root', db: 'admin' } ]
  })
"

sed -i 's/authorization: disabled/authorization: enabled/' /etc/mongod.conf
systemctl restart mongod

# Clean up
rm latest.deb

echo "Installation and security setup completed successfully!"
echo "MongoDB connection for admin: mongosh -u $MONGODB_ADMIN -p $MONGODB_PASSWORD --authenticationDatabase admin"
