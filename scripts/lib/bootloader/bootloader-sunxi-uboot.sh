#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0
#
# This file is a part of the Avaota Build Framework
# https://github.com/AvaotaSBC/AvaotaOS/
#
# 主线 u-boot + ATF (BL31) 方案, 适配 Avaota A1 (T527/sun55i):
# - ATF: jernejsk/arm-trusted-firmware a523-v4, PLAT=sun55i_a523 (主线 ATF 无此 plat)
# - u-boot: 主线, avaota-a1_defconfig (2025-07 已合入), 板级修复见 patches/u-boot/avaota-a1/

patch_u-boot()
{
    if [ ! -d ${workspace}/${BL_CONFIG} ];then
        echo "The u-boot source path not exist, exit..."
        exit 2
    fi
    patchdev=$1
    targetdir=$2
    if [ -d ${workspace}/../patches/u-boot/${patchdev} ];then
        for pth in $(ls ${workspace}/../patches/u-boot/${patchdev})
        do
            pushd ${targetdir}
            if patch -p1 --dry-run < ${workspace}/../patches/u-boot/${patchdev}/${pth} >/dev/null 2>&1;then
                patch -N -p1 < ${workspace}/../patches/u-boot/${patchdev}/${pth}
            elif patch -R -p1 --dry-run < ${workspace}/../patches/u-boot/${patchdev}/${pth} >/dev/null 2>&1;then
                echo "patch ${pth} already applied, skip."
            else
                echo "ERROR: patch ${pth} cannot be applied, exit."
                popd
                exit 2
            fi
            popd
        done
    fi
}

build_bootloader(){
  BOARD=$1
  source ../boards/${BOARD}.conf

  if [ ! -d ${workspace}/atf ];then
    echo "ERROR: atf source not found, run fetch first!"
    exit 2
  fi
  if [ ! -d ${workspace}/${BL_CONFIG} ];then
    echo "ERROR: ${BL_CONFIG} source not found, run fetch first!"
    exit 2
  fi

  cd atf
  make CROSS_COMPILE=${KERNEL_GCC} PLAT=${ATF_PLAT} DEBUG=1 bl31
  if [ $? != 0 ];then exit 2; fi
  cd ..

  BL31_BIN=${workspace}/atf/build/${ATF_PLAT}/debug/bl31.bin
  if [ ! -f ${BL31_BIN} ];then
    echo "ERROR: bl31 not found: ${BL31_BIN}"
    exit 2
  fi

  patch_u-boot ${BL_PATCHDIR} ${workspace}/${BL_CONFIG}
  cd ${BL_CONFIG}
  make CROSS_COMPILE=${KERNEL_GCC} distclean
  make CROSS_COMPILE=${KERNEL_GCC} BL31=${BL31_BIN} ${BL_CONF}
  if [ $? != 0 ];then exit 2; fi
  make CROSS_COMPILE=${KERNEL_GCC} BL31=${BL31_BIN} -j$(nproc)
  if [ $? != 0 ];then exit 2; fi
  cd ${workspace}
}

apply_bootloader(){
  BOARD=$1
  source ../boards/${BOARD}.conf

  UB_BIN=${workspace}/${BL_CONFIG}/u-boot-sunxi-with-spl.bin
  if [ ! -f ${UB_BIN} ];then
    echo "ERROR: u-boot build output not found: ${UB_BIN}"
    exit 2
  fi

  if [ -d ${workspace}/bootloader-${BOARD} ];then rm -rf ${workspace}/bootloader-${BOARD}; fi

  cp ${UB_BIN} ${workspace}/bootloader-u-boot.bin

  mkdir -p ${workspace}/bootloader-${BOARD}/extlinux
  cp ${workspace}/../target/boot/uInitrd ${workspace}/bootloader-${BOARD}
  cp ${workspace}/../target/boot/extlinux.conf ${workspace}/bootloader-${BOARD}/extlinux
  sed -i "s|DTB_NAME|${DEVICE_DTS}|g" ${workspace}/bootloader-${BOARD}/extlinux/extlinux.conf
  sed -i "s|BOOTARGS|${BOOTARGS}|g" ${workspace}/bootloader-${BOARD}/extlinux/extlinux.conf

  for f in uInitrd extlinux/extlinux.conf;do
    if [ ! -f ${workspace}/bootloader-${BOARD}/${f} ];then
      echo "ERROR: bootloader artifact missing: ${f}"
      exit 2
    fi
  done
  if [ ! -f ${workspace}/bootloader-u-boot.bin ];then
    echo "ERROR: bootloader artifact missing: bootloader-u-boot.bin"
    exit 2
  fi

  echo "${BOARD}" > ${workspace}/bootloader-${BOARD}/.done
}

write_bootloader(){
    echo "write bootloader"
    if [ ! -f ${workspace}/bootloader-u-boot.bin ];then
        echo "ERROR: bootloader-u-boot.bin not found, build bootloader first!"
        exit 2
    fi
    dd if=${workspace}/bootloader-u-boot.bin of=$1 bs=1024 seek=8 conv=fsync status=noxfer
}
