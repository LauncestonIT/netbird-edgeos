#!/bin/bash
#
# This is the single, self-contained installer script for Netbird on EdgeOS.
# It is designed to be run as a one-liner, taking the management URL as an argument.
# It creates robust, persistent boot scripts to ensure Netbird survives firmware upgrades.
# It is heavily inspired by the design of the tailscale-edgeos script.

set -e

# --- System Paths (Do not edit) ---
PERSISTENT_CONFIG_DIR="/config/netbird"
INSTALLER_CONFIG_FILE="${PERSISTENT_CONFIG_DIR}/installer.conf"
ARCHIVE_CACHE_DIR="/config/data/netbird"
CACHED_ARCHIVE_FILE="${ARCHIVE_CACHE_DIR}/netbird-latest.tar.gz"
FIRSTBOOT_SCRIPT_DEST="/config/scripts/firstboot.d/10-install-netbird.sh"
POSTCONFIG_SCRIPT_DEST="/config/scripts/post-config.d/10-install-netbird.sh"


# --- Main setup function ---
setup() {
    # --- Step 1: Read Management URL from command-line argument ---
    SELF_HOSTED_MANAGEMENT_URL="$1"
    if [ -z "$SELF_HOSTED_MANAGEMENT_URL" ]; then
        echo "!! ERROR: You must provide your self-hosted management URL as an argument." >&2
        echo "!! Usage: ... | sudo bash -s setup https://netbird.yourdomain.com" >&2
        exit 1
    fi
    echo "Setting up Netbird for management server: ${SELF_HOSTED_MANAGEMENT_URL}"

    # --- Step 2: Download and Cache the Binary ---
    echo "Determining correct architecture..."
    MACHINE_ARCH=$(uname -m)
    case $MACHINE_ARCH in
      mips) ARCH="mips_softfloat" ;;
      mips64) ARCH="mips64_hardfloat" ;;
      aarch64) ARCH="arm64" ;;
      *) echo "Fatal: Unsupported architecture: $MACHINE_ARCH" >&2; exit 1 ;;
    esac
    
    echo "Finding and downloading latest Netbird version..."
    API_URL="https://api.github.com/repos/netbirdio/netbird/releases/latest"
    LATEST_TAG=$(curl -s "$API_URL" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_TAG" ]; then echo "Fatal: Could not determine latest Netbird version." >&2; exit 1; fi
    LATEST_VERSION=${LATEST_TAG#v}
    DOWNLOAD_URL="https://github.com/netbirdio/netbird/releases/download/${LATEST_TAG}/netbird_${LATEST_VERSION}_linux_${ARCH}.tar.gz"

    TMP_DIR=$(mktemp -d)
    curl -L --fail -o "${TMP_DIR}/netbird.tar.gz" "$DOWNLOAD_URL"
    echo "Caching downloaded archive to ${CACHED_ARCHIVE_FILE}..."
    mkdir -p "$ARCHIVE_CACHE_DIR"
    cp "${TMP_DIR}/netbird.tar.gz" "$CACHED_ARCHIVE_FILE"
    rm -rf "$TMP_DIR"

    # --- Step 3: Create Persistent Configuration and Scripts ---
    echo "Creating persistent configuration and installing boot scripts..."
    mkdir -p "$PERSISTENT_CONFIG_DIR"
    mkdir -p "$(dirname "$FIRSTBOOT_SCRIPT_DEST")"
    mkdir -p "$(dirname "$POSTCONFIG_SCRIPT_DEST")"

    echo "SELF_HOSTED_MANAGEMENT_URL=\"${SELF_HOSTED_MANAGEMENT_URL}\"" > "$INSTALLER_CONFIG_FILE"

    # --- Create the firstboot.d script ---
    cat << 'EOF' > "$FIRSTBOOT_SCRIPT_DEST"
#!/bin/bash
# This script runs once after a firmware upgrade.
# It calls the main post-config script to perform the actual re-installation.
POST_CONFIG_SCRIPT="/config/scripts/post-config.d/10-install-netbird.sh"
if [ -x "$POST_CONFIG_SCRIPT" ]; then
    echo "Running Netbird post-config script from firstboot..."
    "$POST_CONFIG_SCRIPT"
fi
EOF
    chmod +x "$FIRSTBOOT_SCRIPT_DEST"

    # --- Create the post-config.d script (the main worker) ---
    cat << 'EOF' > "$POSTCONFIG_SCRIPT_DEST"
#!/bin/bash
# This is the main worker script. It ensures Netbird is installed and configured.

# Only run installation logic if the binary is missing
if ! command -v netbird >/dev/null 2>&1; then
    echo "Netbird not found, installing from cache..."

    # --- Define Paths ---
    INSTALL_DIR="/usr/sbin"
    BINARY_NAME="netbird"
    PERSISTENT_CONFIG_DIR="/config/netbird"
    INSTALLER_CONFIG_FILE="${PERSISTENT_CONFIG_DIR}/installer.conf"
    PERSISTENT_CONFIG_FILE="${PERSISTENT_CONFIG_DIR}/config.json"
    CACHED_ARCHIVE_FILE="/config/data/netbird/netbird-latest.tar.gz"

    # --- Source the configuration to get the management URL ---
    if [ ! -f "$INSTALLER_CONFIG_FILE" ]; then echo "FATAL: Installer config not found." >&2; exit 1; fi
    source "$INSTALLER_CONFIG_FILE"
    if [ ! -f "$CACHED_ARCHIVE_FILE" ]; then echo "FATAL: Netbird cache missing." >&2; exit 1; fi

    # --- Installation Logic ---
    TMP_DIR=$(mktemp -d)
    tar -xzf "$CACHED_ARCHIVE_FILE" -C "$TMP_DIR"
    install -m 755 "${TMP_DIR}/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
    mkdir -p "${PERSISTENT_CONFIG_DIR}"
    SERVICE_INSTALL_CMD=("${INSTALL_DIR}/${BINARY_NAME}" service install --config "${PERSISTENT_CONFIG_FILE}" --management-url "${SELF_HOSTED_MANAGEMENT_URL}")
    "${SERVICE_INSTALL_CMD[@]}"
    rm -rf "$TMP_DIR"
fi

# --- Systemd Override Logic (runs every boot to be safe) ---
OVERRIDE_DIR="/config/netbird/systemd/netbird.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/10-wait-for-networking.conf"
if [ ! -f "$OVERRIDE_FILE" ]; then
    echo "Creating systemd override for networking dependency..."
    mkdir -p "$OVERRIDE_DIR"
    cat > "$OVERRIDE_FILE" <<-EOM
[Unit]
Wants=vyatta-router.service
After=vyatta-router.service
EOM
fi

# Ensure the override is always linked correctly
if [ ! -L /etc/systemd/system/netbird.service.d ]; then
    ln -s "$OVERRIDE_DIR" /etc/systemd/system/netbird.service.d
    systemctl daemon-reload
fi
EOF
    chmod +x "$POSTCONFIG_SCRIPT_DEST"

    # --- Step 4: Run the Post-Config Script Now to Complete the Installation ---
    echo "Running post-config script now to perform initial installation..."
    "$POSTCONFIG_SCRIPT_DEST"

    # --- Final User Instructions ---
    UP_CMD="sudo /usr/sbin/netbird up --setup-key YOUR_SETUP_KEY --management-url ${SELF_HOSTED_MANAGEMENT_URL}"
    echo ""
    echo "--------------------------------------------------------------------"
    echo " Netbird installation complete!"
    echo " To connect your router, run: ${UP_CMD}"
    echo "--------------------------------------------------------------------"
}


# --- Uninstall function ---
uninstall() {
    echo "Uninstalling Netbird..."
    systemctl stop netbird.service || true
    if command -v netbird >/dev/null 2>&1; then
        /usr/sbin/netbird service uninstall || true
    fi
    systemctl disable netbird.service || true
    
    echo "Removing system files, scripts, and configuration..."
    rm -f /etc/systemd/system/netbird.service
    rm -rf /etc/systemd/system/netbird.service.d
    rm -f /usr/sbin/netbird
    rm -f "$FIRSTBOOT_SCRIPT_DEST"
    rm -f "$POSTCONFIG_SCRIPT_DEST"
    rm -rf "$ARCHIVE_CACHE_DIR"
    rm -rf "$PERSISTENT_CONFIG_DIR"

    systemctl daemon-reload
    echo "Netbird has been uninstalled."
}


# --- Main Script Entrypoint ---
main() {
    if [ "$(id -u)" -ne 0 ]; then echo "This script must be run as root." >&2; exit 1; fi
    
    COMMAND="$1"
    URL_ARG="$2"

    case "$COMMAND" in
        setup|install) setup "$URL_ARG" ;;
        uninstall) uninstall ;;
        *)
            echo "Usage: ... | sudo bash -s setup <management_url>" >&2
            echo "   or: ... | sudo bash -s uninstall" >&2
            exit 1
            ;;
    esac
}

main "$@"