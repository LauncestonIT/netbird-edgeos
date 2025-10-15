#!/bin/sh

set -e

# Configuration - set your management URL here
MANAGEMENT_URL="${NETBIRD_MGMT_URL:-}"

if [ -z "$MANAGEMENT_URL" ]; then
    echo "Error: MANAGEMENT_URL not set"
    echo "Set the NETBIRD_MGMT_URL environment variable before running:"
    echo "  export NETBIRD_MGMT_URL=https://netbird.yourdomain.com"
    echo "  sudo -E ./netbird-edgeos.sh"
    exit 1
fi

# Determine architecture
MACHINE_ARCH=$(uname -m)
case $MACHINE_ARCH in
    mips) ARCH="mips_softfloat" ;;
    mips64) ARCH="mips64_hardfloat" ;;
    aarch64) ARCH="arm64" ;;
    *) echo "Error: Unsupported architecture: $MACHINE_ARCH" >&2; exit 1 ;;
esac

echo "Setting up Netbird for $ARCH with management server: $MANAGEMENT_URL"

# Create directory structure
mkdir -p /config/netbird/systemd/netbird.service.d
mkdir -p /config/netbird/state
mkdir -p /config/data/netbird

# Store management URL for post-config script
echo "MANAGEMENT_URL=$MANAGEMENT_URL" > /config/netbird/mgmt.conf

# Download and cache Netbird binary
echo "Downloading latest Netbird version..."
API_URL="https://api.github.com/repos/netbirdio/netbird/releases/latest"
LATEST_TAG=$(curl -s "$API_URL" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$LATEST_TAG" ]; then
    echo "Error: Could not determine latest Netbird version" >&2
    exit 1
fi
LATEST_VERSION=${LATEST_TAG#v}
DOWNLOAD_URL="https://github.com/netbirdio/netbird/releases/download/${LATEST_TAG}/netbird_${LATEST_VERSION}_linux_${ARCH}.tar.gz"

echo "Downloading from $DOWNLOAD_URL..."
curl -L --fail -o /config/data/netbird/netbird.tar.gz "$DOWNLOAD_URL"

# Extract and install binary
TMP_DIR=$(mktemp -d)
tar -xzf /config/data/netbird/netbird.tar.gz -C "$TMP_DIR"
install -m 755 "${TMP_DIR}/netbird" /usr/sbin/netbird
rm -rf "$TMP_DIR"

# Create state directory bind mount
if [ ! -f /config/netbird/systemd/var-lib-netbird.mount ]; then
    cat > /config/netbird/systemd/var-lib-netbird.mount <<-EOF
[Mount]
What=/config/netbird/state
Where=/var/lib/netbird
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
	EOF
fi

# Add override to require the bind mount
if [ ! -f /config/netbird/systemd/netbird.service.d/mount.conf ]; then
    cat > /config/netbird/systemd/netbird.service.d/mount.conf <<-EOF
[Unit]
RequiresMountsFor=/var/lib/netbird
	EOF
fi

# Add override to wait for networking
if [ ! -f /config/netbird/systemd/netbird.service.d/wait-for-networking.conf ]; then
    cat > /config/netbird/systemd/netbird.service.d/wait-for-networking.conf <<-EOF
[Unit]
Wants=vyatta-router.service
After=vyatta-router.service
	EOF
fi

# Install service (this will create /etc/systemd/system/netbird.service)
/usr/sbin/netbird service install --config /config/netbird/state/config.json

# Link the overrides
if [ ! -L /etc/systemd/system/netbird.service.d ]; then
    ln -s /config/netbird/systemd/netbird.service.d /etc/systemd/system/netbird.service.d
fi

# Copy mount unit (must be copied, not linked)
cp /config/netbird/systemd/var-lib-netbird.mount /etc/systemd/system/var-lib-netbird.mount

systemctl daemon-reload

# Start and enable the mount
systemctl enable var-lib-netbird.mount
systemctl start var-lib-netbird.mount

# Start and enable netbird service
systemctl enable netbird.service
systemctl start netbird.service

echo "Waiting for Netbird service to start..."
sleep 2

# Check if service is running
if systemctl is-active --quiet netbird.service; then
    echo "Netbird service is running"
else
    echo "Warning: Netbird service failed to start"
    systemctl status netbird.service
fi

# Create post-config script
mkdir -p /config/scripts/post-config.d
if [ ! -x /config/scripts/post-config.d/netbird.sh ]; then
    cat > /config/scripts/post-config.d/netbird.sh <<"EOF"
#!/bin/sh

set -e

reload=""

# The mount unit needs to be copied rather than linked
if [ ! -f /etc/systemd/system/var-lib-netbird.mount ]; then
    echo "Installing /var/lib/netbird mount unit"
    cp /config/netbird/systemd/var-lib-netbird.mount /etc/systemd/system/var-lib-netbird.mount
    reload=y
fi

if [ ! -L /etc/systemd/system/netbird.service.d ]; then
    ln -s /config/netbird/systemd/netbird.service.d /etc/systemd/system/netbird.service.d
    reload=y
fi

if [ -n "$reload" ]; then
    systemctl daemon-reload
fi

# Check if Netbird binary exists
if ! command -v netbird >/dev/null 2>&1; then
    echo "Installing Netbird from cache"
    if [ ! -f /config/data/netbird/netbird.tar.gz ]; then
        echo "Error: Cached Netbird archive not found" >&2
        exit 1
    fi
    
    TMP_DIR=$(mktemp -d)
    tar -xzf /config/data/netbird/netbird.tar.gz -C "$TMP_DIR"
    install -m 755 "${TMP_DIR}/netbird" /usr/sbin/netbird
    rm -rf "$TMP_DIR"
    
    # Reinstall service
    . /config/netbird/mgmt.conf
    /usr/sbin/netbird service install --config /config/netbird/state/config.json
    reload=y
fi

if [ -n "$reload" ]; then
    systemctl --no-block restart netbird
fi
EOF
    chmod 755 /config/scripts/post-config.d/netbird.sh
fi

echo ""
echo "Netbird installation complete!"
echo ""
echo "To connect your router, run:"
echo "  sudo netbird up --setup-key YOUR_SETUP_KEY --management-url $MANAGEMENT_URL"
echo ""
echo "The service will start automatically on boot."