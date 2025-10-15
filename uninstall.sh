#!/bin/sh

set -e

echo "Uninstalling Netbird from EdgeOS..."

# Stop and disable the service
echo "Stopping Netbird service..."
systemctl stop netbird.service 2>/dev/null || true
systemctl disable netbird.service 2>/dev/null || true

# Stop and disable the mount
echo "Stopping state directory mount..."
systemctl stop var-lib-netbird.mount 2>/dev/null || true
systemctl disable var-lib-netbird.mount 2>/dev/null || true

# Uninstall the service using netbird's built-in uninstaller
if command -v netbird >/dev/null 2>&1; then
    echo "Running Netbird service uninstaller..."
    /usr/sbin/netbird service uninstall 2>/dev/null || true
fi

# Remove systemd units and overrides
echo "Removing systemd configuration..."
rm -f /etc/systemd/system/netbird.service
rm -rf /etc/systemd/system/netbird.service.d
rm -f /etc/systemd/system/var-lib-netbird.mount

# Remove the binary
echo "Removing Netbird binary..."
rm -f /usr/sbin/netbird

# Remove post-config script
echo "Removing boot scripts..."
rm -f /config/scripts/post-config.d/netbird.sh

# Remove cached archive
echo "Removing cached files..."
rm -rf /config/data/netbird

# Remove persistent configuration and state
echo "Removing configuration and state..."
rm -rf /config/netbird

# Reload systemd
systemctl daemon-reload

echo ""
echo "Netbird has been completely uninstalled."
echo ""
echo "The following were removed:"
echo "  - Netbird binary (/usr/sbin/netbird)"
echo "  - Systemd service and mount units"
echo "  - Boot scripts (/config/scripts/post-config.d/netbird.sh)"
echo "  - Cached archive (/config/data/netbird/)"
echo "  - Configuration and state (/config/netbird/)"
echo ""
echo "Uninstall complete!"