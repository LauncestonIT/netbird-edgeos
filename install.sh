#!/bin/bash
#
# This is the MAIN installer script for Netbird on EdgeOS.
# It is designed to be run as a one-liner, taking the management URL as an argument.
# It downloads the Netbird binary and installs the persistent boot script
# from the launcestonit/netbird-edgeos GitHub repository.

set -e

# --- System Paths and URLs (Do not edit) ---
PERSISTENT_CONFIG_DIR="/config/netbird"
INSTALLER_CONFIG_FILE="${PERSISTENT_CONFIG_DIR}/installer.conf"
ARCHIVE_CACHE_DIR="/config/data/netbird"
CACHED_ARCHIVE_FILE="${ARCHIVE_CACHE_DIR}/netbird-latest.tar.gz"

# This URL points to the raw version of the boot script in your GitHub repo.
BOOT_SCRIPT_URL="https://raw.githubusercontent.com/launcestonit/netbird-edgeos/main/99-netbird-boot.sh"
BOOT_SCRIPT_DEST="/config/scripts/post-config.d/99-netbird-boot.sh"


# --- Main setup function ---
setup() {
    # --- Step 1: Read Management URL from command-line argument ---
    SELF_HOSTED_MANAGEMENT_URL="$1"
    if [ -z "$SELF_HOSTED_MANAGEMENT_URL" ]; then
        echo "!! ERROR: You must provide your self-hosted management URL as an argument." >&2
        echo "!! Usage: sudo bash -s setup https://netbird.yourdomain.com" >&2
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

    # --- Step 3: Create Persistent Config and Download Boot Script ---
    echo "Creating persistent configuration..."
    mkdir -p "$PERSISTENT_CONFIG_DIR"
    echo "SELF_HOSTED_MANAGEMENT_URL=\"${SELF_HOSTED_MANAGEMENT_URL}\"" > "$INSTALLER_CONFIG_FILE"

    echo "Downloading boot script from ${BOOT_SCRIPT_URL}..."
    mkdir -p "$(dirname "$BOOT_SCRIPT_DEST")"
    curl -L --fail -o "$BOOT_SCRIPT_DEST" "$BOOT_SCRIPT_URL"
    chmod +x "$BOOT_SCRIPT_DEST"

    # --- Step 4: Run the Boot Script Now to Complete the Installation ---
    echo "Running boot script now to perform initial installation..."
    "$BOOT_SCRIPT_DEST"

    # --- Final User Instructions ---
    UP_CMD="sudo /usr/sbin/netbird up --setup-key YOUR_SETUP_KEY --management-url ${SELF_HOSTED_MANAGEMENT_URL}"
    echo ""
    echo "--------------------------------------------------------------------"
    echo " Netbird installation complete!"
    echo " To connect your router, run: ${UP_CMD}"
    echo "--------------------------------------------------------------------"
}

# --- Main Script Entrypoint ---
main() {
    if [ "$(id -u)" -ne 0 ]; then echo "This script must be run as root." >&2; exit 1; fi
    
    COMMAND="$1"
    URL_ARG="$2"

    case "$COMMAND" in
        setup|install)
            setup "$URL_ARG"
            ;;
        uninstall)
            # Uninstall logic can be added here if desired
            echo "Uninstalling..."
            systemctl stop netbird.service || true
            if command -v netbird >/dev/null 2>&1; then /usr/sbin/netbird service uninstall || true; fi
            rm -f /usr/sbin/netbird /etc/systemd/system/netbird.service
            rm -rf /config/netbird /config/data/netbird
            rm -f /config/scripts/post-config.d/99-netbird-boot.sh
            systemctl daemon-reload
            echo "Uninstall complete."
            ;;
        *)
            echo "Usage: sudo bash -s setup <management_url>" >&2
            echo "   or: sudo bash -s uninstall" >&2
            exit 1
            ;;
    esac
}

main "$@"