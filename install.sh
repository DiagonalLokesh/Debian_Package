#!/bin/bash
set -e

echo "Starting secure installation process..."

# Check for root privileges
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

# Validate input parameters
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <username> <password> <client_username>"
    exit 1
fi

MONGODB_ADMIN=$1
MONGODB_PASSWORD=$2
CLIENT_USERNAME=$3

# System updates and initial setup
apt-get update
apt-get install -y dos2unix gnupg curl acl attr

# MongoDB Installation
curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | \
   sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg \
   --dearmor

echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] http://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main" | \
    tee /etc/apt/sources.list.d/mongodb-org-8.0.list

apt-get update
apt-get install -y mongodb-org

# Download and install latest package
LATEST_DEB=$(curl -s https://api.github.com/repos/DiagonalLokesh/Debian_Package/releases/latest | grep "browser_download_url.*deb" | cut -d '"' -f 4)
if [ -z "$LATEST_DEB" ]; then
    echo "Error: Could not find latest release"
    exit 1
fi

echo "Downloading latest version from: $LATEST_DEB"
wget "$LATEST_DEB" -O latest.deb && apt install -y ./latest.deb

useradd -m -s /bin/bash "$CLIENT_USERNAME" 2>/dev/null || echo "User $CLIENT_USERNAME already exists"
usermod -aG sudo "$CLIENT_USERNAME"

# Create service user for FastAPI
useradd -r -s /sbin/nologin fastapi_service || true

echo "$CLIENT_USERNAME ALL=(ALL:ALL) ALL,!/usr/bin/main,!/usr/bin/.hidden/main,!/opt/fastapi-app/,!/usr/bin/chattr" > /etc/sudoers.d/$CLIENT_USERNAME
chmod 0440 /etc/sudoers.d/$CLIENT_USERNAME

# Configure advanced security for FastAPI directory
secure_fastapi_directory() {
    local app_dir="/usr/bin"
    local main_file="$app_dir/main"
    local hidden_dir="$app_dir/.hidden"
    
    mkdir -p "$hidden_dir"
    mv "$main_file" "$hidden_dir/main"
    # Set permissions
    chown root:root "$hidden_dir/main"
    chmod 100 "$hidden_dir/main"
    chmod 500 "$hidden_dir"
    
    # Create symlink
    ln -s "$hidden_dir/main" "$app_dir/main"
    
    # Apply ACL
    setfacl -m u:$CLIENT_USERNAME:---,g::---,o::--- "$hidden_dir/main"
    setfacl -m u:fastapi_service:--x "$hidden_dir/main"
    
    cat > /etc/systemd/system/fastapi-protect.service << EOF
[Unit]
Description=Protect FastAPI executable
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/chmod 100 /usr/bin/.hidden/main
ExecStart=/usr/bin/chown root:root /usr/bin/.hidden/main
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable fastapi-protect
}
# Apply FastAPI security measures
secure_fastapi_directory

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

# Set up MongoDB directories
mkdir -p /var/lib/mongodb
mkdir -p /var/log/mongodb
chown -R mongodb:mongodb /var/lib/mongodb
chown -R mongodb:mongodb /var/log/mongodb
chmod 755 /var/lib/mongodb
chmod 755 /var/log/mongodb

# Start MongoDB services
systemctl daemon-reload
systemctl start mongod
systemctl enable mongod
systemctl restart mongod

echo "Waiting for MongoDB to start..."
sleep 5

# Configure MongoDB admin user
mongosh admin --eval "
  db.createUser({
    user: '$MONGODB_ADMIN',
    pwd: '$MONGODB_PASSWORD',
    roles: [ { role: 'root', db: 'admin' } ]
  })
"

# Enable MongoDB authentication
sed -i 's/authorization: disabled/authorization: enabled/' /etc/mongod.conf

# Cleanup
rm latest.deb
rm -r "$main_file"
echo "Installation completed with enhanced security measures!"
echo "MongoDB connection string: mongosh -u $MONGODB_ADMIN -p $MONGODB_PASSWORD --authenticationDatabase admin"
echo "Note: The FastAPI application directory has been secured with strict permissions."

main
