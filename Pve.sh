#!/bin/bash

# Update CT templates
pveam update

# Disable PVE Enterprise source
PveEnterprisePath="/etc/apt/sources.list.d/pve-enterprise.list"
if [ -f "${PveEnterprisePath}" ]; then
  if ! grep -q "^#" "${PveEnterprisePath}"; then
    sed -i 's/^/# /' "${PveEnterprisePath}"
    echo "PVE Enterprise source has been disabled."
  else
    echo "PVE Enterprise source is already disabled. No action needed."
  fi
else
  echo "PVE Enterprise source file not found. Skipping."
fi

# Backup network interfaces and APT sources
TimeStamp=$(date +%Y%m%d_%H%M%S)
BackupPath="/etc/backup"
mkdir -p "${BackupPath}"

cp -p "/etc/network/interfaces" "${BackupPath}/interfaces_backup_${TimeStamp}"
cp -p "/etc/apt/sources.list" "${BackupPath}/sources.list_backup_${TimeStamp}"
cp -p "/usr/share/perl5/PVE/APLInfo.pm" "${BackupPath}/APLInfo.pm_backup_${TimeStamp}"
echo "Backup completed. Files saved to ${BackupPath}."

# Replace Debian sources with USTC mirrors
sed -i 's#http://ftp.debian.org#https://mirrors.ustc.edu.cn#g' "/etc/apt/sources.list"
sed -i 's#http://security.debian.org#https://mirrors.ustc.edu.cn/debian-security#g' "/etc/apt/sources.list"
echo "Debian sources replaced with USTC mirrors."

# Get system version information
if [ -f "/etc/os-release" ]; then
  . "/etc/os-release"
else
  echo "Cannot find /etc/os-release. System version information is unavailable."
  exit 1
fi

# Replace PVE no-subscription source
PveNoSubscriptionPath="/etc/apt/sources.list.d/pve-no-subscription.list"
if [ ! -f "${PveNoSubscriptionPath}" ] || ! grep -q "mirrors.ustc.edu.cn" "${PveNoSubscriptionPath}"; then
  echo "deb https://mirrors.ustc.edu.cn/proxmox/debian/pve $VERSION_CODENAME pve-no-subscription" > "${PveNoSubscriptionPath}"
  echo "PVE no-subscription source added."
else
  echo "PVE no-subscription source already exists. No action needed."
fi

# Replace Ceph repository
CephListPath="/etc/apt/sources.list.d/ceph.list"
if [ -f "${CephListPath}" ]; then
  CEPH_CODENAME=$(ceph -v | awk '/ceph version / {print $(NF-1)}')
  if [ -n "${CEPH_CODENAME}" ]; then
    echo "deb https://mirrors.ustc.edu.cn/proxmox/debian/ceph-${CEPH_CODENAME} $VERSION_CODENAME no-subscription" > "${CephListPath}"
    echo "Ceph repository updated."
  else
    echo "Unable to determine Ceph codename. Skipping update."
  fi
else
  echo "Ceph source file not found. Skipping."
fi

# Clean APT cache
apt clean all
echo "APT cache cleaned."

# Update and upgrade system
apt update && apt full-upgrade -y
echo "System updated and fully upgraded."

# Install OpenvSwitch
if ! dpkg -l | grep -q "openvswitch-switch"; then
  apt install openvswitch-switch -y
  echo "OpenvSwitch installed."
else
  echo "OpenvSwitch is already installed. No action needed."
fi

# Replace LXC/LXD container sources with USTC mirrors
LXCSourceFile="/usr/share/perl5/PVE/APLInfo.pm"
if [ -f "${LXCSourceFile}" ]; then
  if ! grep -q "mirrors.ustc.edu.cn" "${LXCSourceFile}"; then
    #sed -i.backup_${TimeStamp} 's|http://download.proxmox.com|https://mirrors.ustc.edu.cn/proxmox|g' "${LXCSourceFile}"
    sed -i 's|http://download.proxmox.com|https://mirrors.ustc.edu.cn/proxmox|g' "${LXCSourceFile}"
    echo "LXC/LXD container sources replaced with USTC mirrors. Backup created: ${LXCSourceFile}.backup_${TimeStamp}"
  else
    echo "LXC/LXD container sources already set to USTC mirrors. No action needed."
  fi
else
  echo "LXC/LXD source file not found. Skipping."
fi

# Restart relevant services to apply changes
systemctl restart pvedaemon.service pveproxy.service
echo "Relevant services restarted."
