# AvaotaOS 当前状态

> 2026-09-14。目标: Avaota A1 / T527 / Ubuntu 24.04 noble gnome / 内核 5.15.154 BSP。
> 详细排查过程在 `AGENTS.md`。下次会话先读本文再动手。

## 已经能用的

- 主线 u-boot v2026.07 + jernejsk ATF a523-v4, 能过 systemd, GDM 在跑
- HDMI 接采集卡 (EDID 名称 HDP-V104 / demoset-1): 现卡已用 debug EDID 绕过全 0 header, 输出 4K60 HDMI 而非 DVI。内核补丁 0010 还没进现卡内核
- SD 卡 `mmcblk0` 正常 (内核补丁 0006: sdc0 CCLK_DIV=/2)
- WiFi AIC8800 `wlan0` 已联网; SSH 走 `ssh.socket` (镜像自带 openssh-server, 不必再装)
- 板载 0.96" ST7789V `/dev/fb0`; DRM `card0-HDMI-A-1` / `card0-DP-1`。HDMI 接采集卡 (见下第 3 条)
- GPU panfrost Mali-G57, 最高 696MHz (648/744/792 被拒是 vf3920 bin 规格, 不是故障)
- 音频 codec 内核正常 (`sudo aplay -l` 能列出 `audiocodec`); 用户已进 `audio` 组, 需重新登录后再测
- PMIC 备注: 板上丝印为 AXP717B; SyterKit eFEX 将 I2C 0x35/0x36 按 AXP2202/AXP1530 模型初始化, 主线 U-Boot DTS 则按 AXP717/AXP323 描述同一组电源。Linux 当前 `reg_cldo3` / `reg_ext_axp1530_dcdc1` 映射与实测 DVM 电压一致; 因而 SyterKit 没有单独的 `axp717b` 文件并不表示 PMIC 未使用, 精确料号仍待原理图或 I2C ID 确认
- 构建: 显示修复、gzip initramfs、hostname、用户组、init-resize wants 链接、aic8800 模块加载、smartmontools mask、bluez/cloud-guest-utils 包

- 内核 defconfig 已补 snap 所需的 ext4 security xattr, 以及 NFS/CIFS fscache (见下「内核配置」). **现卡内核还没吃到**

默认账号 `avaota` / `avaota`, sudo 要密码。

## 待办 (按优先级)

### 1. GNOME 缺常见应用 — 构建已修, 现卡/旧 tar 未吃到

`ubuntu-desktop` 是 metapackage: **Depends** 只有 GDM/gnome-shell/nautilus 等壳, Firefox、LibreOffice、gnome-software、eog、evince、file-roller、gnome-text-editor 等全是 **Recommends**。`mmdebstrap --include` **默认不装 Recommends** (和板上 `apt install` 相反), 所以镜像里 metapackage 在、应用不在。卸载再装 `ubuntu-desktop` 会按 Ubuntu 默认把 Recommends 全拉回来, 看起来像"少了一大堆依赖"。

第一版 `apt-get install --install-recommends ubuntu-desktop` **无效**: metapackage 在 mmdebstrap 里已经装过, apt 报 already newest 然后 0 packages, Recommends 不会补。2026-09-18 的 973MB tar 仍缺 eog/evince/LibreOffice/gnome-software/Yaru 等 (~100 个 Recommends)。

现已改成 `apt-cache depends` 展开 Recommends 再按包名安装 (仍跳过 firefox/thunderbird/snapd 的 snap 壳, 以及 cloud-init/flash-kernel)。

要吃到: **必须删 rootfs tar 再编**, pack 不会重建 rootfs。旧 973MB tar 不能用。

```bash
sudo rm -f build_dir/rootfs-noble-gnome.tar.gz
./build_all.sh
```

现卡若根分区仍是 ~3G, 先扩容再 `sudo apt install --install-recommends ubuntu-desktop` (会装 LibreOffice 等, 体积明显变大)。Firefox 在 noble 是 snap, 本构建不预装。

### 2. cpufreq / cluster1 切频死机 — 已解决并验证 (2026-09-14)

根因是两件事叠在一起, 不是单纯打开 `CONFIG_AW_CPUFREQ_DT` 就能好:

1. **pll-cpu3 重锁时 cluster1 还挂在 PLL 上**会冻核。`0008` 在 PRE 把 CPU mux 切到 `dcxo24M`, POST/ABORT 再切回; CPU PLL 不再开 SSC。第一版用 `pll-peri0-600m` 不够。
2. **`cpu@400` 没有 `cpu-supply`**。日志里 CPU4 `768→840` 已经成功 (`EM: invalid perf. state: -22` 印出来了), 随后默认 `performance` 调速器把 cluster1 拉到最高频, 电压仍停在 u-boot 的 ~0.9V, 当场死机。主线 dts 写明 AXP1530/AXP323 DCDC1 = `vdd-cpub`。`0009` 给 `&cpu4` 接上 `<&reg_ext_axp1530_dcdc1>`。
3. **AXP1530/AXP323 双相 DVM**: 主线 DTS 注明 DCDC2 与 DCDC1 并联, SyterKit 会同步设置两路; 已在 defconfig 启用 `CONFIG_AW_AXP1530_WORKAROUND_DVM`。2026-09-14 实测两路在 1.15 V 满载时保持一致。
4. **DSUFREQ 仍关**: `pll-cpu2` 同样没有 mux 旁路, 两个 policy 起来后会在 CPU 切频回调里 `clk_set_rate` 卡死。先保证 CPU DVFS 能起。

2026-09-14 实测: 无 `cpufreq.off`, 两个 policy 正常建立; CPU0 达到 1.416 GHz, CPU4 达到 1.8 GHz。8 个 CPU 满载 20 秒无复位, uptime 持续增长。板上检查:

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies
cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_available_frequencies
```

重编: `sudo rm -f build_dir/avaota-a1-kernel-pkgs/.done` 后 `./build_all.sh` (mklinux 现在会 `git checkout -- .` 再打补丁, 更新后的 0008 不会打在旧 0008 上面)。

### 3. HDMI 采集卡无画面 (EDID 头全 0 → DVI) — 内核补丁已写, 现卡已绕过

HDMI 口接的是采集卡, 不是显示器。采集卡 EDID (HDP-V104 / demoset-1) 前 16 字节全 0, `drm_get_edid` 丢弃, BSP 驱动改走 **DVI 1080p** (不发 AVI), 采集端采不到。注入修复 header 的 EDID 后 4K60 HDMI 出图, vsync `err=0`。

- 内核: `patches/.../0010-drm-sunxi-hdmi-repair-zero-edid-header.patch` (**还没进现卡**, 需删 `.done` 重编)
- 现卡: `avaota-hdmi-edid.service` + `edid_debug=1`; GDM `idle-delay=0` (没键盘会熄屏, 采集也会断)
- 免重编脚本: `scripts/fix-hdmi-edid.sh`
- 采集端若只要 1080p: GNOME 显示设置改 1920x1080。kernel 吃到 0010 后可 `systemctl disable --now avaota-hdmi-edid`

### 4. 蓝牙未通 — 低

WiFi=SDIO 已通; BT=UART `ttyAS1` (PG6-9), 复位 PG12 (`sunxi-bt` rfkill), wake PG11。

现象: `hciattach` 报 Device setup complete, 但 `BDADDR 00:00:00:00:00:00`、RX=0、HCI Reset (`0x1001`) timeout = UART 挂上了芯片没回包。`any` 不等芯片应答。

卡点:

- 芯片默认睡, 要 `echo 1 > /proc/bluetooth/sleep/btwrite` (aic8800_btlpm); 当前内核该模块 probe 失败 (`No such device` / 先前 EBUSY), 节点不存在
- 必须 `sudo rfkill unblock all` 松开 PG12 复位; `gpiofind`/`gpioset` 必须 sudo
- 构建已有补丁 `patches/kernel/avaota-a1-bsp/patches/0007-*.patch` 和 `target/services/avaota-bluetooth/`, **0007 还没进现卡内核**

现卡可试 (先 `killall hciattach`):

```bash
sudo rfkill unblock all
sudo mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
n=$(sudo sed -n 's/^ gpio-\([0-9][0-9]*\).*PG11.*/\1/p' /sys/kernel/debug/gpio | head -1)
echo "$n" | sudo tee /sys/class/gpio/export
echo out | sudo tee /sys/class/gpio/gpio$n/direction
echo 1 | sudo tee /sys/class/gpio/gpio$n/value
sudo hciattach -s 1500000 /dev/ttyAS1 any 1500000 flow nosleep
hciconfig -a   # 成功则非零 MAC、UP RUNNING、RX≠0
```

内核重编 (吃 0007): `sudo rm -f build_dir/avaota-a1-kernel-pkgs/.done`

### 5. snapd setcap EOPNOTSUPP + 网络文件系统 — defconfig 已改, 需重编内核

`snapd` postinst `setcap` 报 Operation not supported: 缺 `CONFIG_EXT4_FS_SECURITY` (file capabilities 走 ext4 `security.*` xattr)。已写入板级 defconfig, 并补:

- snap: `EXT4_FS_POSIX_ACL`, `SQUASHFS_XATTR`, `CGROUP_BPF`
- NFS/CIFS: `FSCACHE` + `CACHEFILES` + `NFS_FSCACHE` + `CIFS_FSCACHE`; NFS 用 kernel DNS (关掉 LEGACY_DNS); `NFSD_V4_SECURITY_LABEL`
- CIFS/SMB/NFS/BTRFS 主体本来就是 y (含 ACL/xattr/NFSv4.2/ksmbd); 关掉不安全的 `CIFS_DEBUG_DUMP_KEYS`
- 未开 RDMA `CIFS_SMB_DIRECT` / `SMB_SERVER_SMBDIRECT` (这块板没有 IB)

```bash
sudo rm -f build_dir/avaota-a1-kernel-pkgs/.done
./build_all.sh
```

新内核起来后: `zcat /proc/config.gz | grep EXT4_FS_SECURITY` 应为 y, 然后 `sudo apt install -f` 或 `sudo dpkg --configure snapd`.

## 其它已知、暂不挡用

- 根分区扩容: 构建已修 (wants 链接 + 新 init-resize.sh)。**现卡若仍是 ~3G/29.7G**, 在板子上:

```bash
echo ',+' | sudo sfdisk --no-reread -N 2 /dev/mmcblk0
sudo partx -u /dev/mmcblk0
sudo resize2fs /dev/mmcblk0p2
df -hT /
```

- eMMC `mmcblk1` 29.1G 空片, 不是 SD
- eth0/eth1 PHY 正常, 没插网线则 NO-CARRIER
- `aic8800_btlpm` 未进当前运行内核; 包列表已加 `bluez` (现卡可能因空间未装上)

## 构建缓存注意

- rootfs tar 存在则 skip mkrootfs (`rootfs-noble-gnome.tar.gz`)
- 内核缓存键是 `${LINUX_CONFIG}-${LINUX_PATHDIR}`, **只改 patches/ 不会自动重编**, 需删 `.done`
- `mklinux.sh` 打补丁前会 `git checkout -- .` 还原 linux 树, 再按 `patches/kernel/avaota-a1-bsp/patches/` 顺序应用 (0001–0009) 并覆盖 defconfig。更新已有补丁不必再手工还原源码
- `pack.sh` 每次都跑; 新 init-resize / bluetooth 脚本 / 用户组会打进旧 tar, 不必为这些重建 rootfs
- 新桌面应用列表要改 `gnome-packages.list` 或 mmdebstrap recommends, **必须重建 rootfs tar**
