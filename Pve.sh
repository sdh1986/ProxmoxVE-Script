#!/bin/bash
#
# ==============================================================================
# Unified Proxmox VE Post-Install Optimization Script (Enhanced)
#
# Description: This script intelligently optimizes a Proxmox VE installation
#              for versions 8.x (Debian 12) and 9.x (Debian 13). It detects
#              the Debian version and applies the correct repository format.
#
# Key Features:
#   - Disables the enterprise repository.
#   - Configures community (no-subscription) and Ceph repositories.
#   - Switches APT and CT template sources to a user-defined mirror.
#   - Backs up critical configuration files before making changes.
#   - Updates the system and optionally installs 'openvswitch-switch'.
#   - Fixes service restart logic to ensure changes are applied immediately.
#   - Supports non-interactive execution via command-line flags.
#   - [NEW] Uses 'at' command to schedule service restart for maximum reliability.
#
# Usage (Interactive):
#   sudo /bin/bash ./Pve_fixed.sh
#
# Usage (Non-Interactive / Automated):
#   curl -sSL [URL] | sudo bash -s -- --autoremove --install-ovs
# ==============================================================================

# ---[ Script Configuration ]--------------------------------------------------

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Pipes fail on the first command that fails, not the last.
set -o pipefail

# ---[ Argument Parsing ]------------------------------------------------------
# Initialize variables for non-interactive flags
AUTOREMOVE=false
INSTALL_OVS=false

# Process command-line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --autoremove)
      AUTOREMOVE=true
      shift # past argument
      ;;
    --install-ovs)
      INSTALL_OVS=true
      shift # past argument
      ;;
    *)
      # unknown option
      shift
      ;;
  esac
done


# ---[ Constants ]-------------------------------------------------------------

# Directory to store backups of modified files.
readonly BACKUP_DIR="/root/pve_config_backups"
# Timestamp for backup file subdirectories.
readonly TIME_STAMP=$(date "+%Y%m%d-%H%M%S")
# Mirror URL to use for Debian and Proxmox repositories.
readonly MIRROR_URL="https://mirrors.ustc.edu.cn"

# ---[ Logging Functions ]-----------------------------------------------------
# Color-coded prefixes for better readability.

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
# Arguments: $1: Path to the source file.
BackupFile() {
  local src_file="$1"
  local backup_dest_dir="${BACKUP_DIR}/${TIME_STAMP}"

  if [[ ! -f "$src_file" ]]; then
    LogWarn "File not found, skipping backup: $src_file"
    return
  fi

  mkdir -p "$backup_dest_dir"
  cp -a "$src_file" "${backup_dest_dir}/"
  LogInfo "Backed up '$src_file' to '${backup_dest_dir}/'"
}

# Updates the system, including a prompt for cleaning up unused packages.
UpdateSystem() {
  LogInfo "Updating package lists and upgrading the system..."
  apt-get update && apt-get full-upgrade -y
  LogSuccess "System updated and upgraded successfully."

  local response=""
  if [ "$AUTOREMOVE" = true ]; then
      response="y"
  else
      read -r -p "Do you want to run 'apt-get autoremove' to remove unused packages? [y/N] " response
  fi
  
  if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    apt-get autoremove -y
    LogInfo "Unused packages have been removed."
  else
    LogInfo "Skipping 'apt-get autoremove'."
  fi

  apt-get clean
  LogInfo "APT cache has been cleaned."
}

# ---[ Version-Specific Repository Configuration ]----------------------------

# Configures APT repositories for PVE 8.x on Debian 12 (Bookworm)
# Uses the traditional .list format.
ConfigureReposForBookworm() {
  LogInfo "Applying repository configuration for Debian 12 (Bookworm)..."
  local enterprise_list="/etc/apt/sources.list.d/pve-enterprise.list"
  local sources_list="/etc/apt/sources.list"

  # Disable enterprise repo by commenting it out
  if [[ -f "$enterprise_list" ]]; then
    sed -i 's/^deb/#deb/' "$enterprise_list"
    LogInfo "Disabled PVE Enterprise repository."
  fi
  
  # Configure Debian repositories
  cat > "$sources_list" <<EOF
deb ${MIRROR_URL}/debian/ bookworm main contrib non-free non-free-firmware
deb ${MIRROR_URL}/debian/ bookworm-updates main contrib non-free non-free-firmware
deb ${MIRROR_URL}/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
  LogInfo "Updated Debian sources."

  # Configure PVE no-subscription repository
  cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb ${MIRROR_URL}/proxmox/debian/pve bookworm pve-no-subscription
EOF
  LogInfo "Updated PVE no-subscription source."

  # Configure Ceph repository
  if command -v ceph &> /dev/null; then
    local ceph_codename
    ceph_codename=$(ceph -v | awk '/ceph version / {print $(NF-1)}')
    if [[ -n "$ceph_codename" ]]; then
      LogInfo "Detected Ceph version: $ceph_codename"
      cat > /etc/apt/sources.list.d/ceph.list <<EOF
deb ${MIRROR_URL}/proxmox/debian/ceph-${ceph_codename} bookworm no-subscription
EOF
      LogInfo "Updated Ceph source."
    else
      LogWarn "Could not determine Ceph codename. Skipping Ceph repository update."
    fi
  else
    LogInfo "Ceph not found. Skipping Ceph repository configuration."
  fi
}

# Configures APT repositories for PVE 9.x on Debian 13 (Trixie)
# Uses the modern DEB822 .sources format.
ConfigureReposForTrixie() {
  LogInfo "Applying repository configuration for Debian 13 (Trixie)..."
  
  # Disable enterprise repo by renaming the file
  local enterprise_sources="/etc/apt/sources.list.d/pve-enterprise.sources"
  if [[ -f "$enterprise_sources" ]]; then
    mv "$enterprise_sources" "${enterprise_sources}.bak"
    LogInfo "Disabled PVE Enterprise repository."
  fi

  # Clear legacy sources.list file
  echo "# See /etc/apt/sources.list.d/ for repository configuration" > /etc/apt/sources.list
  
  # Configure Debian repositories
  cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: ${MIRROR_URL}/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${MIRROR_URL}/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  LogInfo "Updated Debian sources."

  # Configure PVE no-subscription repository
  cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: ${MIRROR_URL}/proxmox/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  LogInfo "Updated PVE no-subscription source."
  
  # Configure Ceph repository
  if command -v ceph &> /dev/null; then
    local ceph_codename
    ceph_codename=$(ceph -v | awk '/ceph version / {print $(NF-1)}')
    if [[ -n "$ceph_codename" ]]; then
      LogInfo "Detected Ceph version: $ceph_codename"
      cat > /etc/apt/sources.list.d/ceph.sources <<EOF
Types: deb
URIs: ${MIRROR_URL}/proxmox/debian/ceph-${ceph_codename}
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
      LogInfo "Updated Ceph source."
    else
      LogWarn "Could not determine Ceph codename. Skipping Ceph repository update."
    fi
  else
    LogInfo "Ceph not found. Skipping Ceph repository configuration."
  fi
}

# ---[ Main Logic ]-----------------------------------------------------------

Main() {
  # --- 1. Initial Checks and Setup ---
  LogInfo "Starting unified Proxmox VE post-install optimization..."

  if [[ $EUID -ne 0 ]]; then
    LogError "This script must be run as root. Please use 'sudo'."
    exit 1
  fi

  if [[ ! -f /etc/os-release ]]; then
    LogError "/etc/os-release file not found. Cannot determine Debian version."
    exit 1
  fi
  # shellcheck source=/dev/null
  source /etc/os-release
  LogInfo "Detected Debian Codename: $VERSION_CODENAME"

  # --- 2. Backup Critical Configuration Files ---
  LogInfo "Backing up existing configuration files to $BACKUP_DIR..."
  local files_to_backup=(
    "/etc/apt/sources.list"
    "/usr/share/perl5/PVE/APLInfo.pm"
    "/etc/network/interfaces"
  )
  # Add version-specific repo files to the backup list
  if [[ "$VERSION_CODENAME" == "bookworm" ]]; then
    files_to_backup+=("/etc/apt/sources.list.d/pve-enterprise.list")
    files_to_backup+=("/etc/apt/sources.list.d/ceph.list")
  elif [[ "$VERSION_CODENAME" == "trixie" ]]; then
    files_to_backup+=("/etc/apt/sources.list.d/pve-enterprise.sources")
    files_to_backup+=("/etc/apt/sources.list.d/debian.sources")
    files_to_backup+=("/etc/apt/sources.list.d/ceph.sources")
  fi
  
  for file in "${files_to_backup[@]}"; do
    BackupFile "$file"
  done
  LogSuccess "Configuration backup complete."

  # --- 3. Update APT Source Lists (Conditional Logic) ---
  LogInfo "Configuring APT repositories to use mirror: $MIRROR_URL"
  if [[ "$VERSION_CODENAME" == "bookworm" ]]; then
    ConfigureReposForBookworm
  elif [[ "$VERSION_CODENAME" == "trixie" ]]; then
    ConfigureReposForTrixie
  else
    LogError "Unsupported Debian version: $VERSION_CODENAME."
    LogError "This script only supports 'bookworm' (Debian 12) and 'trixie' (Debian 13)."
    exit 1
  fi
  LogSuccess "APT repositories configured successfully."

  # --- 4. System Update and Package Management ---
  LogInfo "Updating CT (LXC) templates..."
  pveam update
  
  UpdateSystem
  
  local response=""
  if [ "$INSTALL_OVS" = true ]; then
      response="y"
  else
      read -r -p "Do you want to install 'openvswitch-switch' for advanced networking? [y/N] " response
  fi

  if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    LogInfo "Installing openvswitch-switch..."
    apt-get install -y openvswitch-switch
    LogSuccess "'openvswitch-switch' has been installed."
  else
    LogInfo "Skipping installation of 'openvswitch-switch'."
  fi

  # --- 5. Final Configuration Tweaks ---
  LogInfo "Updating URL for CT template downloads..."
  sed -i "s|http://download.proxmox.com|${MIRROR_URL}/proxmox|g" /usr/share/perl5/PVE/APLInfo.pm
  LogSuccess "CT template download URL has been updated."
  
  # --- 6. Schedule Service Restart ---
  LogInfo "Ensuring 'at' command is available for reliable service restart..."
  apt-get install -y at
  
  LogInfo "Scheduling PVE services to restart in 1 minute to apply all changes."
  # Using 'at' command to schedule the restart. This is the most reliable way
  # to ensure the services restart correctly, especially when the script is run
  # from a transient shell like via 'curl | bash'.
  # The commands are piped to 'at' which will execute them in a clean, stable
  # environment after the script has finished.
  echo "systemctl stop pveproxy.service pvedaemon.service && systemctl start pveproxy.service pvedaemon.service" | at now + 1 minute
  
  LogSuccess "Service restart has been scheduled."
  echo 
  LogSuccess "Proxmox optimization script completed successfully!"
  LogInfo "Services will restart automatically in approximately one minute."
  LogInfo "It is recommended to also reboot the system later to ensure all changes take effect."
}

# ---[ Script Execution ]-----------------------------------------------------

# Pass command-line arguments to the Main function
Main "$@"
