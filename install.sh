#!/bin/bash
set -e

apt-get update
apt-get install -y dos2unix

echo "Starting installation process..."

if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <username> <password>"
    exit 1
fi

MONGODB_ADMIN=$1
MONGODB_PASSWORD=$2

apt-get update

apt-get install gnupg curl

curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | \
   sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg \
   --dearmor

echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] http://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main" | tee /etc/apt/sources.list.d/mongodb-org-8.0.list

apt-get update

apt-get install -y mongodb-org

LATEST_DEB=$(curl -s https://api.github.com/repos/DiagonalLokesh/Debian_Package/releases/latest | grep "browser_download_url.*deb" | cut -d '"' -f 4)

if [ -z "$LATEST_DEB" ]; then
    echo "Error: Could not find latest release"
    exit 1
fi

echo "Downloading latest version from: $LATEST_DEB"
wget "$LATEST_DEB" -O latest.deb && apt install -y ./latest.deb

#apt install -y ./forget-api_v1.deb
#wget https://raw.githubusercontent.com/DiagonalLokesh/Debian_Package/main/forget-api_v1.deb && apt install -y ./forget-api_v1.deb

# Step 6: Create MongoDB configuration directory if it doesn't exist
mkdir -p /etc/mongod/

# Step 7: Configure MongoDB
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

# Step 8: Create necessary directories and set permissions
mkdir -p /var/lib/mongodb
mkdir -p /var/log/mongodb
chown -R mongodb:mongodb /var/lib/mongodb
chown -R mongodb:mongodb /var/log/mongodb
chmod 755 /var/lib/mongodb
chmod 755 /var/log/mongodb

# Step 9: Start and enable MongoDB
systemctl daemon-reload
systemctl start mongod
systemctl enable mongod

systemctl restart mongod

echo "Waiting for MongoDB to start..."
sleep 5

# Create admin user
mongosh admin --eval "
  db.createUser({
    user: '$MONGODB_ADMIN',
    pwd: '$MONGODB_PASSWORD',
    roles: [ { role: 'root', db: 'admin' } ]
  })
"

sed -i 's/authorization: disabled/authorization: enabled/' /etc/mongod.conf

echo "MongoDB installation and security setup completed successfully!"
echo "You can now connect to MongoDB using: mongosh -u $MONGODB_ADMIN -p $MONGODB_PASSWORD --authenticationDatabase admin"
