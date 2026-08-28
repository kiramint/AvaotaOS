# Avaota A1 (T527) 显示问题排查记录

> 更新时间: 2026-08-29 (已能进 systemd/GNOME; 待办见仓库根目录 status.md)。目标设备: Avaota A1, T527, Ubuntu 24.04, 内核 5.15.154 BSP (sun4i-drm)。

## 构建默认值调整 (2026-08-23)

- `build_all.sh` `default_param()`: VERSION 默认 **noble**, TYPE 默认 **gnome**, MIRROR 默认 **https://mirrors.ustc.edu.cn/ubuntu-ports/** (其余默认值不变)
- sudo 策略: 删除 mkrootfs.sh 的 `/etc/sudoers.d/010_avaota-nopassword` (NOPASSWD); avaota 进 sudo 组由 pack.sh `usermod -aG sudo,video,render,dialout,tty,audio,bluetooth,plugdev` 完成, **sudo 需要密码**
> 本仓库是系统编译脚本。运行系统排查修复已固化进构建系统 (见下"构建系统集成"章节); 已部署系统可用 `scripts/fix-display.sh` 修复。

## 构建系统集成 (2026-08-22, 本次改动)

支持范围精简: **仅 Avaota A1 + Ubuntu 22.04/24.04 (jammy/noble) + cli/gnome**。构建时自动应用全部显示修复:

| 修复 | 集成位置 |
|---|---|
| DP 口 eDP→DP 模式 (EDID 自动) | `patches/kernel/avaota-a1-bsp/patches/0001-*.patch` (内核 dts: `&drm_edp` compatible 覆盖为 `allwinner,drm-dp`) |
| cma=256M | `boards/avaota-a1.conf` BOOTARGS |
| mutter AFBC 黑屏绕过 (仅 gnome) | `scripts/mkrootfs.sh` `setup_display_fixes()`: gdm drop-in + /etc/environment |
| 用户组 video,render,dialout,tty,audio,bluetooth,plugdev | `scripts/pack.sh` `setup_users()`: usermod -aG (组不存在则 `groupadd -f`) |
| 内核缺失配置 (AppArmor/nftables/VETH/WIREGUARD/容器栈等) | `patches/kernel/avaota-a1-bsp/files/arch/arm64/configs/sun55i_t527_bsp_defconfig` (原版+追加) |

- 内核补丁机制: `boards/avaota-a1.conf` `LINUX_PATHDIR="avaota-a1-bsp"` → mklinux.sh `patch_kernel()` 应用 `patches/kernel/avaota-a1-bsp/{patches,files}/`
- 内核包缓存判断已改为 `${LINUX_CONFIG}-${LINUX_PATHDIR}` (build_all.sh + mklinux.sh), 修改补丁后会正确触发重建
- 内核配置补充要点 (对比通用 Ubuntu 5.15 config, 参考 config 为 x86 需按符号核对): **SECURITY/APPARMOR** (Ubuntu 用户态强依赖, 原版整体关闭!), CGROUP_FREEZER/VETH/NF_TABLES (容器/防火墙), WIREGUARD/TUN/VXLAN/BONDING/VLAN (VPN/虚拟网络), BTRFS/XFS/NTFS/ISO9660/UDF (移动介质), FANOTIFY/BINFMT_MISC, CRYPTO_USER_API/CHACHA20POLY1305/ECDSA, FTRACE/KPROBES/PSI/TASKSTATS (可观测), DEVFREQ_THERMAL (GPU 过热降频), GPIO_SYSFS/HIDRAW/IIO/UIO/PTP/USB gadget mass storage

## 构建健壮性修复 (2026-08-23)

起因: 一次被中断的 `git clone --depth=1` 留下半截 linux 工作树 (缺 `scripts/` 等, git status 7 万+删除), fetch.sh 走 `git pull` 路径未察觉, make 报 `scripts/Kbuild.include: 没有那个文件或目录`。同时暴露多个级联问题, 已修复:

- **fetch.sh**: `clone_linux()` 前置 `check_linux_tree()` (哨兵文件 `scripts/Kbuild.include` 缺失 → 删树重克隆); 克隆后 `check_linux_complete()` 校验, 不完整 exit 2; `do_clone_linux()` 3 次重试 + gitee 兜底 (AvaotaSBC/linux 浅克隆 600MB+, 网络抖动常见)
- **build_all.sh**: fetch.sh 退出码检查 (失败即 exit 2; 此前 linux 克隆失败被无视, 继续跑 bootloader/mklinux 才在别处炸)
- **mklinux.sh**: `patch_kernel()` 改幂等非交互 — dry-run 三态: 可应用→`patch -N -p1`; 已应用→skip; 冲突→exit 2。此前重复构建会交互式问 "Assume -R?" 且被答 y → **把 dts 补丁反向卸载**
- **build_all.sh**: mklinux/mkrootfs 后校验产物 (.done / rootfs tar), 失败即 exit 2; `mkdir rootfs` 改 `mkdir -p` (原来 File exists 失败会经 `&&` 静默跳过 mkrootfs)
- **pack.sh**: `pack_sdcard()` 入口校验 rootfs tar / deb-data / kernel-pkgs 存在 (原来对缺失文件 du 得空值 → `$(( *3+256++880 ))` 算术错误)
- **boards/avaota-a1.conf**: `SYTERKIT_BRANCH` dev→main (上游 YuzukiHD/SyterKit 已删 dev 分支, 现仅剩 main/0.5.0)

### 第二轮 (同日, mmdebstrap/binfmt 与 bootloader 假 .done)

- **主机侧根因**: `qemu-user-static` 未安装 (可能被 autoremove), `/proc/sys/fs/binfmt_misc/` 无 qemu-aarch64 条目 → mmdebstrap 报 `arm64 can neither be executed natively nor via qemu user emulation`。修复: 新版 Ubuntu (25.04+) 上 `qemu-user-static` 已是**虚拟包**, 真实包名 `qemu-user-binfmt`(-hwe); 旧版直接装 `qemu-user-static`。装后 `sudo systemctl restart systemd-binfmt`, 验证 `/proc/sys/fs/binfmt_misc/qemu-aarch64` 存在。**已集成**: build_all.sh `ensure_qemu_binfmt()` 自适应安装三种包名并校验注册; 同时删除上游笔误的 `apt install diaout` (包不存在, 每次报错)
- **mkrootfs.sh**: run_debootstrap 前置 binfmt 检查 (缺失给出修复命令); mmdebstrap 失败 exit 2; 成功后校验 `${ROOTFS}/bin/sh`。此前失败后仍继续跑完并打出垃圾 tar
- **bootloader-sunxi-syterkit.sh**: build/apply 全程 fail-fast — 源码目录缺失、cmake/make 失败、产物 cp 失败均 exit 2; `.done` 只在全部产物 (uInitrd/extlinux/bl31/scp/splash/bootloader-syterkit.bin) 校验通过后写入。此前 syterkit 克隆失败时 cp 全静默失败但 `.done` 照写 → build_all 误判跳过 → pack 时 dd 找不到 bin
- **build_all.sh**: bootloader 跳过条件增加 `-f bootloader-syterkit.bin` (仅 .done 不可信)
- **write_bootloader()**: dd 前校验 bin 存在
- **注意**: 垃圾产物 `rootfs-*.tar.gz` / `sdcard.img` 需手动删除, 否则被当作有效缓存跳过对应构建步骤

### 第三轮 (同日, SyterKit main 分支工具链 / pack.sh chroot)

- **SyterKit main 分支 `avaota-a1.cmake` 强制要求 `LINARO_GCC_721_PATH`** (gcc-linaro-7.2.1 arm-linux-gnueabi), 而 releases.linaro.org **已停服** (301 → linaro.org/contact)。修复: `patches/bootloader/avaota-a1/0001-*.patch` 回退系统 `arm-none-eabi-gcc` (gcc 14.2, 已实测完整编译出 `extlinux_boot_bin_card.bin`); `bootloader-sunxi-syterkit.sh` `patch_bootloader()` 幂等应用 (dry-run 三态, 同 patch_kernel); `build_bootloader` 每次重建前 `rm -rf build-${BOARD}` (清掉失败 configure 的 CMakeCache); fetch.sh `clone_syterkit` pull 前 `git checkout -- .` (还原补丁避免冲突)
- **pack.sh 裸 `chroot rootfs_dir` heredoc**: 无命令时 chroot 执行 `$SHELL` → 主机 root shell 是 zsh → `chroot: failed to run command '/usr/bin/zsh'` 且 **内核 deb 安装段整体没跑**。修复: 显式 `chroot ... /bin/bash`
- **pack.sh `cat <<EOF | chroot adduser X && addgroup X sudo`**: 优先级使 addgroup 跑在**主机** ("使用双参数运行 addgroup 是未定义行为")。修复: addgroup 移入独立 `chroot ... addgroup ${SYS_USER} sudo`; 后发现 **noble 的 adduser ≥3.137 重写版删除了 addgroup 双参数用法** (chroot 内同样报 "addgroup with two arguments is an unspecified operation"), 最终改为并入 `usermod -aG sudo,video,render,dialout,tty` (usermod 属 passwd 包, 不受影响)。期间 adduser/passwd chroot 补 `LC_ALL=C` 消 perl locale 告警
- **build_all.sh**: mkbootloader 后校验 `.done` + `bootloader-syterkit.bin`, 失败即 exit 2

## Bootloader 切换: SyterKit → 主线 u-boot (2026-08-23, 第四轮)

SyterKit main 分支工具链问题 (第三轮) 之后, 应用户要求整体切换到**主线 u-boot**。方案与 Armbian `sun55iw3` family 一致 (已在 Armbian 上验证可启动 A1):

| 组件 | 来源 | 说明 |
|---|---|---|
| u-boot | 主线 `v2026.07` tag | `avaota-a1_defconfig` 2025-07 由 Andre Przywara 合入主线; 含 AXP717 PMIC + DRAM 调参 |
| BL31 (ATF) | `jernejsk/arm-trusted-firmware` 分支 `a523-v4`, `PLAT=sun55i_a523 DEBUG=1` | **主线 ATF 无 sun55i plat**; Jernej Skrabec (A523 移植合作者) 的 fork |
| 板级补丁 | `patches/u-boot/avaota-a1/` (4 个, 移植自 Armbian v2026.07-sunxi64) | SD 卡检测 broken-cd / CLDO3 供电 / eMMC 修复 / defconfig 加 SPI-MTD |

- **已实测**: 本机完整编译 ATF bl31 (41K) + u-boot 补丁版 (950K `u-boot-sunxi-with-spl.bin`, 无 binman blob 警告)
- **为何不用主线 master**: Armbian 方案基于 v2026.07 tag + 补丁, 跟随已验证组合; master 的 sun55i gmac1 等仍在活跃变动
- **为何不用 AvaotaSBC/u-boot fork**: 那是 Allwinner 2018.07 SDK 树 (android 启动流, 无 extlinux/distro boot), SD 启动需私有 boot0, 不可用
- **boot 流**: u-boot distro_bootcmd 扫描 FAT 分区 `/extlinux/extlinux.conf` (pack.sh 现有布局 /Image /dtb/ /uInitrd 兼容); 写卡仍是 `dd seek=8` (8KB 偏移, u-boot 约 1MB, 分区从 16MB 起, 无冲突)
- **改动**: `boards/avaota-a1.conf` (BL_CONFIG=sunxi-uboot + UBOOT/ATF/PLAT/BL_CONF/BL_PATCHDIR); 重写 `bootloader-sunxi-uboot.sh` (fail-fast + 幂等补丁 + distclean); fetch.sh clone_atf 修目录判断 bug (原来误查 BL_CONFIG 目录, atf 永远不会更新/重克隆)、clone_u-boot pull 前还原补丁; build_all.sh bootloader 产物名校验通用化 (sunxi-uboot → bootloader-u-boot.bin)
- **删除**: `scripts/lib/bootloader/bootloader-sunxi-syterkit.sh`, `patches/bootloader/`, fetch.sh clone_syterkit
- **旧 SyterKit 产物清理** (root 属主, 需手动): `sudo rm -rf build_dir/sunxi-syterkit build_dir/bootloader-avaota-a1 build_dir/bootloader-syterkit.bin build_dir/sdcard.img build_dir/sdcard.img.xz`

## 第五轮 (2026-08-23, 镜像无 boot 事故: 两 bug 叠加)

症状: 镜像烧卡后板子完全无反应、串口无输出。排查发现 **两个致命 bug 叠加**:

1. **u-boot 没写进镜像**: pack.sh 原顺序是 `UMOUNT_ALL` (kpartx -d + losetup -d 拆掉所有设备) **之后** `write_bootloader /dev/mapper/loopX` — dd 对着已拆除/僵尸的 mapper 节点写, 报成功但数据进了已删除的旧 inode (上次构建残留), 镜像 8KB 处全零, BROM 找不到 eGON.BT0 静默进 FEL。**验证手段**: `xz -dc img.xz | dd bs=1 skip=8192 count=32 | xxd` 应见 `eGON.BT0`。修复: `write_bootloader ${device}` (裸 loop) 移到 UMOUNT_ALL **之前**, dd 加 `conv=fsync`
2. **FAT 上没有 /Image**: arm64 内核 `make install` (arch/arm64/boot/install.sh) 对未压缩 Image 命名为 **`vmlinux-<ver>`** 而非 `vmlinuz-<ver>` (40MB 的 vmlinux-* 就是 raw arm64 Image, 可 booti 直接引导), postinst 的 `mv /boot/vmlinuz-* /boot/Image` 失败 → extlinux 的 `kernel /Image` 找不到。修复: gen_image_postinst 双名字兼容 (vmlinuz- 优先, 回退 vmlinux-); gen_image_postrm 清理补 `/boot/vmlinux*`。**修已有 deb 的快通道** (免整内核重编): sudo sed 改 deb-data/image/DEBIAN/postinst 后 `dpkg-deb -b deb-data/image avaota-a1-kernel-pkgs`

FAT 分区离线检查工具链 (mtools, 免 root): `xz -dc img.xz | dd bs=512 skip=32768 count=491520 of=fat.img` → `mdir -i fat.img ::` (p1 起始 32768 扇区 = OFFSET*2048, 共 491520 = BOOT_SIZE*2048-OFFSET*2048)。注意 xz 解压中报错别丢 stderr, 否则截断文件会误导排查

其余排查结论: 镜像 xz 完好 (xz -t 过), mbr/分区表/ext4 正常, dtb/uInitrd/extlinux.conf 均在位

## 第六轮 (2026-08-23, 换主线 u-boot 后内核启动卡死: PSCI 深度 idle)

症状: u-boot/内核都能起, 串口日志走到 `cpufreq_online` 后约 21 秒 RCU stall, CPU5/6 的 idle task 卡死在 `cpuidle_enter` 不归, 板子僵死。

**根因**: BSP 内核 dts (`sun55i-t527.dtsi`) 给每个 CPU 挂了 PSCI 深度 idle 态 `CPU_SLEEP_0`(0x0010000) + `CLUSTER_SLEEP_0`(0x1010000, cluster 断电)。SyterKit 自带 Allwinner monitor/scp 固件实现了这些状态; **jernejsk a523-v4 BL31 未实现** — 佐证: 主线 u-boot 同步的上游 dts (sun55i-a523.dtsi) CPU 节点**根本没有 cpu-idle-states**, Armbian 验证组合就是纯 WFI。CPU 进 CLUSTER_SLEEP 后永不返回。

**修复**: `patches/kernel/avaota-a1-bsp/patches/0002-*.patch` 删除 dtsi 中全部 8 处 `cpu-idle-states` 引用 (idle-states 节点定义留着无害), cpuidle 退化为 WFI, 与主线一致。内核配置 `CONFIG_CPU_IDLE/ARM_PSCI_CPUIDLE` 不动 (无 state 节点即只剩 WFI)。

- 触发内核重编需删缓存: `sudo rm build_dir/avaota-a1-kernel-pkgs/.done` (内核包缓存键是 `${LINUX_CONFIG}-${LINUX_PATHDIR}`, 补丁更新不改键值)
- **免重编快速验证法**: 改卡上 FAT 分区 `/extlinux/extlinux.conf` 的 append 加 `cpuidle.off=1` (禁用整个 cpuidle 框架), 2 分钟可确认诊断
- 遗留 (不致命, SyterKit 时代同样存在): CPU OPP `not supported by regulators (0V)` / `EM: invalid perf state -22` — DTB OPP 表无电压信息, cpufreq 仍可切频, 暂不处理

## 第七轮 (2026-08-23, 修 idle 后暴露: BSP cpufreq 切频死循环)

0002 补丁删 idle-states 后, `cpuidle_enter` 卡死消失, 但暴露下一个卡点: CPU4 (cluster1) cpufreq 首次切频卡在 `clk_set_rate → clk_change_rate → __clk_notify` (RCU stall on CPU5, 无超时死循环)。

**根因**: cluster0 用 `pll-cpu1` (切频正常), cluster1 用 `pll-cpu3` (P 分频在 CPUB mux 寄存器 0x0064, 路径特殊), BSP cpufreq 驱动 (`CONFIG_ARM_AW_SUN50I_CPUFREQ_NVMEM` 注册 cpufreq-dt) 对 pll-cpu3 首次切频死循环。u-boot 把 CPU 留在 768MHz (日志 "unlisted initial frequency 768000"), 不切频本可正常起。

**修复**: defconfig 覆盖文件禁用 `CONFIG_AW_CPUFREQ_DT` + `CONFIG_ARM_AW_SUN50I_CPUFREQ_NVMEM`, CPU 停在 u-boot 设定的 768MHz。先保证能起, DVFS 后续再评估 (OPP 表本就无电压信息)。

- **免重编快速验证**: 卡上 extlinux.conf append 加 `cpufreq.off=1` (5.15 支持, 见 kernel-parameters.txt)
- 触发重编: `sudo rm build_dir/avaota-a1-kernel-pkgs/.done`

## 第八轮 (2026-08-23, psci_checker 开机自测卡死)

修掉 cpufreq 后内核跑到 `psci_checker: Starting hotplug tests` → 逐个 `psci: CPU%d killed` 后卡死。`CONFIG_ARM_PSCI_CHECKER=y` 是开机对全部 CPU 做 PSCI hotplug 自测的**调试项**, jernejsk a523-v4 BL31 (WIP) 对 CPU_OFF 后再 CPU_ON 支持不完整 → 卡死。修复: defconfig 覆盖文件禁用该配置 (无生产价值)。旁证: `sunxi_dsufreq` 报 "cpufreq cpu get failed" 是我们禁用 cpufreq 的正常副作用, 无害。

## 第九轮 (2026-08-23, initramfs 找不到 LABEL=rootfs)

修掉 psci_checker 后内核顺利跑到 `Run /init`, 但 initramfs 报 `Gave up waiting for root file system / ALERT! LABEL=rootfs does not exist`。

**根因**: SD 卡没被内核识别 (无 /dev/mmcblk0)。离线验证过镜像 p2 ext4 label 确实是 `rootfs` (e2label), 问题在内核侧卡检测: BSP 内核 dts `&sdc0` 用了 `cd-gpios = <&pio PF 6 ...>`, 该卡检测脚在 Avaota A1 上不可靠 (Armbian 对这块板也是把 u-boot 用的主线 dts 改成 `broken-cd`), 内核读不到卡 → 无根设备。

**修复**: `patches/kernel/avaota-a1-bsp/patches/0003-*.patch` 把 `&sdc0` 的 `cd-gpios` 注释掉、加 `broken-cd` (恒认为有卡, mmc core 周期性重探)。

- 触发重编: `sudo rm build_dir/avaota-a1-kernel-pkgs/.done`
- 免重编快速验证: 卡上 extlinux.conf 内核参数加 `rootwait` 无效 (卡根本没识别, 不是时序问题); 直接改卡上 dtb 麻烦, 建议直接重编
- 诊断备忘: 内核起来后卡在 initramfs shell 时, `ls /dev/mmc*` / `cat /proc/partitions` 确认有无块设备; `dmesg | grep -i mmc` 看 sdc0 探测日志

### 分区识别改 UUID (2026-08-23, 与第九轮同批)

从 LABEL 改为固定 UUID 识别分区 (更稳, 避免 label 冲突):

- `boards/avaota-a1.conf`: 新增 `ROOT_UUID="d88a2c3e-7f4b-4e11-9c8a-5d2b1f3a6e7c"` / `BOOT_UUID="1A2B-3C4D"`; BOOTARGS `root=UUID=${ROOT_UUID}`
- `pack.sh`: `mkfs.ext4 -L rootfs -U ${ROOT_UUID}`; `mkfs.vfat -n boot -F 32 -i 0x${BOOT_UUID//-/}` (FAT32 卷序列号, blkid 显示为 `1A2B-3C4D`)
- `mkrootfs.sh` fstab: `UUID=${BOOT_UUID}` / `UUID=${ROOT_UUID}`

注意: 改 UUID 会让三个缓存产物全部过期 (extlinux.conf 的 BOOTARGS 在 bootloader 阶段烧入、fstab 在 rootfs 阶段烧入、内核 0003 补丁), 需 `sudo rm build_dir/avaota-a1-kernel-pkgs/.done build_dir/bootloader-avaota-a1/.done build_dir/rootfs-noble-gnome.tar.gz` 后全量重编

### 第十轮 (2026-08-23, CMD8 RTO: SD 卡命令全部超时)

修掉 broken-cd 后, 内核识别到卡并尝试初始化, 但 CMD8 (SEND_IF_COND) / CMD55 (APP_CMD) 全部 Response Timeout —— 卡不响应任何命令。

**根因**: BSP DTS `&sdc0` 的 `vmmc-supply` 注释掉, MMC 核心不知道 SD 卡电源从哪来, 无法正确配置电压/电源。虽然 `reg_cldo3` 有 `regulator-always-on`, 但 MMC 框架仍需 `vmmc-supply` 调用 `mmc_regulator_set_supply()` 做电源协商。同时 `ctl-spec-caps = <0x408>` / `cd-used-24M` / `sunxi-power-save-mode` / `sunxi-dly-208M` 等 BSP 私有属性可能干扰初始化。

**修复**: 此项现已合并进 `patches/kernel/avaota-a1-bsp/patches/0003-*.patch`，一次性从原始 DTS 清理 `&sdc0` 节点，避免 0003/0004 修改同一区域导致重复构建时无法识别已应用补丁:
- 启用 `vmmc-supply = <&reg_cldo3>` (对齐主线 DTS)
- 删除 `ctl-spec-caps` / `cd-used-24M` / `cd-set-debounce` / `sunxi-power-save-mode` / `sunxi-dly-208M` 及所有注释掉的旧属性
- 保留: `broken-cd` / `cap-sd-highspeed` / `sd-uhs-*` / `no-sdio` / `no-mmc`

触发重编: `sudo rm build_dir/avaota-a1-kernel-pkgs/.done`

### 第十一轮 (2026-08-23, 0004 后仍 CMD8 RTO: PF bank IO 电源模式切换致死)

合并后的 sdc0 修复生效确认 (内核日志: 无 "No vmmc regulator found", vdd 21→23=cldo3 3.5V OCR 最高位; detmode:gpio polling=broken-cd), 但 CMD8/55 仍全 RTO。

**排查过程**:
- 日志 `ctl-spec-caps 428` 一度怀疑 DTB 不是新构建 → 反编译构建产物 DTB 确认有 ctl-spec-caps → 最终发现 **dtsi 基础节点 `sun55i-t527.dtsi:3806` 的 sdc0 本身就带 `ctl-spec-caps = <0x428>`** (板级 dts 只是被 0004 清了, dtsi 的还在, 板级覆盖合并后仍存在)。DTB 是正确的。
- u-boot 实测 (卡正常可读): `PIO 0x02000000+0x340~0x350` 全 0 —— **PF bank IO 电源模式 (pow_ctrl 0x350) = 0**
- 内核 pinctrl 应用 `sdc0_pins_a` (dtsi: `power-source = <3300>`) → `sunxi_power_switch_pf()` (pinctrl-sunxi.c:1179) 判定 0="1.8V" < 3300 → 升压路径: 0x344 bit5=1 (关自适应) + **0x350=1** + 轮询 0x348 确认。内核把 PF IO 电源模式 0→1 后卡就聋了
- 结论 (待 u-boot mw.l 实验最终确认): **该板 PF 的 mode-1 轨不可用/语义相反, mode 0 才是能工作的状态**; u-boot 不做此切换所以能读卡
- 排除项: `vcc-pf-supply=<&reg_pio1_8>(1.8V fixed)` 无效 —— 日志明确警告 "Dts property 'vcc-pf=*' takes no effect" (sun55iw3 power_mode_detect=true, 硬件自检承压)

**修复**: `patches/kernel/avaota-a1-bsp/patches/0005-*.patch` 板级 dts 追加, 对 sdc0 三组 pin 状态 (sdc0@0/1/2) `/delete-property/ power-source` → 内核永远不触发 `sunxi_power_switch_pf`, 保持 u-boot 留下的 mode 0 (与主线 dts 行为一致, 主线这些 pin 无 power-source)。已验证 dtc 编译通过且 DTB 中 power-source 消失。

- **验证实验 (u-boot, 修正版地址) 已做 (2026-08-23)**: 结果**证伪**原理论: `0x380=0x20/0x384=0x20/0x390=1` (升压路径, 与内核写法相同) 下卡**正常** → 内核 PF 升压序列无害; 但恢复时 `0x390=0` (降 1.8V) 当场杀死卡, 且重做升压**不复活** → 卡进入电压切换中断卡死态 (SD 卡经典行为, 需 VDD 真断电恢复; CLDO3 always-on, **软复位无效, 必须拔电源**)。0x388=0x444: bit2/6/10=C/G/K 处于 1.8V (对应内核 bank[C/G/K] 警告), bit5(PF)=0=3.3V
- **当前最大嫌疑 (未证实)**: 时钟树 — 内核 CCU SMHC0 mux/分频或 CLKCR 输出时钟异常 → 卡看不到 CMD8。u-boot 参照值: GCTRL=0xa0000000, CLKCR=0x00010001 (bit16 卡时钟开), CCU 0x830/0x84c/NTSR 待采
- 0005 补丁保留 (内核完全不碰 PF 电源寄存器 = 复刻 u-boot 环境, 排除变量), 但大概率不是根治
- u-boot 抓内核现场方法: 卡上 FAT 的 extlinux.conf append 加 ` break=mount` → initramfs-tools 直接停 shell, busybox devmem 读寄存器; 不加则等 "Gave up waiting" 2-3 分钟
- **initramfs 串口无输入问题 (2026-08-23)**: break=mount 能停到 busybox shell 但键盘/串口 RX 无法输入命令 (u-boot 下输入正常, 内核 console 输出正常) → 手工 devmem 不可行。替代方案: `mkrootfs.sh` `setup_initramfs_debug()` 注入 `/etc/initramfs-tools/scripts/init-premount/avaota-mmc-debug` (后台每 8s 自动 dump: GCTRL/NTSR/CCU830/84C/PF 寄存器 + CLKCR 10 连采抓活动窗 + regulator/分区/mmc dmesg, 输出带 `AVAOTA-MMCDBG:` 前缀)
- **uInitrd 静态件问题**: extlinux.conf 加载的 `/uInitrd` 是 `target/boot/uInitrd` (**2024-04 预编译**, 不含 rootfs 的 initramfs hook); chroot 装内核 deb 时 postinst 实际生成了新 `initrd.img-<ver>` 但没被用上。`pack.sh` 已加: chroot 安装后把 initrd.img **裸拷贝**为 uInitrd
- **MMCDBG 首轮数据判读 (2026-08-23)**: PF 电源域内核态正常 (PF390=1/3.3V, PF388 bit5=0=实际 3.3V, PF380 bit5=1) → PF 域彻底排除; cldo3=enabled 3.3V 正常; CCU830=0x8000001D (mux=osc24M M=29 → 800kHz 模块钟 = 驱动给 400kHz 2x 模式的目标值, 符合意图); CLKCR 10 连采全 0 (ON 窗口每 1.2s 仅 ~100ms, 0.2s 间隔采样大概率错过, 不确定); PFCFG0=0 单采落在 OFF 窗口 (sleep 态=gpio_in) 无法判定。**纠正误判: mmcblk1 (30.5GB 无分区) 不是 SD 卡, 是 sdc2 的空 eMMC**; SD 卡 sdc0 从首轮扫描即 RTO 仍未通。剩余嫌疑: ON 窗口内的 PFCFG0 mux / CLKCR bit16 卡时钟。hook 升级 v2: 50ms 连采 100 发抓 ON 窗口 + eMMC (0x04022000, CCU 0x838) 对照组 + console loglevel 压到 3 抗 RTO 刷屏
- **MMCDBG v2 判读 (2026-08-23, ON 窗口抓到)**: B7/B56/B72/B88 捕获 pm ON 窗口: **CLKCR=0x00010000 (bit16 卡时钟开) ✓, NTSR=0x81710000 与 u-boot 完全一致 ✓, GCTRL=0x20000010 活跃 ✓, CCU 门控/mux/分频符合驱动意图 ✓ → 时钟树排除**。eMMC 对照组 CLKCR=0x00030000 (bit16=1) 同样正常。但 PFCFG 读数 0x00000000 — **是 hook 读错地址: 0xB4 是 PG CFG0 (空 bank), PF CFG0 实为 0x02000090** (bank_base 从 PB 起编号)。唯一未验证项 = PF pinmux。hook v3: 修正为 0x90/0xA0(PFDAT 看线电平)/0xAC(PFPULL)
- **PF CFG0 地址疑云 (2026-08-23, v3 阶段)**: u-boot 实测 `md.l 0x02000090` = 0xffffffff×3+0 (io_disabled 模式, 不是 0x222222) → 0x90 也不是 PF! 两种布局: 传统 stride 0x24 → PF=0xB4; sun55iw3 HW_TYPE_3 stride 0x30 → PF=0xF0。待 u-boot `md.l 0x02000000 0x50` 全片 dump 找 0x00222222 定位真身。hook v3 改为 CLKCR 非零触发 (ON 窗口) + 快照候选 0x90/B4/D8/F0/120/144 + DAT(=CFG+0x10)
- **v3 判读: PF=0xF0 实锤, pinmux 排除 (2026-08-23)**: u-boot 全片 dump + 内核 HIT 对照: PIO 布局 stride 0x30 (PB=0x30, PC=0x60, PD=0x90, PE=0xC0, **PF=0xF0**, PG=0x120, PK=0x500 特例); u-boot PF CFG0=0x0F222222, **内核 ON 窗口 AF0=0x0F222222 完全一致** (PF0-5 func2=sdc0); PG 0x120=0x22222222 = 内核使能 sdc1 (WiFi sdio) 正常。至此 pinmux/时钟/NTSR/CCU/供电/PF电源域 **全部排除**, 可测量寄存器全与 u-boot 工作态一致但卡仍 RTO。下一嫌疑: SDMMC0 控制器内部未 dump 的配置 (CSDC 0x54 / DRV_DL 0x140 / SAMP_DL 0x144 / TMOUT / STAS) 或卡被扫描周期留在锁死态。hook v4: HIT 时全量 dump SDMMC0 0x00-0x5C+延时寄存器。SDMMC 寄存器: GCTRL 0x00/CLKCR 0x04/TMOUT 0x08/WIDTH 0x0C/CMDR 0x18/CARG 0x1C/RESP 0x20/IMASK 0x30/RINTR 0x38/STAS 0x3C/FTRGL 0x40/CSDC 0x54/A12A 0x58/NTSR 0x5C/THLD 0x100/EDSD 0x10C/DRV_DL 0x140/SAMP_DL 0x144/DS_DL 0x148
- **双重压缩事故 (2026-08-23)**: 第一版 pack.sh 用 `gzip -9 | mkimage -C gzip` 重制 uInitrd, 但 noble initramfs-tools 默认输出 zstd → 双重压缩 → 内核解出垃圾 cpio → initramfs 空 → 直落 `prepare_namespace` panic ("Cannot open root device UUID=...")。教训: **initrd.img 必须原样裸拷贝** (内核 RD_GZIP/RD_ZSTD 都有, 自动探测; u-boot booti 接受裸 initrd 不需要 mkimage 头)
- **update-initramfs 在 chroot 里卡死 (2026-08-23)**: 两个原因: ① noble 默认 `COMPRESS=zstd`, zstd 在 qemu-user-static 模拟下压缩极慢/假死, pack 阶段 `update-initramfs: Generating...` 后长时间无输出即此。修复: pack.sh (chroot 装 deb 前) + mkrootfs.sh 写 `/etc/initramfs-tools/conf.d/avaota-compress.conf` = `COMPRESS=gzip`。② **avaota-mmc-debug hook 首版不处理 `prereqs` 参数** — mkinitramfs 生成阶段以 prereqs 调用每个脚本, 旧版直接跑正文在 chroot 里起 8 分钟后台循环, 后台进程持有 stdout 管道 → mkinitramfs 等 EOF 卡死, 且输出会被误当 prereq 列表。修复: hook 加 `case "$1" in prereqs) exit 0`, 后台循环 `exec >/dev/console 2>&1`; pack.sh 解包后从 mkrootfs.sh 重新抽取覆盖 hook (rootfs tar 里可能是旧版)。若 pack 被 Ctrl-C 中断, 残留挂载需 `sudo umount build_dir/rootfs_dir/boot; sudo losetup -D; sudo rm -rf build_dir/rootfs_dir` 再重跑
- 触发重编: `sudo rm build_dir/avaota-a1-kernel-pkgs/.done`
- 寄存器备忘 (修正版, 第一版 0x340/0x350 是错误寄存器——那是别的芯片类型的): sun55iw3=HW_TYPE_3=hw_info 数组 index 3, **PF 电源模式真正寄存器: sel=0x380 / ctrl=0x384 / val(状态)=0x388 / pio_pow_ctrl(开关)=0x390, PF 用 bit5** (vccio_banks={B,H} 映射 bit12, PF 不在其中); `sunxi_power_switch_pf` 升压路径: 0x380 bit5=1(reverse=true) + 0x384 bit5=1(关自适配) + **0x390=1** + 轮询 0x388 bit5 清零。PIO base 0x02000000; **PF bank 偏移: sun55iw3 bank_base 从 PB 起编号, PF=index 4 → 4×0x24=0x90** (CFG0=0x02000090, func2=sdc0 → 0x222222; DAT=0xA0; PULL=0xAC; **0xB4 是 PG 的 CFG0, v2 hook 读它全 0 一度误判 pinmux 丢失**)。SDMMC0 base 0x04020000 (GCTRL/CLKCR bit16=clock on/NTSR 0x5C); CCU 0x02001000: SMHC0 clk 0x830 (bit31 gate, mux[26:24]), BUS_SMHC0 0x84C (bit0 gate, bit16 rst)
- u-boot 无 devmem, 用 md.l/mw.l; 注意 md.l 地址别截断 (用户曾 `md.l 0x02001` 触发 Synchronous Abort 复位)

### 第十二轮 (2026-08-25, CMD8 RTO 根因: Linux 将 A523 SMHC0 CCLK_DIV 写成 0)

对比 SyterKit、主线 u-boot 和 Linux v5p3x 驱动后确认，phase/timing 不是根因：u-boot 工作态与 Linux 400k 默认值均为 `DRV_DL=0x00010000`（CMD 180 度、DAT 90 度）和 `NTSR=0x81710000`。u-boot 手工改 `DRV_DL=0x00030000` 后 Linux 仍 CMD8 RTO；且 Linux `set_ios()` 会覆盖 bootloader 留下的 phase 值。

真正差异是 SMHC0 内部分频：

- u-boot 工作态: `CLKCR=0x00010001`，即 card clock enable + `CCLK_DIV=/2`
- Linux 失败现场: `CLKCR=0x00010000`，即 card clock enable + `CCLK_DIV=0`
- 当前 u-boot A523 补丁已注明 `CCLK_DIV=0` 在 A523/T527 上不可用，并强制 `/2` 后将模块时钟请求乘 2补偿
- BSP Linux `sunxi-mmc-v5p3x.c` 对 SDR 模式固定 `mod_clk=ios->clock*2, div=0`，正好生成失败现场值；时钟门、PF pinmux、CLDO3 和 CCU 看似正常，但卡实际收不到 CMD8/CMD55

修复: `patches/kernel/avaota-a1-bsp/patches/0006-*.patch` 仅对 `phy_index==0` (sdc0) 使用 `mod_clk=ios->clock*4, div=1`。这样内部 `/2` 后 card clock 保持不变；不影响 sdc1/sdc2。400k 初始化的预期现场是 `CLKCR=0x00010001`，CCU SMHC0 模块钟由约 800kHz 提高到约 1.6MHz。

触发重编: `sudo rm -f build_dir/avaota-a1-kernel-pkgs/.done`。验证重点: Linux 日志不再出现 CMD8/CMD55 RTO，出现 `mmcblk0` 及其分区；v4 initramfs hook 的 HIT 行应显示 `CLKCR=0x00010001`。

### 第十三轮 (2026-08-25, 新镜像只有 u-boot、分区全零)

症状: u-boot 正常启动并识别 `mmc0`，但不显示 `Scanning mmc 0:1` / `Found /extlinux/extlinux.conf`，随后回退到空 eMMC、USB、PXE/DHCP。离线检查镜像发现 8KiB 处 `eGON.BT0` 正常，但 16MiB 处没有 FAT，rootfs 分区也为空；3.34GiB 镜像压缩后仅 843KiB。

根因: 主机没有 `kpartx` 命令，旧 `pack.sh` 仍执行 `kpartx -va` 并使用 `/dev/mapper/loopXp1/p2`。mapper 分区没有创建，mkfs/mount/copy 全部失败，但脚本没有 fail-fast，最后只有对裸 loop 的 `write_bootloader` 成功，生成了只有 u-boot 的空镜像。

修复: `pack.sh` 改用 `losetup -P` 直接创建 `/dev/loopXp1/p2`，彻底移除 kpartx/mapper；等待并校验分区块设备，mkfs/mount 失败立即退出。打包阶段验证 FAT/ext4 类型和 UUID、`Image`/DTB/uInitrd/extlinux、rootfs `/sbin/init`；压缩前再次从原始 `sdcard.img` 按偏移离线验证 u-boot 魔数、文件系统和 FAT 启动文件。坏镜像必须重新打包并烧录，修改 u-boot 环境无法修复缺失的文件系统。

### 第十四轮 (2026-08-28, 去掉 MMC 调试 hook, 系统已能进 systemd)

删除 `mkrootfs.sh` `setup_initramfs_debug()` / `avaota-mmc-debug` (会压低 printk=3 盖住真故障) 以及 pack.sh 的 hook 覆盖。保留 `COMPRESS=gzip`。BOOTARGS 去掉无用的 `initcall_debug=0`。pack.sh 对旧 tar 主动 `rm` 残留 hook。0006 CCLK_DIV 补丁生效后 SD 卡 (mmcblk0) 正常, 能进 Ubuntu 24.04 systemd / GDM。

### 第十五轮 (2026-08-28, 开机噪音清理 / WiFi / 音频组 / 根分区扩容)

实测: 主机名曾是 `BOARDNAME` — `setup_hostname_fstab` 用单引号把 `${BOARD_NAME}` 写进文件, systemd 丢掉非法字符。已改双引号 + `127.0.1.1`。smartmontools 在无 SATA 板上 [FAILED], 已 mask。WiFi AIC8800 需 `aic8800_bsp`/`aic8800_fdrv` 自动加载 (SDIO 上电后 rescan), 已写入 `/etc/modules-load.d/aic8800.conf`; 实测 `wlan0` 已连 AP。

**根分区扩容从未跑**: Ubuntu chroot 里 `systemctl enable` 会 no-op ("Running in chroot, ignoring"), `init-resize.service` 镜像里一直是 disabled。29.7G 卡只用了 3G (94%)。已改为手写 `multi-user.target.wants` 符号链接; 脚本改 `growpart`/`sfdisk` + `partx` + `resize2fs`。包列表加 `cloud-guest-utils`。板子上曾手动 `usermod -aG audio,bluetooth,plugdev`; 扩容需在板子上跑 sfdisk/resize2fs (或重打镜像)。

音频: 内核 `audiocodec`/`card0` 正常, `sudo aplay -l` 能列出设备; 缺 `audio` 组时用户态 `aplay -l` 报 no soundcards。已加入组。HDMI 音频内核关了 `CONFIG_SND_SOC_SUNXI_CODEC_HDMI`, 板载 codec 不受影响。

SSH: 镜像已含 openssh-server, `ssh.socket` 激活, 不必再装。WiFi IP 可直接 `ssh avaota@...`。

### 第十六轮 (2026-08-28/29, 蓝牙 UART HCI 未通)

AIC8800 是 WiFi=SDIO / BT=UART (uart1=`/dev/ttyAS1`, PG6-9; `bt_rst`=PG12; `bt_wake`=PG11)。WiFi 通不代表 BT 通。

- `hciattach` 报 Device setup complete 但 `BD Address 00:00:00:00:00:00`、RX=0、`command 0x1001 tx timeout` = **UART 挂上了, 芯片没回包** (`any` 不等 Reset 成功)
- 芯片默认睡死, 需 `echo 1 > /proc/bluetooth/sleep/btwrite` (TaterLi 同板验证), 该节点由 `aic8800_btlpm` 提供
- `aic8800_btlpm` 当前内核 probe 失败 (`dev_pm_set_wake_irq` EBUSY, 用户态有时表现为 `modprobe: No such device`), 所以没有 `btwrite`
- 另需 `rfkill unblock` 松开 `sunxi-bt` (PG12 复位); `gpiofind` 必须 sudo
- 构建已加: `patches/.../0007-aic8800-btlpm-dont-fail-probe-on-wake-irq.patch` (wake IRQ 失败不让 probe 失败); `target/services/avaota-bluetooth/` 开机服务 (wake + `hciattach -s 1500000 /dev/ttyAS1 any 1500000 flow nosleep`); 包列表 `bluez`。**0007 需内核重编才进现卡**: `sudo rm -f build_dir/avaota-a1-kernel-pkgs/.done`。**BT 仍未通, 低优先级待排查**

GPU OPP 648/744/792 被拒是 **vf3920 bin 规格**, 额定最高 696MHz, 不是故障。CPU 无 cpufreq 是故意关的 (cluster1 pll-cpu3 切频死机), 8 核锁 u-boot 768MHz, **影响 CPU 性能**, 中优先级。

## 硬件/软件背景

- 三个显示输出:
  1. **板载 0.96" 屏**: SPI ST7789V, 走 `/dev/fb0` (fbcon), **不在 DRM 桌面内** — GDM 看不见它
  2. **HDMI**: `card0-HDMI-A-1`, 接 27" QHD (2560x1440, EDID 型号 P27QBC-RG)
  3. **DP (实为 eDP)**: T527 eDP 控制器 `drm_edp@5720000`, 外接 2560x1440 显示器, **不走 EDID, 用 DTB 固定 timing**
- DRM 驱动是 BSP sun4i-drm (内核内建), GPU 是 panfrost (renderD128)
- 显示服务器: GDM + gnome-shell (Wayland), mutter 46.2
- 注: 用户之前在另一台相同设备排查过 GDM 问题但不是根因; 本次 GDM 本身确实无故障

## 问题一: DP 无画面 (已修复; 2026-08-22 二次升级: 切换为真 DP 模式)

**根因**: DTB (`/boot/dtb/allwinner/sun55i-t527-avaota-a1.dtb`) 中整条 eDP 通路 `status="disabled"`:
`drm_edp@5720000` / `edp_panel` / `edp_backlight`。内核驱动 `CONFIG_AW_DRM_EDP=y` 内建但从未 probe。

**修复 v1 (eDP 固定 timing, 备份 `*.dtb.edp-fixed`)**: 启用三节点 + `edp_panel/panel-timing` 改 2560x1440@60 CVT-RB
(pixel 241.5MHz, hbp 80, hfp 48, hsync 32, vbp 33, vfp 3, vsync 5)。已验证可点亮。

**修复 v2 (当前, DP 模式)**: 源码分析发现 BSP 驱动 (`bsp/drivers/drm/sunxi_drm_edp.c:4763`) 匹配两个 compatible:
- `allwinner,drm-edp` → connector=eDP, 走 `/edp_panel` 固定 timing, 不读 EDID
- `allwinner,drm-dp` → connector=DisplayPort, `get_modes` 经 AUX 通道 `drm_do_get_edid` 读显示器 EDID (lowlevel `inno_edp13.c` 已实现 `read_edid_block`), 自动分辨率/热插拔, probe 不需要 panel 节点

当前 DTB: `drm_edp@5720000` compatible 改为 **`allwinner,drm-dp`**, `edp_panel`/`edp_backlight` disabled。
重启后连接器名从 `card0-eDP-1` 变为 `card0-DP-1`, `/sys/class/drm/card0-DP-1/edid` 应非空。
两种模式可随时用 `scripts/fix-display.sh --dp / --edp` 切换。

**刻意不动**: `edp0@5720000` (非 DRM 老框架节点, 与 drm_edp 同地址冲突, 保持 disabled); `tcon4@5731000` (eDP 实际由 tcon3 供时序, tcon3 已 okay)

## 问题二: HDMI 纯黑画面 (已修复, 已生效已验证)

**症状**: 内核 HPD/EDID/模式全部正常, `status=connected` 但 `enabled=disabled`; gnome-shell 报
`Failed to lock front buffer: gbm_surface_lock_front_buffer failed` + `clutter_frame_clock: code should not be reached`。
重启 GDM 无效 → 非初始化时序问题。

**排查路径 (关键证据链)**:
1. `modetest` legacy 点亮 OK → 内核 KMS 正常
2. `kmscube` 单节点 (GBM+EGL+KMS, 含 atomic、两种 AFBC modifier) 全部 OK
3. 自写跨节点测试 (`/tmp/opencode/xnode_test.c`, dlopen libgbm): renderD128 建 bo → dma-buf 导出 → card0 导入 → AddFB2:
   - **LINEAR: 全通**
   - **AFBC 16x16 (0x800000000000061) 与 32x8 YTR (0x800000000000072): AddFB2 EINVAL**

**根因**: BSP 驱动 primary plane 的 IN_FORMATS 广播 AFBC modifier, mutter 据此用 AFBC 创建 scanout buffer,
但 BSP 驱动**拒绝带 AFBC modifier 的跨节点 AddFB2 导入** (DMA-BUF 导入不含 modifier 信息)。
kmscube/modetest 是单节点路径所以能亮, 极易误导排查方向。

**修复**: mutter 46.2 支持环境变量 `MUTTER_DEBUG_USE_KMS_MODIFIERS=0` 强制 LINEAR:
- `/etc/systemd/system/gdm3.service.d/10-no-kms-modifiers.conf` (Service Environment)
- `/etc/environment` 追加同变量兜底
- 已重启 gdm 验证: HDMI enabled, buffer 错误清零, 登录界面已上 HDMI 屏

## 附带改动

- `/boot/extlinux/extlinux.conf`: `cma=64M` → `cma=256M` (双 2560x1440 屏需 ~90MB+ 扫描缓冲, 64M 必然 OOM; 备份 `.bak`)

## 当前系统状态 (2026-08-29)

系统已能进 Ubuntu 24.04.4 + systemd + GDM。WiFi 可用, SSH (`ssh.socket`) 可用。待办优先级与下一步见仓库根目录 **`status.md`**。

- HDMI/DP: 驱动绑定 `card0-HDMI-A-1` / `card0-DP-1`; 最近一次实测两口均为 disconnected (线未插)
- 板载 ST7789V `fb0` 240×135 正常; panfrost renderD128 正常, GPU 最高 696MHz (vf3920)
- SD `mmcblk0` 工作 (0006 CCLK_DIV); eMMC `mmcblk1` 29.1G 空片
- 用户组 (构建侧已改, 现卡已手工加 audio/bluetooth/plugdev): sudo,video,render,dialout,tty,audio,bluetooth,plugdev
- 一键显示修复: `scripts/fix-display.sh` (`--dp` 默认 / `--edp` 可选)

## GPU 栈现状 (2026-08-22 实测, Mali-G57 / Valhall)

| API | 状态 | 说明 |
|---|---|---|
| OpenGL ES 2.0/3.1 | ✅ 硬件加速 | Mesa 25.2.8 panfrost (kmscube 实测 GLES 3.1) |
| Desktop OpenGL 4.5 | ⚠️ 仅软渲染 | llvmpipe; Mali 上 Mesa 不提供桌面 GL (正常现象) |
| Vulkan | ⚠️ 仅软渲染 | lavapipe (CPU, 1.3.275); panvk 已装但**拒绝 G57**: `Mali-G57 not supported (VK_ERROR_INCOMPATIBLE_DRIVER)` — Mesa panvk 的 Valhall 支持不含此型号, 且 5.15 BSP panfrost UABI 偏旧 |
| gnome-shell 合成 | ✅ 硬件 | journal: "Created gbm renderer for card0" |

- 内核驱动: 5.15 BSP panfrost, GPU id 0x9091 报 "mali-unknown" 但工作正常
- GPU 频率: OPP 648/744/792MHz 被拒是 **vf3920 这颗料的规格** (DTS 里这三档 opp-microvolt=0 或只给别的 bin); 额定最高 **696MHz**, 不是故障
- 用户组: 构建侧已含 video/render; 缺组时 SSH/TTY 下 GL 会 permission denied → llvmpipe
- 测试命令: `vulkaninfo --summary` (需 root 或组权限), `kmscube -D /dev/dri/card0` (需 chvt 抢 master)

## 排查工具备忘 (本机已装)


- `libdrm-tests` (modetest), `kmscube`, `/tmp/opencode/xnode_test` (跨节点 AFBC 测试, 源码 `/tmp/opencode/xnode_test.c`)
- 反编译 DTB: `dtc -I dtb -O dts /boot/dtb/allwinner/sun55i-t527-avaota-a1.dtb`
- 上游 dts 参考: https://github.com/AvaotaSBC/linux linux-5.15 分支 `arch/arm64/boot/dts/allwinner/sun55i-t527-avaota-a1.dts`
- VT 切换跑 KMS 测试前须 `chvt 3` 抢 master, 测完 `chvt 1`; modetest/kmscube 测试时用户需看显示器确认画面
- apt 可能被 unattended-upgrades 锁住, 遇 dpkg lock 等待或绕过

## 回滚

```bash
# DTB
sudo cp /boot/dtb/allwinner/sun55i-t527-avaota-a1.dtb.orig /boot/dtb/allwinner/sun55i-t527-avaota-a1.dtb
# extlinux
sudo cp /boot/extlinux/extlinux.conf.bak /boot/extlinux/extlinux.conf
# mutter modifier 绕过
sudo rm /etc/systemd/system/gdm3.service.d/10-no-kms-modifiers.conf && sudo sed -i '/MUTTER_DEBUG_USE_KMS_MODIFIERS/d' /etc/environment && sudo systemctl daemon-reload && sudo systemctl restart gdm
```
