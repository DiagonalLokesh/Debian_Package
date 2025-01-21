#!/bin/bash
set -e

# Install required packages
apt-get update
apt-get install -y dos2unix e2fsprogs openssl acl

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

# Create service account for application ownership
SERVICE_USER="forget_service"
useradd -r -s /usr/sbin/nologin "$SERVICE_USER" 2>/dev/null || true

# Create client user
useradd -m -s /usr/sbin/nologin "$CLIENT_USERNAME" 2>/dev/null || true

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

# Create wrapper script directory
WRAPPER_DIR="/usr/local/bin"
mkdir -p "$WRAPPER_DIR"

# Remove immutable attribute if exists
chattr -i "$WRAPPER_DIR/forget_api_wrapper" 2>/dev/null || true

# Create and configure wrapper script
cat > "$WRAPPER_DIR/forget_api_wrapper" << 'EOF'
#!/bin/bash
if [ -n "$SUDO_USER" ]; then
    echo "This application cannot be run with sudo"
    exit 1
fi
exec /opt/.forget_api/opt/fastapi-app/main.py "$@"
EOF

# Set correct ownership and permissions for wrapper
chmod 555 "$WRAPPER_DIR/forget_api_wrapper"
chown root:root "$WRAPPER_DIR/forget_api_wrapper"

# Set directory and file permissions
chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR"
find "$INSTALL_DIR" -type f -exec chmod 400 {} \;
find "$INSTALL_DIR" -type d -exec chmod 500 {} \;

# Remove any existing ACLs
setfacl -b "$INSTALL_DIR"
setfacl -R -b "$INSTALL_DIR"

# Set specific ACLs
setfacl -m u:$CLIENT_USERNAME:--x "$INSTALL_DIR"
find "$INSTALL_DIR" -type f -exec setfacl -m u:$CLIENT_USERNAME:--x {} \;
find "$INSTALL_DIR" -type d -exec setfacl -m u:$CLIENT_USERNAME:--x {} \;

# Make files immutable after setting permissions
chattr +i "$WRAPPER_DIR/forget_api_wrapper"
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

# Create restricted MongoDB user
RESTRICTED_USER_PASSWORD=$(openssl rand -hex 12)
mongosh admin --eval "
  db.createUser({
    user: '$CLIENT_USERNAME',
    pwd: '$RESTRICTED_USER_PASSWORD',
    roles: [ { role: 'root', db: 'admin' } ]
  })
"
sed -i 's/authorization: disabled/authorization: enabled/' /etc/mongod.conf
systemctl restart mongod
sleep 5

# Configure sudoers
cat > "/etc/sudoers.d/$CLIENT_USERNAME" << EOF
Cmnd_Alias FORGET_API_COMMANDS = /usr/bin/systemctl status mongod, /usr/bin/systemctl restart mongod
$CLIENT_USERNAME ALL=(ALL) NOPASSWD: FORGET_API_COMMANDS
$CLIENT_USERNAME ALL=(ALL) !($INSTALL_DIR/*, $INSTALL_DIR)
EOF
chmod 440 "/etc/sudoers.d/$CLIENT_USERNAME"

# Clean up
rm latest.deb

echo "Installation and security setup completed successfully!"
echo "Restricted user '$CLIENT_USERNAME' has been created with execute-only permissions"
echo "MongoDB password for restricted user: $RESTRICTED_USER_PASSWORD"
echo "Execute the application using: forget_api_wrapper"
echo "MongoDB connection for admin: mongosh -u $MONGODB_ADMIN -p $MONGODB_PASSWORD --authenticationDatabase admin"
echo "MongoDB connection for restricted user: mongosh -u $CLIENT_USERNAME -p $RESTRICTED_USER_PASSWORD --authenticationDatabase admin"
