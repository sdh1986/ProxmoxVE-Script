#!/bin/bash
#
# ==============================================================================
# Unified Proxmox VE Post-Install Script
#
# Description: This script intelligently optimizes a Proxmox VE installation
#              for versions 8.x (Debian 12) and 9.x (Debian 13). It detects
#              the Debian version and applies the correct repository format.
#
# Key Features:
#    - Disables the enterprise repository.
#    - Configures community (no-subscription) and Ceph repositories.
#    - Switches APT and CT template sources to a user-defined mirror.
#    - Optimizes TurnKey Linux LXC template sources (metadata & download URLs).
#    - Backs up critical configuration files before making changes.
#    - Updates the system and optionally installs 'openvswitch-switch'.
#    - Patches pveceph.pm to prevent it from overwriting mirror settings.
#    - Robustly handles APT locks to prevent conflicts with background processes.
#
# Usage:       /bin/bash Pve.sh or ./Pve.sh
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

# Waits for APT locks to be released to avoid "Could not get lock" errors.
WaitForAptLocks() {
  LogInfo "Checking for active APT locks..."
  local lock_files=("/var/lib/apt/lists/lock" "/var/lib/dpkg/lock" "/var/lib/dpkg/lock-frontend")
  local timeout=300
  local timer=0

  while true; do
    local locked=false
    
    # Method 1: Check lock files using fuser (most reliable)
    if command -v fuser &> /dev/null; then
      for lock in "${lock_files[@]}"; do
        if fuser "$lock" >/dev/null 2>&1; then
          locked=true
          break
        fi
      done
    # Method 2: Fallback to checking process names if fuser is missing
    else
      if pgrep -x "apt" >/dev/null || pgrep -x "apt-get" >/dev/null || pgrep -x "dpkg" >/dev/null; then
        locked=true
      fi
    fi

    if [[ "$locked" == "false" ]]; then
      break
    fi

    if [[ "$timer" -ge "$timeout" ]]; then
      echo ""
      LogError "Timed out waiting for APT locks to be released. Please check running processes manually."
      exit 1
    fi

    echo -ne "Waiting for other package management processes to finish... (${timer}s)\r"
    sleep 1
    timer=$((timer + 1))
  done
  
  if [[ "$timer" -gt 0 ]]; then
    echo -e "\nLocks released. Proceeding..."
  fi
}

# Updates the system, including a prompt for cleaning up unused packages.
UpdateSystem() {
  WaitForAptLocks
  
  LogInfo "Updating package lists and upgrading the system..."
  apt-get update
  apt-get full-upgrade -y
  LogSuccess "System updated and upgraded successfully."

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

# ---[ TurnKey Linux ]-------------------------------------------

ConfigureTurnKeyTemplates() {
  LogInfo "Optimizing TurnKey Linux LXC template sources..."
  local apl_info_pm="/usr/share/perl5/PVE/APLInfo.pm"

  # 1. Replace default metadata URL with USTC mirror
  if grep -q "releases.turnkeylinux.org/pve" "$apl_info_pm"; then
    # Note: Backup of APLInfo.pm is handled in Main
    sed -i "s|https://releases.turnkeylinux.org/pve|${MIRROR_URL}/turnkeylinux/metadata/pve|g" "$apl_info_pm"
    LogSuccess "Replaced TurnKey metadata URL in APLInfo.pm"
  else
    LogInfo "TurnKey metadata URL already updated or not found."
  fi

  # 2. Restart pvedaemon to reload configuration
  LogInfo "Restarting pvedaemon to apply metadata URL change..."
  systemctl restart pvedaemon
  LogSuccess "pvedaemon restarted."

  # 3. Configure systemd override to patch internal download URLs
  # TurnKey uses absolute URLs in their metadata, so we need a hook to fix them after download.
  LogInfo "Configuring systemd override for pve-daily-update..."
  local service_dir="/etc/systemd/system/pve-daily-update.service.d"
  
  mkdir -p "$service_dir"
  
  cat > "${service_dir}/update-turnkey-releases.conf" <<EOF
[Service]
ExecStopPost=/bin/sed -i 's|http://mirror.turnkeylinux.org|${MIRROR_URL}|' /var/lib/pve-manager/apl-info/releases.turnkeylinux.org
EOF
  LogSuccess "Created ${service_dir}/update-turnkey-releases.conf"

  # 4. Reload systemd and start update service
  LogInfo "Reloading systemd daemon..."
  systemctl daemon-reload
  
  LogInfo "Triggering pve-daily-update.service to fetch and patch templates..."
  systemctl start pve-daily-update.service
  
  LogSuccess "TurnKey Linux template complete."
}

# ---[ Main Logic ]-----------------------------------------------------------

Main() {
  # --- 1. Initial Checks and Setup ---
  LogInfo "Starting unified Proxmox VE post-install..."

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
    "/usr/share/perl5/PVE/CLI/pveceph.pm"
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
  
  read -r -p "Do you want to install 'openvswitch-switch' for advanced networking? [y/N] " response
  if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    LogInfo "Installing openvswitch-switch..."
    apt-get install -y openvswitch-switch
    LogSuccess "'openvswitch-switch' has been installed."
  else
    LogInfo "Skipping installation of 'openvswitch-switch'."
  fi

  # --- 5. Final Configuration Tweaks ---
  LogInfo "Updating URL for standard CT template downloads..."
  sed -i.bak "s|http://download.proxmox.com|${MIRROR_URL}/proxmox|g" /usr/share/perl5/PVE/APLInfo.pm
  LogSuccess "Standard CT template download URL has been updated."
  
  # --- 6. TurnKey Linux Configuration (New Feature) ---
  ConfigureTurnKeyTemplates
  
  # --- 7. Patch pveceph.pm to prevent repository overwrites ---
  LogInfo "Patching pveceph.pm to prevent repository file overwrites..."
  local pveceph_pm_file="/usr/share/perl5/PVE/CLI/pveceph.pm"

  if [[ ! -f "$pveceph_pm_file" ]]; then
    LogWarn "Could not find $pveceph_pm_file, skipping patch."
  else
    if [[ "$VERSION_CODENAME" == "bookworm" ]]; then
      # Patch for PVE 8.x (Bookworm) which uses ceph.list
      LogInfo "Applying patch for Bookworm (ceph.list)..."
      sed -i.bak 's|PVE::Tools::file_set_contents("/etc/apt/sources.list.d/ceph.list", $repolist);|#&|' "$pveceph_pm_file"
      LogSuccess "Patched pveceph.pm for ceph.list."
    elif [[ "$VERSION_CODENAME" == "trixie" ]]; then
      # Patch for PVE 9.x (Trixie) which uses ceph.sources
      LogInfo "Applying patch for Trixie (ceph.sources)..."
      sed -i.bak 's|PVE::Tools::file_set_contents("/etc/apt/sources.list.d/ceph.sources", $repo_source);|#&|' "$pveceph_pm_file"
      LogSuccess "Patched pveceph.pm for ceph.sources."
    else
      LogWarn "Unsupported Debian version for pveceph.pm patch, skipping."
    fi
  fi
  
  # --- 8. Restart Services ---
  LogInfo "Restarting PVE proxy services to apply changes..."
  systemctl restart pveproxy.service pvedaemon.service
  LogSuccess "Services restarted."
  LogSuccess "Proxmox script completed successfully!"
}

# ---[ Script Execution ]-----------------------------------------------------

Main "$@"
