#!/bin/bash
# Exit on error
set -e
# Catch errors in pipelines
set -o pipefail

# Logging functions
LogInfo() {
  echo -e "\033[1;32m[INFO] $1\033[0m"
}

LogWarn() {
  echo -e "\033[1;33m[WARNING] $1\033[0m"
}

LogError() {
  echo -e "\033[1;31m[ERROR] $1\033[0m"
}

# Ensure backup directory exists
EnsureBackupDir() {
  local BackupDir="$1"
  if [[ ! -d "${BackupDir}" ]]; then
    mkdir -p "${BackupDir}"
    LogInfo "Backup directory created: ${BackupDir}"
  fi
}

# Backup a file
BackupFile() {
  local SrcFile="$1"
  local BackupDir="$2"
  local TimeStamp="$3"
  
  if [[ -f "${SrcFile}" ]]; then
    cp -p "${SrcFile}" "${BackupDir}/$(basename "${SrcFile}")_backup_${TimeStamp}"
    LogInfo "Backup of ${SrcFile} created in ${BackupDir}"
  else
    LogWarn "${SrcFile} not found. Skipping backup."
  fi
}

# Disable PVE Enterprise source
DisablePveEnterpriseSource() {
  local EnterprisePath="/etc/apt/sources.list.d/pve-enterprise.list"
  
  if [[ -f "${EnterprisePath}" ]]; then
    if ! grep -q "^#" "${EnterprisePath}"; then
      sed -i 's/^/# /' "${EnterprisePath}"
      LogInfo "PVE Enterprise source has been disabled."
    else
      LogInfo "PVE Enterprise source is already disabled."
    fi
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
    sed -i "s|${OldUrl}|${NewUrl}|g" "${File}"
    LogInfo "Replaced ${OldUrl} with ${NewUrl} in ${File}."
  else
    LogWarn "${File} not found. Skipping source replacement."
  fi
}

# Update and upgrade system
UpdateAndUpgrade() {
  apt update && apt full-upgrade -y
  LogInfo "System updated and fully upgraded."
}

# Install a package
InstallPackage() {
  local Package="$1"
  
  if ! dpkg -l | grep -q "${Package}"; then
    apt install -y "${Package}"
    LogInfo "${Package} installed."
  else
    LogWarn "${Package} is already installed. No action needed."
  fi
}

# Main program logic
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
    . "/etc/os-release"
  else
    LogError "/etc/os-release not found. Exiting."
    exit 1
  fi

  # Replace PVE no-subscription source
  local PveNoSubscriptionPath="/etc/apt/sources.list.d/pve-no-subscription.list"
  echo "deb https://mirrors.ustc.edu.cn/proxmox/debian/pve $VERSION_CODENAME pve-no-subscription" >"${PveNoSubscriptionPath}"
  LogInfo "PVE no-subscription source updated."

  # Replace Ceph repository
  local CephListPath="/etc/apt/sources.list.d/ceph.list"
  if [[ -f "${CephListPath}" ]]; then
    local CephCodename
    CephCodename=$(ceph -v | awk '/ceph version / {print $(NF-1)}')
    if [[ -n "${CephCodename}" ]]; then
      echo "deb https://mirrors.ustc.edu.cn/proxmox/debian/ceph-${CephCodename} $VERSION_CODENAME no-subscription" >"${CephListPath}"
      LogInfo "Ceph repository updated."
    else
      LogWarn "Ceph codename could not be determined. Skipping Ceph repository update."
    fi
  else
    LogWarn "Ceph source file not found. Skipping."
  fi

  apt clean all
  LogInfo "APT cache cleaned."

  UpdateAndUpgrade

  InstallPackage "openvswitch-switch"

  ReplaceSources "/usr/share/perl5/PVE/APLInfo.pm" "http://download.proxmox.com" "https://mirrors.ustc.edu.cn/proxmox"

  systemctl restart pvedaemon.service pveproxy.service
  LogInfo "Relevant services restarted."
}

# Execute the main program
Main "$@"
