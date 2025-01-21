# Debian Package Installer

## Quick Installation

Run the following command to install the package (replace `user`, `diagonal` and `client` with your desired MongoDB username, MongoDB password and client_username):

```bash
curl -sSL https://raw.githubusercontent.com/DiagonalLokesh/Debian_Package/main/install.sh | tr -d '\r' | sudo bash -s -- <mongodb_username> <mongodb_password> <client_username>
```

#### Test
```bash
curl -sSL https://raw.githubusercontent.com/DiagonalLokesh/Debian_Package/main/install.sh | tr -d '\r' | sudo bash -s -- user diagonal client
```

## Manual Installation

To install the package, follow these steps:

1. Download the installation script:
   ```bash
   wget https://raw.githubusercontent.com/Debian_Package/main/install.sh
   wget https://raw.githubusercontent.com/Debian_Package/main/forget-api_v1.deb
   ```

2. Update package list
   ```bash
   sudo apt update
   sudo apt install dos2unix
   ```

3. Run the script
   ```bash
   dos2unix install.sh
   chmod +x install.sh
   sudo ./install.sh
   ```
