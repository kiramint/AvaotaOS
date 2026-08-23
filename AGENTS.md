# Avaota A1 (T527) 显示问题排查记录

> 更新时间: 2026-08-23 (构建系统已切主线 u-boot)。目标设备: Avaota A1, T527, Ubuntu 24.04, 内核 5.15.154 BSP (sun4i-drm)。

## 构建默认值调整 (2026-08-23)

- `build_all.sh` `default_param()`: VERSION 默认 **noble**, TYPE 默认 **gnome**, MIRROR 默认 **https://mirrors.ustc.edu.cn/ubuntu-ports/** (其余默认值不变)
- sudo 策略: 删除 mkrootfs.sh 的 `/etc/sudoers.d/010_avaota-nopassword` (NOPASSWD); avaota 进 sudo 组由 pack.sh `usermod -aG sudo,video,render,dialout,tty` 完成, **sudo 需要密码**
> 本仓库是系统编译脚本。运行系统排查修复已固化进构建系统 (见下"构建系统集成"章节); 已部署系统可用 `scripts/fix-display.sh` 修复。

## 构建系统集成 (2026-08-22, 本次改动)

支持范围精简: **仅 Avaota A1 + Ubuntu 22.04/24.04 (jammy/noble) + cli/gnome**。构建时自动应用全部显示修复:

| 修复 | 集成位置 |
|---|---|
| DP 口 eDP→DP 模式 (EDID 自动) | `patches/kernel/avaota-a1-bsp/patches/0001-*.patch` (内核 dts: `&drm_edp` compatible 覆盖为 `allwinner,drm-dp`) |
| cma=256M | `boards/avaota-a1.conf` BOOTARGS |
| mutter AFBC 黑屏绕过 (仅 gnome) | `scripts/mkrootfs.sh` `setup_display_fixes()`: gdm drop-in + /etc/environment |
| 用户组 video,render,dialout,tty | `scripts/pack.sh` `setup_users()`: usermod -aG |
| 内核缺失配置 (AppArmor/nftables/VETH/WIREGUARD/容器栈等) | `patches/kernel/avaota-a1-bsp/files/arch/arm64/configs/sun55i_t527_bsp_defconfig` (原版+追加) |

- 内核补丁机制: `boards/avaota-a1.conf` `LINUX_PATHDIR="avaota-a1-bsp"` → mklinux.sh `patch_kernel()` 应用 `patches/kernel/avaota-a1-bsp/{patches,files}/`
- 内核包缓存判断已改为 `${LINUX_CONFIG}-${LINUX_PATHDIR}` (build_all.sh + mklinux.sh), 修改补丁后会正确触发重建
- 内核配置补充要点 (对比通用 Ubuntu 5.15 config, 参考 config 为 x86 需按符号核对): **SECURITY/APPARMOR** (Ubuntu 用户态强依赖, 原版整体关闭!), CGROUP_FREEZER/VETH/NF_TABLES (容器/防火墙), WIREGUARD/TUN/VXLAN/BONDING/VLAN (VPN/虚拟网络), BTRFS/XFS/NTFS/ISO9660/UDF (移动介质), FANOTIFY/BINFMT_MISC, CRYPTO_USER_API/CHACHA20POLY1305/ECDSA, FTRACE/KPROBES/PSI/TASKSTATS (可观测), DEVFREQ_THERMAL (GPU 过热降频), GPIO_SYSFS/HIDRAW/IIO/UIO/PTP/USB gadget mass storage

## 构建健壮性修复 (2026-08-23)

起因: 一次被中断的 `git clone --depth=1` 留下半截 linux 工作树 (缺 `scripts/` 等, git status 7 万+删除), fetch.sh 走 `git pull` 路径未察觉, make 报 `scripts/Kbuild.include: 没有那个文件或目录`。同时暴露多个级联问题, 已修复:

- **fetch.sh**: `clone_linux()` 前置 `check_linux_tree()` (哨兵文件 `scripts/Kbuild.include` 缺失 → 删树重克隆); 克隆后 `check_linux_complete()` 校验, 不完整 exit 2
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

## 当前系统状态 (2026-08-22, DP 模式待重启验证)

- HDMI: connected/enabled, 有画面 (eDP 模式时期验证)
- DP: DTB 已切 `allwinner,drm-dp` (v2), **等重启验证** ← 下次会话第一件事:
  - `ls /sys/class/drm/` 应出现 `card0-DP-1` (不再是 eDP-1)
  - `/sys/class/drm/card0-DP-1/status` = connected, `edid` 文件非 0 字节
  - `dmesg | grep -iE "edp|dp"` 看 link training 与 EDID 读取
  - 若 DP 模式失败 (HPD 不触发/无 EDID): 回滚 `sudo cp <dtb>.edp-fixed <dtb>` 即回到已验证可用的 v1, 或 `scripts/fix-display.sh --edp`
- CmaTotal: 262144 kB
- 一键修复脚本: `scripts/fix-display.sh` (`--dp` 默认 / `--edp` 可选, 已验证幂等)

## GPU 栈现状 (2026-08-22 实测, Mali-G57 / Valhall)

| API | 状态 | 说明 |
|---|---|---|
| OpenGL ES 2.0/3.1 | ✅ 硬件加速 | Mesa 25.2.8 panfrost (kmscube 实测 GLES 3.1) |
| Desktop OpenGL 4.5 | ⚠️ 仅软渲染 | llvmpipe; Mali 上 Mesa 不提供桌面 GL (正常现象) |
| Vulkan | ⚠️ 仅软渲染 | lavapipe (CPU, 1.3.275); panvk 已装但**拒绝 G57**: `Mali-G57 not supported (VK_ERROR_INCOMPATIBLE_DRIVER)` — Mesa panvk 的 Valhall 支持不含此型号, 且 5.15 BSP panfrost UABI 偏旧 |
| gnome-shell 合成 | ✅ 硬件 | journal: "Created gbm renderer for card0" |

- 内核驱动: 5.15 BSP panfrost, GPU id 0x9091 报 "mali-unknown" 但工作正常
- GPU 频率被限制: OPP 648/744/792MHz 被稳压器拒绝, **实际最高 696MHz** (available_frequencies: 150M-696M)
- 用户 `avaota` 不在 video/render 组: SSH/TTY 下跑 GL 程序会 permission denied → llvmpipe 兜底; 图形会话内经 logind 授权不受影响。修复: `sudo usermod -aG video,render avaota`
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
