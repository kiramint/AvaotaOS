#!/usr/bin/env bash
#
# fix-display.sh — Avaota A1 (T527) 双屏显示修复
#
# 修复内容 (详见仓库 AGENTS.md):
#   1. DTB: 启用显示口控制器 (板载 DP 口实为 eDP 控制器引出), 两种模式:
#        --dp  (默认) compatible=allwinner,drm-dp, 驱动走 AUX 通道读显示器 EDID,
#              自动分辨率 + 热插拔, 无需固定 timing
#        --edp          compatible=allwinner,drm-edp, 使用 /edp_panel 固定 timing
#              (2560x1440@60 CVT-RB), 不读 EDID, 换显示器需改 timing 重启
#   2. 引导参数: cma=64M -> cma=256M (双 2560x1440 屏需 ~90MB+ 扫描缓冲)
#   3. GDM/mutter: MUTTER_DEBUG_USE_KMS_MODIFIERS=0 绕过 BSP sun4i-drm 驱动
#      AFBC modifier 跨节点 AddFB2 导入失败的 bug (HDMI 纯黑画面根因)
#
# 用法: sudo ./fix-display.sh [--dp|--edp]   (幂等, 可重复执行; 改 DTB/cma 后需重启)
#
set -euo pipefail

DTB="/boot/dtb/allwinner/sun55i-t527-avaota-a1.dtb"
EDP_NODE="/soc@3000000/drm_edp@5720000"
EXTLINUX="/boot/extlinux/extlinux.conf"
GDM_DROPIN_DIR="/etc/systemd/system/gdm3.service.d"
GDM_DROPIN="${GDM_DROPIN_DIR}/10-no-kms-modifiers.conf"
ENV_FILE="/etc/environment"

MODE="--dp"
[[ $# -le 1 ]] || { echo "用法: $0 [--dp|--edp]"; exit 1; }
[[ $# -eq 1 ]] && { case "$1" in --dp|--edp) MODE="$1";; *) echo "未知参数: $1"; exit 1;; esac; }

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行"; exit 1; }

# 板型校验
MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)
if [[ "${MODEL}" != "Avaota A1" ]]; then
    warn "设备型号为 '${MODEL:-unknown}', 非 Avaota A1 (T527), 继续执行可能有风险"
    read -rp "仍要继续? [y/N] " ans; [[ "${ans}" =~ ^[Yy] ]] || exit 1
fi

command -v fdtput >/dev/null || { echo "缺少 fdtput, 先 apt install device-tree-compiler"; exit 1; }

# ---------------------------------------------------------------- DTB (DP/eDP) --
log "配置 DTB 显示口模式: ${MODE}"
if [[ ! -f "${DTB}.orig" ]]; then
    cp "${DTB}" "${DTB}.orig"
    log "已备份出厂 DTB -> ${DTB}.orig"
fi

get_status() { fdtget "${DTB}" "$1" status 2>/dev/null || echo none; }

need_fix=0
if [[ "${MODE}" == "--dp" ]]; then
    [[ "$(fdtget "${DTB}" "${EDP_NODE}" compatible 2>/dev/null)" == "allwinner,drm-dp" ]] || need_fix=1
    [[ "$(get_status /edp_panel)" == "disabled" ]] || need_fix=1
    [[ "$(get_status /edp_backlight)" == "disabled" ]] || need_fix=1
else
    [[ "$(fdtget "${DTB}" "${EDP_NODE}" compatible 2>/dev/null)" == "allwinner,drm-edp" ]] || need_fix=1
    [[ "$(get_status /edp_panel)" == "okay" ]] || need_fix=1
    [[ "$(get_status /edp_backlight)" == "okay" ]] || need_fix=1
    [[ "$(fdtget "${DTB}" /edp_panel/panel-timing vactive 2>/dev/null)" == "1440" ]] || need_fix=1
fi

if [[ ${need_fix} -eq 1 ]]; then
    # 切换模式前, 若存在另一种模式的可用状态则备份
    case "$(fdtget "${DTB}" "${EDP_NODE}" compatible 2>/dev/null)" in
        allwinner,drm-edp)
            [[ -f "${DTB}.edp-fixed" ]] || cp "${DTB}" "${DTB}.edp-fixed" ;;
        allwinner,drm-dp)
            [[ -f "${DTB}.dp-auto" ]] || cp "${DTB}" "${DTB}.dp-auto" ;;
    esac
    if [[ "${MODE}" == "--dp" ]]; then
        # DP 模式: 驱动经 AUX 读 EDID, 不需要 panel 节点 (probe 也不查找)
        fdtput -t s "${DTB}" "${EDP_NODE}" compatible "allwinner,drm-dp"
        fdtput -t s "${DTB}" /edp_panel status disabled
        fdtput -t s "${DTB}" /edp_backlight status disabled
        log "DTB 已切换为 DP 模式 (EDID 自动)"
    else
        # eDP 模式: 固定 timing。刻意不动 edp0@5720000 (非 DRM 老框架, 同地址冲突) 和 tcon4 (eDP 由 tcon3 供时序)
        fdtput -t s "${DTB}" "${EDP_NODE}" compatible "allwinner,drm-edp"
        fdtput -t s "${DTB}" /edp_panel status okay
        fdtput -t s "${DTB}" /edp_backlight status okay
        # 2560x1440@60 CVT-RB: pixel 241.5MHz
        fdtput -t i "${DTB}" /edp_panel/panel-timing \
            clock-frequency 241500000 \
            hactive 2560  hback-porch 80  hfront-porch 48  hsync-len 32 \
            vactive 1440  vback-porch 33  vfront-porch 3   vsync-len 5  \
            hsync-active 1 vsync-active 1
        log "DTB 已切换为 eDP 模式 (固定 2560x1440@60)"
    fi
else
    log "DTB 已是目标状态, 跳过"
fi

# ------------------------------------------------------- extlinux (CMA 256M) --
log "检查 ${EXTLINUX} (cma)"
if ! grep -q 'cma=256M' "${EXTLINUX}"; then
    [[ -f "${EXTLINUX}.bak" ]] || cp "${EXTLINUX}" "${EXTLINUX}.bak"
    sed -i 's/cma=64M/cma=256M/' "${EXTLINUX}"
    log "cma=64M -> cma=256M"
else
    log "cma=256M 已生效, 跳过"
fi

# --------------------------------------------------- mutter AFBC 黑屏绕过 --
log "检查 GDM drop-in (mutter 禁用 KMS modifiers)"
if [[ ! -f "${GDM_DROPIN}" ]]; then
    mkdir -p "${GDM_DROPIN_DIR}"
    cat > "${GDM_DROPIN}" <<'EOF'
# BSP sun4i-drm 拒绝带 AFBC modifier 的跨节点 AddFB2 导入,
# mutter 据 IN_FORMATS 用 AFBC 建 scanout buffer 会黑屏, 强制 LINEAR 绕过。
[Service]
Environment=MUTTER_DEBUG_USE_KMS_MODIFIERS=0
EOF
    systemctl daemon-reload
    log "已写入 ${GDM_DROPIN}"
else
    log "drop-in 已存在, 跳过"
fi

log "检查 ${ENV_FILE} 兜底"
if ! grep -q '^MUTTER_DEBUG_USE_KMS_MODIFIERS=0$' "${ENV_FILE}"; then
    cp "${ENV_FILE}" "${ENV_FILE}.bak.nokmsmod" 2>/dev/null || true
    echo 'MUTTER_DEBUG_USE_KMS_MODIFIERS=0' >> "${ENV_FILE}"
    log "已追加兜底环境变量"
else
    log "环境变量已存在, 跳过"
fi

# ------------------------------------------------------------------- 收尾 --
log "全部完成 — 若修改了 DTB/cma 请重启"
echo
echo "重启后验证:"
echo "  ls /sys/class/drm/ | grep -E 'DP|eDP'   # DP 模式应出现 card0-DP-1"
echo "  cat /sys/class/drm/card0-DP-1/status    # 应为 connected"
echo "  wc -c /sys/class/drm/card0-DP-1/edid    # 应非 0 (EDID 已读出)"
echo "  cat /sys/class/drm/card0-HDMI-A-1/status # 应为 connected"
echo "  grep CmaTotal /proc/meminfo              # 应为 262144 kB"
echo
echo "模式切换: $0 --dp (EDID 自动) / $0 --edp (固定 2560x1440)"
echo "回滚:"
echo "  cp ${DTB}.orig ${DTB}                  # 出厂状态"
echo "  cp ${DTB}.edp-fixed ${DTB}             # eDP 固定 timing 状态"
echo "  cp ${EXTLINUX}.bak ${EXTLINUX}"
echo "  rm ${GDM_DROPIN} && sed -i '/MUTTER_DEBUG_USE_KMS_MODIFIERS/d' ${ENV_FILE} && systemctl daemon-reload"
