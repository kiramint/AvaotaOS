#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0
#
# This file is a part of the Avaota Build Framework
# https://github.com/AvaotaSBC/AvaotaOS/

__usage="
Usage: pack [OPTIONS]
Pack bootable image.
The target sdcard.img will be generated in the build folder of the directory where the mklinux.sh script is located.

Options: 
  -b,  -board BOARD                   The target board.
  -t, --type ROOTFS_TYPE              The rootfs type.
  -u, --user SYS_USER                 The normal user of rootfs.
  -p, --password SYS_PASSWORD         The password of user.
  -s, --supassword ROOT_PASSWORD      The password of root.
  -h, --help                          Show command help.
"

help()
{
    echo "$__usage"
    exit $1
}

default_param() {
    TYPE=cli
    VERSION=jammy
    BOARD=avaota-a1
    SYS_USER=avaota
    SYS_PASSWORD=avaota
    ROOT_PASSWORD=avaota
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
        elif [ "x$1" == "x-b" -o "x$1" == "x--board" ]; then
            BOARD=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-t" -o "x$1" == "x--type" ]; then
            TYPE=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-v" -o "x$1" == "x--version" ]; then
            VERSION=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-u" -o "x$1" == "x--user" ]; then
            SYS_USER=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-p" -o "x$1" == "x--password" ]; then
            SYS_PASSWORD=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-s" -o "x$1" == "x--supassword" ]; then
            ROOT_PASSWORD=`echo $2`
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
    
    if grep -q "${workspace}/rootfs_dir/boot " /proc/mounts ; then
        umount ${workspace}/rootfs_dir/boot
    fi
    
    if [ -d ${workspace}/rootfs_dir ]; then
        if grep -q "${workspace}/rootfs_dir " /proc/mounts ; then
            umount ${workspace}/rootfs_dir
        fi
    fi
    
    if [ -d ${workspace}/rootfs_dir ]; then
        rm -rf ${workspace}/rootfs_dir
    fi
    
    if [ "x$device" != "x" ]; then
        losetup -d ${device}
        device=""
    fi
    
    set -e
}

apply_board_fixes(){
# 旧 rootfs tar 里的 hostname 曾写成字面量 ${BOARD_NAME}, systemd 清洗后变成 BOARDNAME。
echo "${BOARD_NAME}" > ${workspace}/rootfs_dir/etc/hostname
sed -i -e '/BOARD_NAME/d' -e '/[[:space:]]BOARDNAME$/d' ${workspace}/rootfs_dir/etc/hosts
if ! grep -qE "^127\.0\.1\.1[[:space:]]+${BOARD_NAME}([[:space:]]|$)" ${workspace}/rootfs_dir/etc/hosts 2>/dev/null; then
    echo "127.0.1.1	${BOARD_NAME}" >> ${workspace}/rootfs_dir/etc/hosts
fi

mkdir -p ${workspace}/rootfs_dir/etc/modules-load.d
cat > ${workspace}/rootfs_dir/etc/modules-load.d/aic8800.conf << 'EOF'
aic8800_bsp
aic8800_fdrv
aic8800_btlpm
EOF

mkdir -p ${workspace}/rootfs_dir/usr/local/bin \
         ${workspace}/rootfs_dir/etc/systemd/system/multi-user.target.wants
cp ${workspace}/../target/services/init-resize/init-resize.sh \
    ${workspace}/rootfs_dir/usr/local/bin/
cp ${workspace}/../target/services/init-resize/init-resize.service \
    ${workspace}/rootfs_dir/etc/systemd/system/
chmod +x ${workspace}/rootfs_dir/usr/local/bin/init-resize.sh
ln -sf /etc/systemd/system/init-resize.service \
    ${workspace}/rootfs_dir/etc/systemd/system/multi-user.target.wants/init-resize.service

cp ${workspace}/../target/services/avaota-bluetooth/avaota-bluetooth.sh \
    ${workspace}/rootfs_dir/usr/local/bin/
cp ${workspace}/../target/services/avaota-bluetooth/avaota-bluetooth.service \
    ${workspace}/rootfs_dir/etc/systemd/system/
chmod +x ${workspace}/rootfs_dir/usr/local/bin/avaota-bluetooth.sh
ln -sf /etc/systemd/system/avaota-bluetooth.service \
    ${workspace}/rootfs_dir/etc/systemd/system/multi-user.target.wants/avaota-bluetooth.service

mkdir -p ${workspace}/rootfs_dir/etc/systemd/system
ln -sf /dev/null ${workspace}/rootfs_dir/etc/systemd/system/smartmontools.service
ln -sf /dev/null ${workspace}/rootfs_dir/etc/systemd/system/smartd.service
}

setup_users(){
#SYS_USER=avaota
#SYS_PASSWORD=avaota
#ROOT_PASSWORD=avaota

cat <<EOF | LC_ALL=C LANGUAGE=C LANG=C chroot ${workspace}/rootfs_dir adduser ${SYS_USER}
${SYS_USER}
${SYS_PASSWORD}
${SYS_PASSWORD}
0
0
0
0
y
EOF

# sudo 并入 usermod: 新版 adduser (>=3.137, noble+) 已删除 addgroup 双参数用法
# video/render: /dev/dri/* 访问权限, SSH/TTY 下 GPU 加速必需 (否则静默回落 llvmpipe)
# dialout/tty:   串口设备访问
# audio: /dev/snd (aplay 否则报 no soundcards)
# bluetooth: BlueZ 设备节点 (旧 tar 可能还没装 bluez, 先 groupadd -f)
# plugdev: 可移动介质 / rfkill
chroot ${workspace}/rootfs_dir /bin/bash -c "
groupadd -f audio
groupadd -f bluetooth
groupadd -f plugdev
usermod -aG sudo,video,render,dialout,tty,audio,bluetooth,plugdev ${SYS_USER}
"

# username：avaota
# password：avaota

cat <<EOF | LC_ALL=C LANGUAGE=C LANG=C chroot ${workspace}/rootfs_dir passwd root
${ROOT_PASSWORD}
${ROOT_PASSWORD}
EOF

# username：root
# password：avaota
}

pack_sdcard()
{

    cd ${workspace}
    if [ ! -f ${workspace}/rootfs-${VERSION}-${TYPE}.tar.gz ];then
        echo "rootfs-${VERSION}-${TYPE}.tar.gz not found, build rootfs first!"
        exit 2
    fi
    if [ ! -d ${workspace}/deb-data ];then
        echo "deb-data not found, build kernel packages first!"
        exit 2
    fi
    if [ ! -d ${workspace}/${BOARD}-kernel-pkgs ];then
        echo "kernel packages not found, build kernel packages first!"
        exit 2
    fi
    if [ -f ${workspace}/sdcard.img ];then rm -rf ${workspace}/sdcard.img; fi
    if [ -d ${workspace}/rootfs_dir ];then rm -rf ${workspace}/rootfs_dir; fi
    
    trap 'UMOUNT_ALL' EXIT
    
    img_size=$(($(du -sh --block-size=1MiB ${workspace}/rootfs-${VERSION}-${TYPE}.tar.gz | cut -f 1 | xargs)*3+${BOOT_SIZE}+$(du -sh --block-size=1MiB ${workspace}/deb-data | cut -f 1 | xargs)+880))
    
    dd if=/dev/zero of=${workspace}/sdcard.img bs=1MiB count=${img_size} status=progress && sync
    
    parted ${workspace}/sdcard.img mklabel ${part_table} mkpart primary fat32 $((${OFFSET}*2048))s $(((${BOOT_SIZE}*2048)-1))s
    parted ${workspace}/sdcard.img -s set 1 boot on
    parted ${workspace}/sdcard.img mkpart primary ext4 $((${BOOT_SIZE}*2048))s 100%

    device=$(losetup -f --show -P ${workspace}/sdcard.img) || {
        echo "ERROR: failed to attach sdcard.img to a loop device"
        exit 2
    }
    partprobe ${device} || true

    # losetup -P creates partition devices directly. Avoid kpartx mapper
    # nodes: if kpartx is missing or leaves stale mappings, mkfs/mount can
    # fail while the old script continues and produces an all-zero image.
    bootpart=${device}p1
    rootpart=${device}p2
    for retry in $(seq 1 20);do
        if [ -b "${bootpart}" ] && [ -b "${rootpart}" ];then
            break
        fi
        partx -u ${device} >/dev/null 2>&1 || true
        sleep 1
    done
    if [ ! -b "${bootpart}" ] || [ ! -b "${rootpart}" ];then
        echo "ERROR: loop partition devices not found: ${bootpart}, ${rootpart}"
        exit 2
    fi
    
    mkfs.vfat -n boot -F 32 -i 0x${BOOT_UUID//-/} ${bootpart} || exit 2
    mkfs.ext4 -L rootfs -U ${ROOT_UUID} ${rootpart} || exit 2
    
    mkdir ${workspace}/rootfs_dir
    mount ${rootpart} ${workspace}/rootfs_dir || exit 2
    
    tar -zxvf ${workspace}/rootfs-${VERSION}-${TYPE}.tar.gz -C ${workspace}/rootfs_dir
    
    rm -f ${workspace}/rootfs_dir/root/.bash_history

    # 旧 rootfs tar 可能仍带 MMC 寄存器 dump hook (会压低 printk 并刷屏)。
    # 打镜像前清掉, 这样不必强制重建 rootfs。
    rm -f ${workspace}/rootfs_dir/etc/initramfs-tools/scripts/init-premount/avaota-mmc-debug

    apply_board_fixes

    sync
    sleep 5
    
    if [ ! -d ${workspace}/rootfs_dir/boot ];then mkdir -p ${workspace}/rootfs_dir/boot; fi
    mount ${bootpart} ${workspace}/rootfs_dir/boot || exit 2
    cp -r ${workspace}/${BOARD}-kernel-pkgs ${workspace}/rootfs_dir/kernel-deb
    
    # initramfs 压缩强制 gzip: noble 默认 zstd, 在 qemu-user 模拟下压缩极慢
    # 甚至假死 (pack 阶段 update-initramfs 卡死无输出); 内核 RD_GZIP=y。
    mkdir -p ${workspace}/rootfs_dir/etc/initramfs-tools/conf.d
    echo "COMPRESS=gzip" > ${workspace}/rootfs_dir/etc/initramfs-tools/conf.d/avaota-compress.conf
    
    cat <<EOF | LC_ALL=C LANGUAGE=C LANG=C chroot ${workspace}/rootfs_dir /bin/bash
apt-get remove linux-libc-dev -y
dpkg -i /kernel-deb/linux-libc-dev*.deb
apt-get -f install -y
dpkg -i /kernel-deb/linux-dtb*.deb
dpkg -i /kernel-deb/linux-image*.deb
apt-get -f install -y
EOF
    
    rm -rf ${workspace}/rootfs_dir/kernel-deb
    
    cp -r ${workspace}/bootloader-${BOARD}/* ${workspace}/rootfs_dir/boot
    
    # 用 chroot 内 initramfs-tools 生成的 initrd.img 作为 uInitrd。
    # target/boot/uInitrd 是 2024-04 的静态预编译件, 不含当前 rootfs 的 hook。
    # 必须原样裸拷贝: initrd.img 本身已带压缩 (noble 默认 zstd, RD_ZSTD=y),
    # 内核对 raw initrd 自动探测压缩格式; 严禁再包一层 gzip —— 双重压缩
    # 会让内核解出垃圾 cpio, initramfs 为空, 直落 prepare_namespace panic。
    # u-boot distro boot (booti) 接受裸 initrd, 无需 mkimage uImage 头。
    INITRD_SRC=$(ls ${workspace}/rootfs_dir/boot/initrd.img-* 2>/dev/null | head -1)
    if [ -n "${INITRD_SRC}" ];then
        echo "using ${INITRD_SRC##*/} as uInitrd (raw, includes initramfs hooks)"
        rm -f ${workspace}/rootfs_dir/boot/uInitrd
        cp -v "${INITRD_SRC}" ${workspace}/rootfs_dir/boot/uInitrd || \
            echo "WARN: uInitrd copy failed, boot will fall back to static one"
    else
        echo "WARN: initrd.img not found, keeping static uInitrd"
    fi
    
    cp -rfp ${workspace}/../target/firmware ${workspace}/rootfs_dir/lib/
    
    setup_users
    
    sync
    sleep 10

    # Refuse to package an image unless both filesystems and all boot-critical
    # files are present on the actual loop partitions.
    if [ "$(blkid -s TYPE -o value ${bootpart})" != "vfat" ];then
        echo "ERROR: boot partition is not FAT: ${bootpart}"
        exit 2
    fi
    if [ "$(blkid -s UUID -o value ${bootpart})" != "${BOOT_UUID}" ];then
        echo "ERROR: boot partition UUID mismatch"
        exit 2
    fi
    if [ "$(blkid -s TYPE -o value ${rootpart})" != "ext4" ];then
        echo "ERROR: root partition is not ext4: ${rootpart}"
        exit 2
    fi
    if [ "$(blkid -s UUID -o value ${rootpart})" != "${ROOT_UUID}" ];then
        echo "ERROR: root partition UUID mismatch"
        exit 2
    fi
    for f in Image uInitrd extlinux/extlinux.conf dtb/${DEVICE_DTS}.dtb;do
        if [ ! -s "${workspace}/rootfs_dir/boot/${f}" ];then
            echo "ERROR: boot partition file missing or empty: /${f}"
            exit 2
        fi
    done
    if [ ! -x ${workspace}/rootfs_dir/sbin/init ];then
        echo "ERROR: root filesystem has no executable /sbin/init"
        exit 2
    fi
    
    # 必须在 UMOUNT_ALL 之前写: detach loop 后再 dd 会写入错误节点。
    write_bootloader ${device}
    
    UMOUNT_ALL
}

xz_image()
{
    cd ${workspace}
    if [ -f sdcard.img ];then
        boot_offset=$((${OFFSET} * 1024 * 1024))
        root_offset=$((${BOOT_SIZE} * 1024 * 1024))
        if ! dd if=sdcard.img bs=1 skip=8192 count=32 status=none | grep -aq 'eGON.BT0';then
            echo "ERROR: u-boot signature missing from sdcard.img"
            exit 2
        fi
        if [ "$(blkid -p -O ${boot_offset} -s TYPE -o value sdcard.img)" != "vfat" ];then
            echo "ERROR: FAT filesystem missing from sdcard.img"
            exit 2
        fi
        if [ "$(blkid -p -O ${root_offset} -s TYPE -o value sdcard.img)" != "ext4" ];then
            echo "ERROR: ext4 filesystem missing from sdcard.img"
            exit 2
        fi
        for f in Image uInitrd extlinux/extlinux.conf dtb/${DEVICE_DTS}.dtb;do
            if ! mdir -i "sdcard.img@@${boot_offset}" "::/${f}" >/dev/null 2>&1;then
                echo "ERROR: /${f} missing from FAT filesystem in sdcard.img"
                exit 2
            fi
        done
        pixz sdcard.img
        echo "xz success."
    else
        echo "sdcard.img not found, xz sdcard image failed!"
        exit 2
    fi
}

workspace=$(pwd)
cd ${workspace}

default_param
parseargs "$@" || help $?

source ../boards/${BOARD}.conf
source ../scripts/lib/bootloader/bootloader-${BL_CONFIG}.sh

OFFSET=16
BOOT_SIZE=256
part_table=msdos

pack_sdcard
xz_image
