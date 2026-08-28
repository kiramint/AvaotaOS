# AvaotaOS 当前状态

> 2026-08-29。目标: Avaota A1 / T527 / Ubuntu 24.04 noble gnome / 内核 5.15.154 BSP。
> 详细排查过程在 `AGENTS.md`。下次会话先读本文再动手。

## 已经能用的

- 主线 u-boot v2026.07 + jernejsk ATF a523-v4, 能过 systemd, GDM 在跑
- SD 卡 `mmcblk0` 正常 (内核补丁 0006: sdc0 CCLK_DIV=/2)
- WiFi AIC8800 `wlan0` 已联网; SSH 走 `ssh.socket` (镜像自带 openssh-server, 不必再装)
- 板载 0.96" ST7789V `/dev/fb0`; DRM `card0-HDMI-A-1` / `card0-DP-1` (线没插时 disconnected 是正常的)
- GPU panfrost Mali-G57, 最高 696MHz (648/744/792 被拒是 vf3920 bin 规格, 不是故障)
- 音频 codec 内核正常 (`sudo aplay -l` 能列出 `audiocodec`); 用户已进 `audio` 组, 需重新登录后再测
- 构建: 显示修复、gzip initramfs、hostname、用户组、init-resize wants 链接、aic8800 模块加载、smartmontools mask、bluez/cloud-guest-utils 包

默认账号 `avaota` / `avaota`, sudo 要密码。

## 待办 (按优先级)

### 1. GNOME 缺常见应用 — 高

`os/noble/gnome-packages.list` 只有一行 `ubuntu-desktop`。`mkrootfs.sh` 用 mmdebstrap `--include=...`, **默认不装 Recommends**。Ubuntu 桌面里 Firefox、LibreOffice、gnome-software、文件归档工具等多半是 Recommends, 所以 metapackage 装了仍像精简桌面。

下一步建议:

- 对比官方 `ubuntu-desktop` / `ubuntu-desktop-minimal` 的 Depends vs Recommends
- 看 mmdebstrap 是否加 `--aptopt='Apt::Install-Recommends "true"'` 或把常用应用写进 `gnome-packages.list`
- 现卡 3G 根分区可能装不下, 先扩容再 apt

### 2. 无 cpufreq, CPU 锁 768MHz — 中

故意关掉 `CONFIG_AW_CPUFREQ_DT` / `CONFIG_ARM_AW_SUN50I_CPUFREQ_NVMEM`: 主线 BL31 下 cluster1 (`pll-cpu3`) 首次切频在 `clk_set_rate`/`__clk_notify` 死循环。8×A55 停在 u-boot 的 768MHz。规格大约 cluster0 ≤1.42GHz、cluster1 ≤1.8–2.0GHz, CPU 活大约只有 40–50%。GPU/显示不受影响。

下一步: 修 cluster1 pll-cpu3, 不要直接打开这两个 config。

### 3. 蓝牙未通 — 低

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
- `pack.sh` 每次都跑; 新 init-resize / bluetooth 脚本 / 用户组会打进旧 tar, 不必为这些重建 rootfs
- 新桌面应用列表要改 `gnome-packages.list` 或 mmdebstrap recommends, **必须重建 rootfs tar**
