#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0
#
# This file is a part of the Avaota Build Framework
# https://github.com/AvaotaSBC/AvaotaOS/

__usage="
Usage: mkrootfs [OPTIONS]
Build Rootfs rootfs.
Run in root user.
The target rootfs will be generated in the build folder of the directory where the mkrootfs.sh script is located.

Options: 
  -m, --mirror MIRROR_ADDR         The URL/path of target mirror address.
  -r, --rootfs ROOTFS_DIR          The directory name of rootfs rootfs.
  -v, --version ROOTFS_VER         The version of ubuntu/debian.
  -b, --board BOARD                The target board.
  -t, --type ROOTFS_TYPE           The type of rootfs: cli, xfce, gnome, kde.
  -h, --help                       Show command help.
"

help()
{
    echo "$__usage"
    exit $1
}

default_param() {
    BOARD=avaota-a1
    ROOTFS=rootfs
    VERSION=jammy
    TYPE=cli
    if [[ "${VERSION}" == "jammy" || "${VERSION}" == "noble" ]];then
        MIRROR=http://ports.ubuntu.com
    elif [[ "${VERSION}" == "bookworm" || "${VERSION}" == "trixie" ]];then
        MIRROR=http://deb.debian.org/debian
    fi
}

parseargs()
{
    if [ "x$#" == "x0" ]; then
        return 0
    fi

    while [ "x$#" != "x0" ];
    do
        if [ "x$1" == "x-h" -o "x$1" == "x--help" ]; then
            return 1
        elif [ "x$1" == "x" ]; then
            shift
        elif [ "x$1" == "x-m" -o "x$1" == "x--mirror" ]; then
            MIRROR=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-r" -o "x$1" == "x--rootfs" ]; then
            ROOTFS=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-v" -o "x$1" == "x--version" ]; then
            VERSION=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-b" -o "x$1" == "x--BOARD" ]; then
            BOARD=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-t" -o "x$1" == "x--type" ]; then
            TYPE=`echo $2`
            shift
            shift
        else
            echo `date` - ERROR, UNKNOWN params "$@"
            return 2
        fi
    done
}

UMOUNT_ALL(){
    set +e
    if grep -q "${ROOTFS}/dev " /proc/mounts ; then
        umount -l ${ROOTFS}/dev
    fi
    if grep -q "${ROOTFS}/proc " /proc/mounts ; then
        umount -l ${ROOTFS}/proc
    fi
    if grep -q "${ROOTFS}/sys " /proc/mounts ; then
        umount -l ${ROOTFS}/sys
    fi
    set -e
}

run_debootstrap(){
    if [[ "${VERSION}" == "jammy" || "${VERSION}" == "noble" ]];then
        LIST="main multiverse restricted universe"
        SRC_LIST="'deb ${MIRROR} ${VERSION} main multiverse restricted universe' \
                  'deb ${MIRROR} ${VERSION}-updates main multiverse restricted universe'"
    else
        echo "unsupported version: ${VERSION} (only jammy/noble)"
        exit 2
    fi
    
    BASE_PKGS=$(cat ../os/${VERSION}/base-packages.list)
    EXT_PKGS=""
    
    if [ "${TYPE}" != "cli" ];then
        echo "Build desktop image."
        EXT_PKGS=$(cat ../os/${VERSION}/${TYPE}-packages.list)
    fi
    
    PACKAGES="${BASE_PKGS} ${EXT_PKGS}"

    echo You are running this scipt on a ${HOST_ARCH} mechine....

    if [ -d ${ROOTFS} ];then rm -rf ${ROOTFS}; fi
    mkdir ${ROOTFS}

    if [ "${HOST_ARCH}" != "${ARCH}" ] && [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ];then
        echo "ERROR: qemu-aarch64 binfmt_misc not registered on host, cannot build ${ARCH} rootfs."
        echo "Fix: sudo apt install --reinstall qemu-user-static (或新版 Ubuntu 的 qemu-user-binfmt) && sudo systemctl restart systemd-binfmt"
        exit 2
    fi

    if [ "${ARCH}" == "arm64" ];then
        sudo mmdebstrap --architectures=arm64 \
        --include="${PACKAGES}" \
        ${VERSION} ${ROOTFS} \
        "deb ${MIRROR} ${VERSION} ${LIST}" \
        "deb ${MIRROR} ${VERSION}-updates ${LIST}" || {
            echo "mmdebstrap failed!"
            exit 2
        }
    elif [ "${ARCH}" == "arm" ];then
        sudo mmdebstrap --architectures=armhf \
        --include="${PACKAGES}" \
        ${VERSION} ${ROOTFS} \
        "deb ${MIRROR} ${VERSION} ${LIST}" \
        "deb ${MIRROR} ${VERSION}-updates ${LIST}" || {
            echo "mmdebstrap failed!"
            exit 2
        }
    else
        echo "unsupported arch."
        exit 2
    fi

    if [ ! -x ${ROOTFS}/bin/sh ];then
        echo "rootfs incomplete after mmdebstrap!"
        exit 2
    fi
}

prepare_apt-list(){
if [[ "${VERSION}" == "jammy" ]];then
    cat ../os/${VERSION}/apt-list/sources.list > ${ROOTFS}/etc/apt/sources.list
    sed -i "s|http://ports.ubuntu.com/ubuntu-ports|${MIRROR}|g" ${ROOTFS}/etc/apt/sources.list
elif [ "${VERSION}" == "noble" ];then
    echo "# Ubuntu sources have moved to /etc/apt/sources.list.d/ubuntu.sources" > ${ROOTFS}/etc/apt/sources.list
    cat ../os/${VERSION}/apt-list/ubuntu.sources > ${ROOTFS}/etc/apt/sources.list.d/ubuntu.sources
    sed -i "s|http://ports.ubuntu.com/ubuntu-ports|${MIRROR}|g" ${ROOTFS}/etc/apt/sources.list.d/ubuntu.sources
fi
}

setup_mount_resolv(){
mount --bind /dev ${ROOTFS}/dev
mount -t proc /proc ${ROOTFS}/proc
mount -t sysfs /sys ${ROOTFS}/sys

cp -b /etc/resolv.conf ${ROOTFS}/etc/resolv.conf
}

setup_dhcp(){
    echo "will overwriten by board.conf"
}

setup_armhf_compate(){
LC_ALL=C LANGUAGE=C LANG=C chroot ${ROOTFS} dpkg --add-architecture armhf
LC_ALL=C LANGUAGE=C LANG=C chroot ${ROOTFS} apt-get update
LC_ALL=C LANGUAGE=C LANG=C chroot ${ROOTFS} apt-get install libc6:armhf libstdc++6:armhf -y
}

setup_firstrun(){
cp ../target/services/init-resize/init-resize.sh ${ROOTFS}/usr/local/bin
cp ../target/services/init-resize/init-resize.service ${ROOTFS}/etc/systemd/system/

chmod +x ${ROOTFS}/usr/local/bin/init-resize.sh

chroot ${ROOTFS} sudo systemctl enable init-resize.service

sed -i "s|#PermitRootLogin prohibit-password|PermitRootLogin yes|g" ${ROOTFS}/etc/ssh/sshd_config

# Allow root ssh login
}

clean_rootfs(){
chroot ${ROOTFS} apt clean
if [ "$HOST_ARCH" != "$ARCH" ];then
    if [ ${ARCH} == "arm64" ];then
        sudo rm ${ROOTFS}/usr/bin/qemu-aarch64-static
    elif [ ${ARCH} == "arm" ];then
        sudo rm ${ROOTFS}/usr/bin/qemu-arm-static
    fi
else
echo "You are running this script on a ${ARCH} mechine, progress...."
fi
}

setup_display_fixes(){
# BSP sun4i-drm 驱动的 primary plane 广播 AFBC modifier, 但其 GEM 导入路径
# 拒绝带 AFBC modifier 的跨节点 AddFB2 (mutter: renderD128 渲染 -> card0 扫描输出),
# 导致 GDM/gnome-shell 黑屏 ("gbm_surface_lock_front_buffer failed")。
# 强制 mutter 使用 LINEAR buffer 绕过, 见 AGENTS.md 问题二。
if [ "${TYPE}" == "gnome" ];then
    echo "apply gnome display fixes (mutter linear buffers)."
    mkdir -p ${ROOTFS}/etc/systemd/system/gdm3.service.d
    cat <<'EOF' > ${ROOTFS}/etc/systemd/system/gdm3.service.d/10-no-kms-modifiers.conf
[Service]
Environment=MUTTER_DEBUG_USE_KMS_MODIFIERS=0
EOF
    grep -q '^MUTTER_DEBUG_USE_KMS_MODIFIERS=0$' ${ROOTFS}/etc/environment 2>/dev/null || \
        echo 'MUTTER_DEBUG_USE_KMS_MODIFIERS=0' >> ${ROOTFS}/etc/environment
fi
}

setup_initramfs_debug(){
# Avaota A1 initramfs 调试: initramfs 下串口 shell 无输入 (RX 不通),
# 无法手工 devmem。此 hook 在 init-premount 阶段后台循环把 SD/MMC 相关
# 寄存器/regulator/分区表打到串口 (输出带 AVAOTA-MMCDBG: 前缀, 便于 grep)。
# 依赖 busybox devmem (busybox-initramfs 自带, 已验证 applet 存在)。
mkdir -p ${ROOTFS}/etc/initramfs-tools/scripts/init-premount
# qemu-user 下 zstd 压缩极慢/假死, 强制 gzip (内核 RD_GZIP=y)
mkdir -p ${ROOTFS}/etc/initramfs-tools/conf.d
echo "COMPRESS=gzip" > ${ROOTFS}/etc/initramfs-tools/conf.d/avaota-compress.conf
cat <<'EOF' > ${ROOTFS}/etc/initramfs-tools/scripts/init-premount/avaota-mmc-debug
#!/bin/sh
# Avaota A1 SD/MMC register auto-dump v4 (serial output only)
# v4: HIT 时全量 dump SDMMC0 0x00-0x5C + CSDC/THLD/EDSD/DRV_DL/SAMP_DL/DS_DL
#     (PF=0xF0 已确认: u-boot/内核 ON 窗口均 0x0F222222, pinmux 排除);
#     v3: CLKCR 非零触发抓 ON 窗口; v2: 50ms 连采; eMMC 对照; 压低 console 噪音。

PRN() { echo "AVAOTA-MMCDBG: $*"; }

# mkinitramfs 生成阶段会以 "prereqs" 参数调用本脚本查询依赖, 必须立即退出;
# 若在此路径起后台循环, 后台进程持有 stdout 管道会让 mkinitramfs 阻塞等
# EOF (qemu 下表现为 pack 卡死), 且循环输出会被误当成 prereq 列表。
case "$1" in
prereqs)
	echo ""
	exit 0
	;;
esac

# init-premount may run before initramfs has populated /dev.  The diagnostic
# commands below intentionally redirect errors to /dev/null, and the worker
# writes to /dev/console; create the two standard character devices first so
# an early /dev-less boot does not print shell redirection errors.
mkdir -p /dev 2>/dev/null || exit 0
[ -e /dev/null ] || mknod -m 666 /dev/null c 1 3 2>/dev/null || true
[ -e /dev/console ] || mknod -m 600 /dev/console c 5 1 2>/dev/null || true

regs_sd() {
	# SDMMC0 全量: 0x00 GCTRL / 04 CLKCR / 08 TMOUT / 0C WIDTH / 18 CMDR /
	# 1C CARG / 30 IMASK / 38 RINTR / 3C STAS / 40 FTRGL / 54 CSDC / 58 A12A /
	# 5C NTSR / 140 DRV_DL / 144 SAMP_DL / 148 DS_DL
	echo "g=$(devmem 0x04020000 2>/dev/null) c=$(devmem 0x04020004 2>/dev/null) t=$(devmem 0x04020008 2>/dev/null) w=$(devmem 0x0402000C 2>/dev/null) cmdr=$(devmem 0x04020018 2>/dev/null) carg=$(devmem 0x0402001C 2>/dev/null) imask=$(devmem 0x04020030 2>/dev/null) rintr=$(devmem 0x04020038 2>/dev/null) stas=$(devmem 0x0402003C 2>/dev/null) ftrl=$(devmem 0x04020040 2>/dev/null) csdc=$(devmem 0x04020054 2>/dev/null) a12a=$(devmem 0x04020058 2>/dev/null) ntsr=$(devmem 0x0402005C 2>/dev/null) drv=$(devmem 0x04020140 2>/dev/null) samp=$(devmem 0x04020144 2>/dev/null) dsdl=$(devmem 0x04020148 2>/dev/null)"
}

regs_emmc() {
	echo "EMMC GCTRL=$(devmem 0x04022000 2>/dev/null) CLKCR=$(devmem 0x04022004 2>/dev/null) NTSR=$(devmem 0x0402205C 2>/dev/null) CCU838=$(devmem 0x02001838 2>/dev/null) CCU84C=$(devmem 0x0200184C 2>/dev/null)"
}

dump_static() {
	PRN "PF380=$(devmem 0x02000380 2>/dev/null) PF384=$(devmem 0x02000384 2>/dev/null) PF388=$(devmem 0x02000388 2>/dev/null) PF390=$(devmem 0x02000390 2>/dev/null)"
	PRN "$(regs_emmc)"
	dmesg 2>/dev/null | tail -1 | while read l; do PRN "dmesg-last: $l"; done
	cat /proc/partitions 2>/dev/null | while read maj min blocks name rest; do
		case "$name" in "" | name) continue ;; esac
		PRN "partition $name blocks=$blocks"
	done
}

dump_burst() {
	# CLKCR 非零 = pm ON 窗口 (idle 时被复位为 0); 命中即快照候选寄存器
	i=0
	hits=0
	while [ $i -lt 150 ]; do
		c=$(devmem 0x04020004 2>/dev/null)
		if [ -n "$c" ] && [ "$c" != "0x00000000" ] && [ $hits -lt 3 ]; then
			PRN "HIT$i CLKCR=$c $(regs_sd)"
			hits=$((hits + 1))
		fi
		i=$((i + 1))
	done
	[ $hits -eq 0 ] && PRN "no ON window caught in this round"
}

dump_dyn() {
	for r in /sys/class/regulator/regulator*; do
		[ -d "$r" ] || continue
		PRN "regulator $(cat $r/name 2>/dev/null): state=$(cat $r/state 2>/dev/null) uv=$(cat $r/microvolts 2>/dev/null)"
	done
}

(
	if [ -c /dev/console ]; then
		exec >/dev/console 2>&1
	fi
	sleep 6
	# 压低 console loglevel 到 3 (ERR 及以下隐藏), 重扫的 RTO 刷屏不再淹没 dump;
	# dmesg 缓冲区不受影响
	echo 3 > /proc/sys/kernel/printk 2>/dev/null
	n=0
	while [ $n -lt 40 ]; do
		PRN "==== round $n $(date +%T) ===="
		dump_static
		dump_burst
		[ $((n % 4)) -eq 0 ] && dump_dyn
		n=$((n + 1))
	done
) &
EOF
chmod +x ${ROOTFS}/etc/initramfs-tools/scripts/init-premount/avaota-mmc-debug
}

setup_hostname_fstab(){
echo '127.0.0.1	${BOARD_NAME}' >> ${ROOTFS}/etc/hosts

cat /dev/null > ${ROOTFS}/etc/hostname
echo '${BOARD_NAME}' >> ${ROOTFS}/etc/hostname

cat /dev/null > ${ROOTFS}/etc/fstab

cat <<EOF >> ${ROOTFS}/etc/fstab
UUID=${BOOT_UUID}  /boot           vfat    defaults          0       0
UUID=${ROOT_UUID}  /               ext4    defaults,noatime  0       1
EOF
}

pack_target_pcakages(){
    if [ -d target_packages ];then
        rm -rf target_packages
    fi
    mkdir target_packages
    for pkg in $(ls ${workspace}/../target/packages)
    do
        gen_md5 \
            ${workspace}/../target/packages/${pkg}/DEBIAN/md5sums \
            ${workspace}/../target/packages/${pkg}
        dpkg-deb -b \
            ${workspace}/../target/packages/${pkg} \
            target_packages
        if [ $? == 0 ]; then
            echo "packaged $pkg."
        else
            echo "can not package $pkg."
        fi
        rm ${workspace}/../target/packages/${pkg}/DEBIAN/md5sums
    done
}

HOST_ARCH=$(arch)

workspace=$(pwd)
cd ${workspace}

default_param
parseargs "$@" || help $?

source ../boards/${BOARD}.conf
source ${workspace}/../scripts/lib/packages/useroverlay-deb.sh

# TODO: download rootfs from Syter's server

run_debootstrap
prepare_apt-list
setup_mount_resolv

trap 'UMOUNT_ALL' EXIT

setup_dhcp

#if [ "${ARCH}" == "arm64" ];then
#setup_armhf_compate
#fi

setup_firstrun
setup_display_fixes
setup_initramfs_debug
clean_rootfs
setup_hostname_fstab
#pack_target_pcakages

UMOUNT_ALL

mv ${ROOTFS} rootfs-${VERSION}-${TYPE}

pushd rootfs-${VERSION}-${TYPE}
tar -zcvf ${workspace}/rootfs-${VERSION}-${TYPE}.tar.gz *
popd

rm -rf rootfs-${VERSION}-${TYPE}
