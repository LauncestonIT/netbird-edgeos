#!/bin/bash
#
# This script runs on every boot to ensure Netbird is installed.
# It includes a systemd override to ensure networking is fully up before Netbird starts.

# Only run if the netbird binary is missing to speed up normal boots
if command -v netbird >/dev/null 2>&1; then
    # Even if it exists, ensure the override is linked. This is a fast check.
    if [ ! -L /etc/systemd/system/netbird.service.d ]; then
        # The override symlink is missing, recreate it
        ln -s /config/netbird/systemd/netbird.service.d /etc/systemd/system/netbird.service.d
        systemctl daemon-reload
    fi
    exit 0
fi

echo "Netbird not found on boot, installing from cache..."

# --- Define Paths ---
INSTALL_DIR="/usr/sbin"
BINARY_NAME="netbird"
PERSISTENT_CONFIG_DIR="/config/netbird"
INSTALLER_CONFIG_FILE="${PERSISTENT_CONFIG_DIR}/installer.conf"
PERSISTENT_CONFIG_FILE="${PERSISTENT_CONFIG_DIR}/config.json"
CACHED_ARCHIVE_FILE="/config/data/netbird/netbird-latest.tar.gz"

# --- Source the configuration to get the management URL ---
if [ ! -f "$INSTALLER_CONFIG_FILE" ]; then
    echo "FATAL: Installer config not found. Cannot proceed." >&2
    exit 1
fi
source "$INSTALLER_CONFIG_FILE"

if [ ! -f "$CACHED_ARCHIVE_FILE" ]; then
    echo "FATAL: Netbird cache missing. Cannot proceed." >&2
    exit 1
fi

# --- Create the Systemd Override for Robust Startup ---
OVERRIDE_DIR="/config/netbird/systemd/netbird.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/10-wait-for-networking.conf"

echo "Creating systemd override for networking dependency..."
mkdir -p "$OVERRIDE_DIR"
cat > "$OVERRIDE_FILE" <<-EOF
# This override ensures that the Netbird service starts only after
# the main EdgeOS routing daemons are fully operational.
[Unit]
Wants=vyatta-router.service
After=vyatta-router.service
EOF

# --- Installation Logic ---
TMP_DIR=$(mktemp -d)
tar -xzf "$CACHED_ARCHIVE_FILE" -C "$TMP_DIR"
install -m 755 "${TMP_DIR}/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
mkdir -p "${PERSISTENT_CONFIG_DIR}"

SERVICE_INSTALL_CMD=("${INSTALL_DIR}/${BINARY_NAME}" service install --config "${PERSISTENT_CONFIG_FILE}" --management-url "${SELF_HOSTED_MANAGEMENT_URL}")

echo "Installing service with explicit config: ${PERSISTENT_CONFIG_FILE}"
"${SERVICE_INSTALL_CMD[@]}"

# --- Link the override directory so systemd can find it ---
# This must be done AFTER the service is installed but BEFORE daemon-reload
echo "Linking systemd override..."
ln -s "$OVERRIDE_DIR" /etc/systemd/system/netbird.service.d

systemctl daemon-reload
systemctl enable netbird.service
systemctl start netbird.service
rm -rf "$TMP_DIR"

echo "Netbird service installed and started."