#!/bin/bash
set -e
apt-get update
apt-get install -y dos2unix e2fsprogs
echo "Starting installation process..."

if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <mongodb_username> <mongodb_password> <client_username>"
    exit 1
fi

MONGODB_ADMIN=$1
MONGODB_PASSWORD=$2
CLIENT_USERNAME=$3

# Create system group for access control
groupadd -f restricted_exec

# Create client user with restricted shell and custom group
useradd -m -s /usr/sbin/nologin -G restricted_exec "$CLIENT_USERNAME"
CLIENT_HOME="/home/$CLIENT_USERNAME"
echo "Created restricted user: $CLIENT_USERNAME"

# Create hidden directory with special naming
INSTALL_DIR="$CLIENT_HOME/.system_required_$(head -c 8 /dev/urandom | xxd -p)"
mkdir -p "$INSTALL_DIR"

apt-get update
apt-get install gnupg curl
curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | \
   sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg \
   --dearmor
echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] http://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main" | tee /etc/apt/sources.list.d/mongodb-org-8.0.list
apt-get update
apt-get install -y mongodb-org

# Download and extract package
LATEST_DEB=$(curl -s https://api.github.com/repos/DiagonalLokesh/Debian_Package/releases/latest | grep "browser_download_url.*deb" | cut -d '"' -f 4)
if [ -z "$LATEST_DEB" ]; then
    echo "Error: Could not find latest release"
    exit 1
fi
echo "Downloading latest version from: $LATEST_DEB"
wget "$LATEST_DEB" -O latest.deb

# Extract deb contents
dpkg-deb -x latest.deb "$INSTALL_DIR"
dpkg-deb -e latest.deb "$INSTALL_DIR/DEBIAN"

# Register package
dpkg -i latest.deb

# Create executable wrapper script
WRAPPER_DIR="/usr/local/bin"
WRAPPER_SCRIPT="$WRAPPER_DIR/forget_api_wrapper"

cat > "$WRAPPER_SCRIPT" << 'EOF'
#!/bin/bash
if [ -n "$SUDO_USER" ]; then
    echo "This application cannot be run with sudo"
    exit 1
fi
exec "$INSTALL_DIR/opt/forget-api/forget-api" "$@"
EOF

# Set permissions and make files immutable
chmod 711 "$INSTALL_DIR"
find "$INSTALL_DIR" -type f -exec chmod 500 {} \;
find "$INSTALL_DIR" -type d -exec chmod 711 {} \;
chmod 555 "$WRAPPER_SCRIPT"

# Set extended file attributes
find "$INSTALL_DIR" -type f -exec chattr +i {} \;
find "$INSTALL_DIR" -type d -exec chattr +i {} \;
chattr +i "$WRAPPER_SCRIPT"

# Create sudoers rule to prevent specific directory access
cat > /etc/sudoers.d/forget_api << EOF
# Block access to installation directory even with sudo
$CLIENT_USERNAME ALL=(ALL) !${INSTALL_DIR}, !${INSTALL_DIR}/*, /usr/bin/systemctl status mongodb, /usr/bin/systemctl restart mongodb
EOF
chmod 440 /etc/sudoers.d/forget_api

# MongoDB configuration
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

mongosh admin --eval "
  db.createUser({
    user: '$MONGODB_ADMIN',
    pwd: '$MONGODB_PASSWORD',
    roles: [ { role: 'root', db: 'admin' } ]
  })
"

sed -i 's/authorization: disabled/authorization: enabled/' /etc/mongod.conf
rm latest.deb

echo "Installation completed successfully!"
echo "Client user '$CLIENT_USERNAME' has been created with restricted permissions"
echo "Installation directory: $INSTALL_DIR"
echo "Execute the application using: forget_api_wrapper"
echo "MongoDB connection: mongosh -u $MONGODB_ADMIN -p $MONGODB_PASSWORD --authenticationDatabase admin"
