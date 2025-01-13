#!/bin/bash
# Exit on error
set -e
# Catch errors in pipelines
set -o pipefail

# ---[ Logging Functions ]-----------------------------------------------------

LogInfo() {
  echo -e "\033[1;32m[INFO] $1\033[0m"
}

LogWarn() {
  echo -e "\033[1;33m[WARNING] $1\033[0m"
}

LogError() {
  echo -e "\033[1;31m[ERROR] $1\033[0m"
}

# ---[ Helper Functions ]-----------------------------------------------------

# Ensure backup directory exists
EnsureBackupDir() {
  local BackupDir="$1"
  if [[ ! -d "${BackupDir}" ]]; then
    mkdir -p "${BackupDir}"
    LogInfo "Backup directory created: ${BackupDir}"
  else
    LogInfo "Backup directory already exists: ${BackupDir}" # Added: Indication if dir exists
  fi
}

# Backup a file
BackupFile() {
  local SrcFile="$1"
  local BackupDir="$2"
  local TimeStamp="$3"

  if [[ -f "${SrcFile}" ]]; then
    # Use 'cp -a' to preserve all attributes, including timestamps
    cp -a "${SrcFile}" "${BackupDir}/$(basename "${SrcFile}")_backup_${TimeStamp}"
    LogInfo "Backup of ${SrcFile} created in ${BackupDir}"
  else
    LogWarn "${SrcFile} not found. Skipping backup."
  fi
}

# Disable PVE Enterprise source
DisablePveEnterpriseSource() {
  local EnterprisePath="/etc/apt/sources.list.d/pve-enterprise.list"

  if [[ -f "${EnterprisePath}" ]]; then
    # Simplified check and modification
    sed -i '/^[^#]/s/^/# /' "${EnterprisePath}"
    LogInfo "PVE Enterprise source has been disabled (if it was enabled)."
  else
    LogWarn "PVE Enterprise source file not found. Skipping."
  fi
}

# Replace repository URLs
ReplaceSources() {
  local File="$1"
  local OldUrl="$2"
  local NewUrl="$3"

  if [[ -f "${File}" ]]; then
    # Use 'sed -i.bak' to create a backup of the original file
    sed -i.bak "s|${OldUrl}|${NewUrl}|g" "${File}"
    LogInfo "Replaced ${OldUrl} with ${NewUrl} in ${File}. Backup created."
  else
    LogWarn "${File} not found. Skipping source replacement."
  fi
}

# Update and upgrade system
UpdateAndUpgrade() {
  apt update && apt full-upgrade -y
  LogInfo "System updated and fully upgraded."

  # Prompt user before running apt autoremove
  read -r -p "Do you want to run 'apt autoremove' to remove unused packages? [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY])
      apt autoremove -y
      LogInfo "Unused packages removed."
      ;;
    *)
      LogInfo "Skipping 'apt autoremove'."
      ;;
  esac
  
  apt clean
  LogInfo "APT cache cleaned."
}

# Install a package
InstallPackage() {
  local Package="$1"

  # Use 'dpkg-query' for a more robust check
  if ! dpkg-query -W -f='${Status}' "${Package}" 2>/dev/null | grep -q "install ok installed"; then
    apt install -y "${Package}"
    LogInfo "${Package} installed."
  else
    LogWarn "${Package} is already installed. No action needed."
  fi
}

# ---[ Main Logic ]-----------------------------------------------------------

Main() {
  local TimeStamp
  local BackupPath="/home/backup"
  TimeStamp=$(date +%Y%m%d_%H%M%S)

  LogInfo "Updating CT templates..."
  pveam update

  DisablePveEnterpriseSource

  EnsureBackupDir "${BackupPath}"
  BackupFile "/etc/network/interfaces" "${BackupPath}" "${TimeStamp}"
  BackupFile "/etc/apt/sources.list" "${BackupPath}" "${TimeStamp}"
  BackupFile "/usr/share/perl5/PVE/APLInfo.pm" "${BackupPath}" "${TimeStamp}"

  ReplaceSources "/etc/apt/sources.list" "http://ftp.debian.org" "https://mirrors.ustc.edu.cn"
  ReplaceSources "/etc/apt/sources.list" "http://security.debian.org" "https://mirrors.ustc.edu.cn/debian-security"

  # Load system version information
  if [[ -f "/etc/os-release" ]]; then
    # Use 'source' instead of '.' for better compatibility
    source "/etc/os-release"
  else
    LogError "/etc/os-release not found. Exiting."
    exit 1
  fi

  # Replace PVE no-subscription source
  local PveNoSubscriptionPath="/etc/apt/sources.list.d/pve-no-subscription.list"
  # Directly write to the file, using a single command
  cat > "${PveNoSubscriptionPath}" << EOF
deb https://mirrors.ustc.edu.cn/proxmox/debian/pve ${VERSION_CODENAME} pve-no-subscription
EOF
  LogInfo "PVE no-subscription source updated."

  # Replace Ceph repository
  local CephListPath="/etc/apt/sources.list.d/ceph.list"
  if [[ -f "${CephListPath}" ]]; then
    local CephCodename
    CephCodename=$(ceph -v 2>/dev/null | awk '/ceph version / {print $(NF-1)}')
    if [[ -n "${CephCodename}" ]]; then
        # Directly write to the file, using a single command
        cat > "${CephListPath}" << EOF
deb https://mirrors.ustc.edu.cn/proxmox/debian/ceph-${CephCodename} ${VERSION_CODENAME} no-subscription
EOF
        LogInfo "Ceph repository updated."
    else
      LogWarn "Ceph codename could not be determined. Skipping Ceph repository update."
    fi
  else
    LogWarn "Ceph source file not found. Skipping."
  fi

  UpdateAndUpgrade

  InstallPackage "openvswitch-switch"

  ReplaceSources "/usr/share/perl5/PVE/APLInfo.pm" "http://download.proxmox.com" "https://mirrors.ustc.edu.cn/proxmox"

  # Add script completion message
  LogInfo "Script completed successfully."

  # Restart Services pveproxy&pvedaemon
  LogInfo "Relevant services restarted."
  systemctl restart pveproxy.service pvedaemon.service

}

# Execute the main program, ensuring proper error handling
Main "$@" || { LogError "Script failed."; exit 1; }
