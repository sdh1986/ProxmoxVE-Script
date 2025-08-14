#!/bin/bash
#
# ==============================================================================
# Proxmox VE Post-Install Optimization Script
#
# Description: This script optimizes a Proxmox VE installation by:
#              - Disabling the enterprise repository.
#              - Configuring community (no-subscription) and Ceph repositories.
#              - Switching APT sources to a specified mirror.
#              - Backing up critical configuration files before modification.
#              - Updating the system and installing optional packages.
#              - Adjusting CT update URLs to use the mirror.
#
# Usage:       sudo bash ./pve-optimize.sh
# ==============================================================================

# ---[ Script Configuration ]--------------------------------------------------

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Pipes fail on the first command that fails, not the last.
set -o pipefail

# ---[ Constants ]-------------------------------------------------------------

# Directory to store backups of modified files.
readonly BACKUP_DIR="/root/pve_config_backups"
# Timestamp for backup file subdirectories.
readonly TIME_STAMP=$(date "+%Y%m%d-%H%M%S")
# Mirror URL to use for Debian and Proxmox repositories.
readonly MIRROR_URL="https://mirrors.ustc.edu.cn"

# ---[ Logging Functions ]-----------------------------------------------------
# These functions add color-coded prefixes to messages for better readability.

LogInfo() {
  echo -e "\033[1;32m[INFO] \033[0m$1"
}

LogSuccess() {
  echo -e "\033[1;36m[SUCCESS] \033[0m$1"
}

LogWarn() {
  echo -e "\033[1;33m[WARN] \033[0m$1"
}

LogError() {
  # Direct error messages to stderr.
  echo -e "\033[1;31m[ERROR] \033[0m$1" >&2
}

# ---[ Helper Functions ]-----------------------------------------------------

# Creates a backup of a given file in a timestamped directory.
# Arguments:
#   $1: Path to the source file.
BackupFile() {
  local src_file="$1"
  local backup_dest_dir="${BACKUP_DIR}/${TIME_STAMP}"

  if [[ ! -f "$src_file" ]]; then
    LogWarn "File not found, skipping backup: $src_file"
    return
  fi

  mkdir -p "$backup_dest_dir"
  # The '-a' flag preserves permissions, ownership, and timestamps.
  cp -a "$src_file" "${backup_dest_dir}/"
  LogInfo "Backed up '$src_file' to '${backup_dest_dir}/'"
}

# Disables a PVE source file by renaming it with a .bak extension.
# Arguments:
#   $1: The base name of the source file (e.g., 'pve-enterprise').
DisableSourceFile() {
    local source_name="$1"
    local source_file="/etc/apt/sources.list.d/${source_name}.sources"

    if [[ -f "$source_file" ]]; then
        mv "$source_file" "${source_file}.bak"
        LogInfo "Disabled source file: $source_file"
    else
        LogWarn "Source file not found, skipping disable: $source_file"
    fi
}

# Updates the system, including a prompt for cleaning up unused packages.
UpdateSystem() {
  LogInfo "Updating package lists and upgrading the system..."
  apt-get update && apt-get full-upgrade -y
  LogSuccess "System updated and upgraded successfully."

  # Prompt user before running apt autoremove.
  read -r -p "Do you want to run 'apt-get autoremove' to remove unused packages? [y/N] " response
  if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    apt-get autoremove -y
    LogInfo "Unused packages have been removed."
  else
    LogInfo "Skipping 'apt-get autoremove'."
  fi

  apt-get clean
  LogInfo "APT cache has been cleaned."
}

# ---[ Main Logic ]-----------------------------------------------------------

Main() {
  # --- 1. Initial Checks and Setup ---
  LogInfo "Starting Proxmox VE post-install optimization..."

  # Ensure the script is run as root, as it modifies system files.
  if [[ $EUID -ne 0 ]]; then
    LogError "This script must be run as root. Please use 'sudo'."
    exit 1
  fi

  # Load OS release information to get the Debian codename (e.g., bookworm, trixie).
  if [[ ! -f /etc/os-release ]]; then
    LogError "/etc/os-release file not found. Cannot determine Debian version."
    exit 1
  fi
  # shellcheck source=/dev/null
  source /etc/os-release
  # The 'VERSION_CODENAME' variable is now available from the sourced file.
  LogInfo "Detected Debian Codename: $VERSION_CODENAME"


  # --- 2. Backup Critical Configuration Files ---
  LogInfo "Backing up existing configuration files to $BACKUP_DIR..."
  # An array makes it easy to add more files to the backup list.
  local files_to_backup=(
    "/etc/apt/sources.list"
    "/etc/apt/sources.list.d/pve-enterprise.sources"
    "/etc/apt/sources.list.d/debian.sources"
    "/usr/share/perl5/PVE/APLInfo.pm"
    "/etc/network/interfaces" # From your original script
  )
  for file in "${files_to_backup[@]}"; do
    BackupFile "$file"
  done
  # Also back up the Ceph source if it exists.
  if [[ -f "/etc/apt/sources.list.d/ceph.sources" ]]; then
      BackupFile "/etc/apt/sources.list.d/ceph.sources"
  fi
  LogSuccess "Configuration backup complete."


  # --- 3. Update APT Source Lists ---
  LogInfo "Configuring APT repositories to use mirror: $MIRROR_URL"

  # Disable the PVE Enterprise repository.
  DisableSourceFile "pve-enterprise"

  # Overwrite the legacy sources.list file. Proxmox now uses the .sources format,
  # so this file can be kept minimal to avoid conflicts.
  echo "# See /etc/apt/sources.list.d/ for repository configuration" > /etc/apt/sources.list
  LogInfo "Cleared legacy /etc/apt/sources.list file."

  # Configure Debian sources using the detected codename.
  cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: ${MIRROR_URL}/debian
Suites: ${VERSION_CODENAME} ${VERSION_CODENAME}-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${MIRROR_URL}/debian-security
Suites: ${VERSION_CODENAME}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  LogInfo "Updated Debian source file."

  # Configure PVE no-subscription source.
  cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: ${MIRROR_URL}/proxmox/debian/pve
Suites: ${VERSION_CODENAME}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  LogInfo "Updated PVE no-subscription source file."

  # Configure Ceph repository, if Ceph is installed.
  if command -v ceph &> /dev/null; then
    # This improved method reliably extracts the Ceph codename (e.g., 'quincy').
    local CEPH_CODENAME
    CEPH_CODENAME=`ceph -v | grep ceph | awk '{print $(NF-1)}'`

    if [[ -n "$CEPH_CODENAME" ]]; then
      LogInfo "Detected Ceph version: $CEPH_CODENAME"
      cat > /etc/apt/sources.list.d/ceph.sources <<EOF
Types: deb
URIs: ${MIRROR_URL}/proxmox/debian/ceph-${CEPH_CODENAME}
Suites: ${VERSION_CODENAME}
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
      LogInfo "Updated Ceph source file."
    else
      LogWarn "Could not determine Ceph codename. Skipping Ceph repository update."
    fi
  else
    LogInfo "Ceph is not installed. Skipping Ceph repository configuration."
  fi


  # --- 4. System Update and Package Management ---
  # Update CT (LXC) templates first.
  LogInfo "Updating CT (LXC) templates..."
  pveam update

  # Perform a full system update and upgrade.
  UpdateSystem
  
  # Ask the user if they want to install openvswitch-switch, as it's not
  # always required.
  read -r -p "Do you want to install 'openvswitch-switch' for advanced networking? [y/N] " response
  if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    LogInfo "Installing openvswitch-switch..."
    apt-get install -y openvswitch-switch
    LogSuccess "'openvswitch-switch' has been installed."
  else
    LogInfo "Skipping installation of 'openvswitch-switch'."
  fi


  # --- 5. Final Configuration Tweaks ---
  LogInfo "Updating URL for CT template downloads..."
  # This sed command replaces the default download URL with the mirror.
  sed -i.bak "s|http://download.proxmox.com|${MIRROR_URL}/proxmox|g" /usr/share/perl5/PVE/APLInfo.pm
  LogSuccess "CT template download URL has been updated."
  

  # --- 6. Restart Services ---
  LogInfo "Restarting PVE services to apply changes..."
  systemctl restart pveproxy.service pvedaemon.service
  
  LogSuccess "Services restarted."
  echo # Add a blank line for spacing.
  LogSuccess "Proxmox optimization script completed successfully!"
  LogInfo "It is recommended to reboot the system to ensure all changes take effect."
}

# ---[ Script Execution ]-----------------------------------------------------

# Run the main function, allowing 'set -e' to handle any errors.
Main "$@"