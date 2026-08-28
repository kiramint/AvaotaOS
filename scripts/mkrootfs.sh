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
# Ubuntu chroot 里 systemctl enable 会直接 no-op ("Running in chroot, ignoring"),
# 必须手写 wants 符号链接, 否则开机永远不跑扩容。
mkdir -p ${ROOTFS}/usr/local/bin \
         ${ROOTFS}/etc/systemd/system/multi-user.target.wants

cp ../target/services/init-resize/init-resize.sh ${ROOTFS}/usr/local/bin/
cp ../target/services/init-resize/init-resize.service ${ROOTFS}/etc/systemd/system/
chmod +x ${ROOTFS}/usr/local/bin/init-resize.sh
ln -sf /etc/systemd/system/init-resize.service \
    ${ROOTFS}/etc/systemd/system/multi-user.target.wants/init-resize.service

cp ../target/services/avaota-bluetooth/avaota-bluetooth.sh ${ROOTFS}/usr/local/bin/
cp ../target/services/avaota-bluetooth/avaota-bluetooth.service ${ROOTFS}/etc/systemd/system/
chmod +x ${ROOTFS}/usr/local/bin/avaota-bluetooth.sh
ln -sf /etc/systemd/system/avaota-bluetooth.service \
    ${ROOTFS}/etc/systemd/system/multi-user.target.wants/avaota-bluetooth.service

sed -i "s|#PermitRootLogin prohibit-password|PermitRootLogin yes|g" ${ROOTFS}/etc/ssh/sshd_config
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

setup_initramfs(){
# qemu-user 下 zstd 压缩极慢/假死, 强制 gzip (内核 RD_GZIP=y)
mkdir -p ${ROOTFS}/etc/initramfs-tools/conf.d
echo "COMPRESS=gzip" > ${ROOTFS}/etc/initramfs-tools/conf.d/avaota-compress.conf
}

setup_hostname_fstab(){
echo "${BOARD_NAME}" > ${ROOTFS}/etc/hostname
# Ubuntu: 127.0.1.1 才是本机主机名; 127.0.0.1 留给 localhost。
# 以前用单引号把 ${BOARD_NAME} 写进文件, systemd 丢掉非法字符后主机名变成 BOARDNAME。
sed -i -e '/BOARD_NAME/d' -e '/[[:space:]]BOARDNAME$/d' ${ROOTFS}/etc/hosts
if ! grep -qE "^127\.0\.1\.1[[:space:]]+${BOARD_NAME}([[:space:]]|$)" ${ROOTFS}/etc/hosts 2>/dev/null; then
    echo "127.0.1.1	${BOARD_NAME}" >> ${ROOTFS}/etc/hosts
fi

cat /dev/null > ${ROOTFS}/etc/fstab

cat <<EOF >> ${ROOTFS}/etc/fstab
UUID=${BOOT_UUID}  /boot           vfat    defaults          0       0
UUID=${ROOT_UUID}  /               ext4    defaults,noatime  0       1
EOF
}

setup_board_services(){
# AIC8800 是 SDIO: 芯片要等 aic8800_bsp 调 sunxi-rfkill 上电后再 rescan。
# 不自动加载的话, udev 会对未上电的 sdc1 发 CMD52, 串口刷 RTO, WiFi 永远枚举不到。
mkdir -p ${ROOTFS}/etc/modules-load.d
cat > ${ROOTFS}/etc/modules-load.d/aic8800.conf << 'EOF'
aic8800_bsp
aic8800_fdrv
aic8800_btlpm
EOF

# 这块板没有 SATA/ATA, smartd 开机必失败。包留下给 USB 盘手动 smartctl。
mkdir -p ${ROOTFS}/etc/systemd/system
ln -sf /dev/null ${ROOTFS}/etc/systemd/system/smartmontools.service
ln -sf /dev/null ${ROOTFS}/etc/systemd/system/smartd.service
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
setup_initramfs
clean_rootfs
setup_hostname_fstab
setup_board_services
#pack_target_pcakages

UMOUNT_ALL

mv ${ROOTFS} rootfs-${VERSION}-${TYPE}

pushd rootfs-${VERSION}-${TYPE}
tar -zcvf ${workspace}/rootfs-${VERSION}-${TYPE}.tar.gz *
popd

rm -rf rootfs-${VERSION}-${TYPE}
