# Avaota A1 (T527) 显示问题排查记录

> 更新时间: 2026-08-22 (修复已固化进构建系统)。目标设备: Avaota A1, T527, Ubuntu 24.04, 内核 5.15.154 BSP (sun4i-drm)。
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
