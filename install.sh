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
    echo "Usage: $0 <mongodb_username> <mongodb_password> <client_username>"
    exit 1
fi

MONGODB_ADMIN=$1
MONGODB_PASSWORD=$2
CLIENT_USERNAME=$3
INSTALL_DIR="/opt/.forget_api"

# Create restricted client user
if id "$CLIENT_USERNAME" &>/dev/null; then
    echo "User $CLIENT_USERNAME already exists"
else
    useradd -m -s /bin/bash "$CLIENT_USERNAME"
    echo "Created user: $CLIENT_USERNAME"
fi

# Create installation directory
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

# Register package with dpkg
dpkg -i latest.deb

# Set strict permissions on installation directory
chown -R root:root "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 755 {} \;
find "$INSTALL_DIR" -type f -exec chmod 755 {} \;

# Create execution script directory
SCRIPT_DIR="/usr/local/bin"
mkdir -p "$SCRIPT_DIR"

# Create wrapper script for client execution
cat > "$SCRIPT_DIR/forget_api" << EOF
#!/bin/bash
$INSTALL_DIR/usr/bin/forget_api "\$@"
EOF

chmod 755 "$SCRIPT_DIR/forget_api"
chown root:root "$SCRIPT_DIR/forget_api"

# Add client user to necessary group and set sudo permissions for specific script
groupadd -f forget_api_users
usermod -a -G forget_api_users "$CLIENT_USERNAME"
echo "%forget_api_users ALL=(ALL) NOPASSWD: $SCRIPT_DIR/forget_api" > /etc/sudoers.d/forget_api

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
echo "Installation directory: $INSTALL_DIR"
echo "Client username: $CLIENT_USERNAME"
echo "MongoDB connection: mongosh -u $MONGODB_ADMIN -p $MONGODB_PASSWORD --authenticationDatabase admin"
echo ""
echo "The client can run the application using: sudo forget_api"
