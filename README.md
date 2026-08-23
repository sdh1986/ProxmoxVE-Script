# ProxmoxVE-Script

适用于中国大陆 Proxmox VE 用户的 PVE 8.x / 9.x 安装后一键优化脚本，自动将 Debian / Proxmox / Ceph / LXC CT 模板 / TurnKey Linux 等源切换到中国科学技术大学开源镜像站（USTC），并完成系统升级与相关补丁修复。

## 简介

ProxmoxVE-Script 是一款面向中国大陆 PVE 用户的安装后优化脚本，支持 PVE 8.x（Debian 12 bookworm）和 PVE 9.x（Debian 13 trixie）。

脚本会自动检测当前系统版本，并使用对应的仓库格式：

- PVE 8.x / Debian 12 bookworm：传统 `.list` 格式
- PVE 9.x / Debian 13 trixie：现代 DEB822 `.sources` 格式

脚本会关闭 PVE 企业订阅源，启用无订阅订阅源（no-subscription），将 Debian 系统源、Proxmox 源、Ceph 源、CT 模板元数据和下载地址，以及 TurnKey Linux LXC 模板源统一指向 USTC 镜像站，从而提升国内更新和下载体验。同时，脚本会对关键文件进行备份，执行系统 `full-upgrade`，并在最后安全重启 pveproxy 和 pvedaemon 服务。

## 功能特性

- 自动检测 PVE 版本，分别适配 bookworm（`.list`）和 trixie（`.sources`）仓库格式。
- 关闭 PVE 企业订阅源（bookworm 注释掉 `pve-enterprise.list`，trixie 重命名 `pve-enterprise.sources`）。
- 配置 Proxmox 无订阅源（`no-subscription`）和 Ceph 源，均指向 USTC 镜像站 `https://mirrors.ustc.edu.cn`。
- 将 Debian 系统源（含 `debian-security`）切换至 USTC。
- 修补 `/usr/share/perl5/PVE/APLInfo.pm` 中硬编码的 `http://download.proxmox.com`，使 CT 模板元数据和下载都走 USTC 镜像；幂等替换，已替换则跳过。
- 在 `full-upgrade` 完成后再次应用 APLInfo.pm 补丁，防止 `pve-manager` 升级覆盖文件后恢复为官方地址。
- 优化 TurnKey Linux LXC 模板源：
  - 将 APLInfo.pm 中的 `https://releases.turnkeylinux.org/pve` 替换为 USTC 的 `https://mirrors.ustc.edu.cn/turnkeylinux/metadata/pve`。
  - 通过 `pve-daily-update` 的 systemd override 文件，在每次服务执行后自动将下载元数据中的 `http://mirror.turnkeylinux.org` 替换为 USTC 镜像地址。
- 修补 `/usr/share/perl5/PVE/CLI/pveceph.pm` 中硬编码的 Proxmox 下载地址，并注释掉会覆盖 `ceph.list` / `ceph.sources` 的代码，避免 Ceph 源被还原。
- 所有被修改的配置文件都会备份到 `/root/pve_config_backups/<时间戳>/`。
- 在每次调用 APT 前等待锁释放：优先使用 `fuser` 检查锁文件，回退到 `pgrep` 检查进程，默认超时 300 秒。
- 执行 `apt-get update && apt-get full-upgrade -y`，并在最后清理 APT 缓存。
- 交互式提示（`autoremove`、安装 `openvswitch-switch`）均设置 60 秒超时，适合无人值守场景。
- 可选一键安装 `openvswitch-switch`，用于高级虚拟网络（OVS）。
- 脚本结尾通过后台 `nohup` 延迟 3 秒重启 `pveproxy` 和 `pvedaemon`，让 Web UI 连接可以自然恢复。

## 系统要求

- Proxmox VE 8.x（Debian 12 bookworm）或 PVE 9.x（Debian 13 trixie）。
- 以 `root` 用户运行。
- 节点能够访问 `https://mirrors.ustc.edu.cn` 以及 `https://raw.githubusercontent.com`（或 gh-proxy 加速地址）。

## 使用方法

### 国外节点直接下载

```bash
bash <(wget -qO- https://raw.githubusercontent.com/sdh1986/ProxmoxVE-Script/refs/heads/main/Pve.sh)
```

```bash
bash <(curl -sSL https://raw.githubusercontent.com/sdh1986/ProxmoxVE-Script/refs/heads/main/Pve.sh)
```

### 国内节点通过 gh-proxy 加速下载 或 jsdelivr cdn 加速下载

```bash
bash <(wget -qO- https://gh-proxy.com/https://raw.githubusercontent.com/sdh1986/ProxmoxVE-Script/refs/heads/main/Pve.sh)
```

```bash
bash <(curl -sSL https://gh-proxy.com/https://raw.githubusercontent.com/sdh1986/ProxmoxVE-Script/refs/heads/main/Pve.sh)
```

```bash
bash <(wget -qO- https://cdn.jsdelivr.net/gh/sdh1986/ProxmoxVE-Script@main/Pve.sh)
```

```bash
bash <(curl -sSL https://cdn.jsdelivr.net/gh/sdh1986/ProxmoxVE-Script@main/Pve.sh)
```

### 也可以先下载到本地再执行

```bash
wget https://raw.githubusercontent.com/sdh1986/ProxmoxVE-Script/refs/heads/main/Pve.sh
bash Pve.sh
```

或

```bash
wget https://raw.githubusercontent.com/sdh1986/ProxmoxVE-Script/refs/heads/main/Pve.sh
chmod +x Pve.sh
./Pve.sh
```

## 执行流程

脚本的主流程 `Main()` 按以下顺序执行：

1. 检查运行身份是否为 `root`，并读取 `/etc/os-release` 确定 Debian 版本代号；若不是 bookworm 或 trixie 则报错退出。
2. 将可能被修改的文件备份到 `/root/pve_config_backups/<时间戳>/`。
3. 根据系统版本调用对应的仓库配置函数：
   - `ConfigureReposForBookworm()`：使用 `.list` 格式。
   - `ConfigureReposForTrixie()`：使用 DEB822 `.sources` 格式。
4. 应用 `PatchAPLInfoURLs()`，将 APLInfo.pm 中的官方 CT 模板地址替换为 USTC 镜像地址。
5. 执行 `pveam update` 刷新 LXC 模板列表。
6. 调用 `UpdateSystem()`：等待 APT 锁、执行 `apt-get update && apt-get full-upgrade -y`、提示是否 `autoremove`、清理 APT 缓存。
7. 再次执行 `PatchAPLInfoURLs()`，因为 `full-upgrade` 可能覆盖 APLInfo.pm。
8. 提示是否安装 `openvswitch-switch`，60 秒内无应答则跳过。
9. 调用 `ConfigureTurnKeyTemplates()`：修改 APLInfo.pm 的 TurnKey 元数据地址，并写入 `pve-daily-update.service` 的 override 文件，随后触发服务更新模板列表。
10. 修改 `/usr/share/perl5/PVE/CLI/pveceph.pm`：替换其中硬编码的 Proxmox 下载 URL，并注释掉会覆盖 `ceph.list` / `ceph.sources` 的代码，避免 Ceph 源被还原。
11. 通过 `nohup` 延迟 3 秒后台重启 `pveproxy` 和 `pvedaemon`，输出提示完成信息。

## 备份与回滚

所有修改过的文件都会在脚本执行时自动备份到：

```text
/root/pve_config_backups/<YYYYMMDD-HHMMSS>/
```

例如：

```text
/root/pve_config_backups/20260121-143052/sources.list
/root/pve_config_backups/20260121-143052/APLInfo.pm
/root/pve_config_backups/20260121-143052/pveceph.pm
```

若需要手动回滚某个文件，请从最近的备份目录复制回原路径，然后更新 APT 并重启服务：

```bash
cp /root/pve_config_backups/<时间戳>/sources.list /etc/apt/sources.list
cp /root/pve_config_backups/<时间戳>/APLInfo.pm /usr/share/perl5/PVE/APLInfo.pm
apt-get update
systemctl restart pveproxy pvedaemon
```

TurnKey Linux 的 systemd override 文件位于：

```text
/etc/systemd/system/pve-daily-update.service.d/update-turnkey-releases.conf
```

如需移除该 hook，可以执行：

```bash
rm -f /etc/systemd/system/pve-daily-update.service.d/update-turnkey-releases.conf
systemctl daemon-reload
```

## 常见问题

### CT 模板下载仍然走 download.proxmox.com？

原因：在 `apt-get full-upgrade` 过程中，`pve-manager` 包可能会重新覆盖 `/usr/share/perl5/PVE/APLInfo.pm`，导致官方地址被恢复。

解决：重新运行一次脚本，或者手动执行以下命令并重启服务：

```bash
sed -i "s|http://download.proxmox.com|https://mirrors.ustc.edu.cn/proxmox|g" /usr/share/perl5/PVE/APLInfo.pm && systemctl restart pveproxy pvedaemon
```

### 想换成其他镜像站怎么办？

修改脚本顶部的 `MIRROR_URL` 常量：

```bash
readonly MIRROR_URL="https://mirrors.ustc.edu.cn"
```

将其改为目标镜像站地址。警告：该镜像站必须同时镜像以下目录树，否则脚本会出现源不完整或模板下载失败：

- `debian`
- `debian-security`
- `proxmox`
- `turnkeylinux`

### 重复运行安全吗？

安全。URL 替换是幂等的：APLInfo.pm 会先检测再替换，已替换则跳过；pveceph.pm 的替换在无匹配时自然为空操作。每次运行都会生成新的时间戳备份目录，不会覆盖旧备份。

### 支持 PVE 7 或更早版本吗？

不支持。脚本只支持基于 Debian 12 bookworm 的 PVE 8.x 和基于 Debian 13 trixie 的 PVE 9.x。检测到其他版本会直接报错退出。

## 注意事项

- 本脚本仅支持 Debian 12 bookworm 和 Debian 13 trixie，其他版本会拒绝运行。
- 必须以 `root` 身份执行。
- 脚本会执行 `apt-get full-upgrade`，可能升级大量软件包，建议在维护窗口或业务低峰期运行。
- 脚本结尾会自动重启 `pveproxy` 和 `pvedaemon`，期间 Proxmox Web UI 会短暂断开，稍后刷新页面重新登录即可。
- 虽然脚本已经做了备份，但在生产环境运行前仍建议手动快照或备份关键数据。
