# Debian Package Installer

## Quick Installation

Run the following command to install the package (replace `admin` and `root` with your desired username and password):

```bash
curl -sSL https://raw.githubusercontent.com/DiagonalLokesh/my-debian-installer/main/install.sh | tr -d '\r' | sudo bash -s -- admin root 
```

## Manual Installation

To install the package, follow these steps:

1. Download the installation script:
   ```bash
   wget https://raw.githubusercontent.com/DiagonalLokesh/my-debian-installer/main/install.sh
   wget https://raw.githubusercontent.com/DiagonalLokesh/my-debian-installer/main/forget-api_v1.deb
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
