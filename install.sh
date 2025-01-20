#!/bin/bash
set -e
apt-get update
apt-get install -y dos2unix
echo "Starting installation process..."

if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <mongodb_username> <mongodb_password> <restricted_username>"
    exit 1
fi

MONGODB_ADMIN=$1
MONGODB_PASSWORD=$2
RESTRICTED_USER=$3

# Original installation process
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

# MongoDB Configuration
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

mkdir -p /var/lib/mongodb
mkdir -p /var/log/mongodb
chown -R mongodb:mongodb /var/lib/mongodb
chown -R mongodb:mongodb /var/log/mongodb
chmod 755 /var/lib/mongodb
chmod 755 /var/log/mongodb

systemctl daemon-reload
systemctl start mongod
systemctl enable mongod
systemctl restart mongod
echo "Waiting for MongoDB to start..."
sleep 5

# Create MongoDB admin user
mongosh admin --eval "
  db.createUser({
    user: '$MONGODB_ADMIN',
    pwd: '$MONGODB_PASSWORD',
    roles: [ { role: 'root', db: 'admin' } ]
  })
"

# Enable MongoDB authentication
sed -i 's/authorization: disabled/authorization: enabled/' /etc/mongod.conf
systemctl restart mongod
sleep 5

# Now create restricted user and set permissions
echo "Creating restricted user..."
useradd -m -s /usr/sbin/nologin "$RESTRICTED_USER"

# Create restricted MongoDB user with minimal permissions
mongosh admin -u "$MONGODB_ADMIN" -p "$MONGODB_PASSWORD" --eval "
  db.createUser({
    user: '$RESTRICTED_USER',
    pwd: '$RESTRICTED_USER-$(openssl rand -hex 4)',
    roles: [
      { role: 'read', db: 'admin' },
      { role: 'readWrite', db: 'forgetDb' }
    ]
  })
"

# Set up restricted execution environment
INSTALL_DIR="/opt/forget-api"
RESTRICTED_DIR="/home/$RESTRICTED_USER/.local/bin"
mkdir -p "$RESTRICTED_DIR"

# Create wrapper script for restricted execution
cat > "$RESTRICTED_DIR/forget-api" << EOF
#!/bin/bash
exec "$INSTALL_DIR/forget-api" "\$@"
EOF

# Set permissions
chmod 500 "$RESTRICTED_DIR/forget-api"
chown root:root "$RESTRICTED_DIR/forget-api"
chattr +i "$RESTRICTED_DIR/forget-api"

# Set up sudoers configuration for restricted user
cat > "/etc/sudoers.d/$RESTRICTED_USER" << EOF
$RESTRICTED_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl status mongod
$RESTRICTED_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart mongod
EOF
chmod 440 "/etc/sudoers.d/$RESTRICTED_USER"

# Clean up
rm latest.deb

echo "Installation and security setup completed successfully!"
echo "Restricted user '$RESTRICTED_USER' has been created with minimal permissions"
echo "The restricted user can:"
echo "  - Execute the application through: $RESTRICTED_DIR/forget-api"
echo "  - Check MongoDB status: sudo systemctl status mongod"
echo "  - Restart MongoDB: sudo systemctl restart mongod"
echo "MongoDB admin connection: mongosh -u $MONGODB_ADMIN -p $MONGODB_PASSWORD --authenticationDatabase admin"
