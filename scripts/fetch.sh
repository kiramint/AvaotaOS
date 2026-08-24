#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0
#
# This file is a part of the Avaota Build Framework
# https://github.com/AvaotaSBC/AvaotaOS/

__usage="
Usage: fetch [OPTIONS]
Fetch build sources.

Options: 
  -b, --board BOARD                   The board name.
  -g, --githubmirror GITHUB_MIRROR    Use GitHub mirror.
  -h, --help                          Show command help.
"

help()
{
    echo "$__usage"
    exit $1
}

default_param() {
    BOARD=avaota-a1
    GITHUB_MIRROR=none
    KERNEL_TARGET=bsp
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
        elif [ "x$1" == "x-i" -o "x$1" == "x--githubmirror" ]; then
            GITHUB_MIRROR=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-g" -o "x$1" == "x--kerneltarget" ]; then
            KERNEL_TARGET=`echo $2`
            shift
            shift
        else
            echo `date` - ERROR, UNKNOWN params "$@"
            return 2
        fi
    done
}

check_linux_tree()
{
    if [ -d ${workspace}/linux ] && [ ! -f ${workspace}/linux/scripts/Kbuild.include ];then
        echo "linux source tree incomplete, remove and re-clone..."
        rm -rf ${workspace}/linux
    fi
}

do_clone_linux()
{
    cd ${workspace}
    for attempt in 1 2 3;do
        echo "clone linux from ${LINUX_REPO} (attempt ${attempt}/3)..."
        git clone --depth=1 ${LINUX_REPO} -b ${LINUX_BRANCH} linux
        if [ $? == 0 ] && [ -f ${workspace}/linux/scripts/Kbuild.include ];then
            return 0
        fi
        rm -rf ${workspace}/linux
        sleep 5
    done
    if [ "x${LINUX_GITEE_REPO}" != "x" ] && [ "${LINUX_GITEE_REPO}" != "${LINUX_REPO}" ];then
        echo "clone linux from fallback ${LINUX_GITEE_REPO}..."
        rm -rf ${workspace}/linux
        git clone --depth=1 ${LINUX_GITEE_REPO} -b ${LINUX_BRANCH} linux
    fi
    return 1
}

clone_linux()
{
    check_linux_tree
    if [ -d ${workspace}/linux ];then
        pushd ${workspace}/linux
        git remote -v update
        remote_url=$(git config --get remote.origin.url)
        current_branch=$(git symbolic-ref --short HEAD)
        if [[ "${remote_url}" == "${LINUX_REPO}" && "${current_branch}" == "${LINUX_BRANCH}" ]];then
            git pull
            popd
        else
            popd
            do_clone_linux
        fi
    else
        do_clone_linux
    fi
}

check_linux_complete()
{
    if [ ! -f ${workspace}/linux/scripts/Kbuild.include ];then
        echo "Fetch linux source incomplete, please check network and retry."
        exit 2
    fi
}

clone_atf()
{
    if [ -d ${workspace}/atf ];then
    	pushd ${workspace}/atf
        git pull
        popd
    else
        git clone --depth=1 ${ATF_REPO} -b ${ATF_BRANCH} atf
    fi
}

clone_rkbin()
{
    if [ -d ${workspace}/${BL_CONFIG} ];then
    	pushd ${workspace}/${BL_CONFIG}
        git pull
        popd
    else
        git clone ${RKBIN_REPO} rkbin
        pushd rkbin
        git checkout ${RKBIN_BRANCH_HASH}
        popd
    fi
}

clone_u-boot()
{
    if [ -d ${workspace}/${BL_CONFIG} ];then
    	pushd ${workspace}/${BL_CONFIG}
        git checkout -- . 2>/dev/null
        git pull
        popd
    else
        git clone --depth=1 ${UBOOT_REPO} -b ${UBOOT_BRANCH} ${BL_CONFIG}
    fi
}

workspace=$(pwd)
cd ${workspace}

default_param
parseargs "$@" || help $?

source ../boards/${BOARD}.conf
source ../scripts/lib/bootloader/bootloader-${BL_CONFIG}.sh

if [[ ${LINUX_REPO:0:18} == "https://github.com" && ${GITHUB_MIRROR} != "no" ]];then
    echo "Use GitHub Proxy: ${GITHUB_MIRROR}/${LINUX_REPO}"
    LINUX_REPO=${GITHUB_MIRROR}/${LINUX_REPO}
fi

if [ ${BL_CONFIG} == "sunxi-uboot" ];then
    clone_atf
    clone_u-boot
elif [ ${BL_CONFIG} == "rockchip-uboot" ];then
    clone_rkbin
    clone_u-boot
fi

clone_linux
check_linux_complete

if [[ ! -d ${workspace}/${BL_CONFIG} && ! -d ${workspace}/linux ]];then
    echo "Fetch sources error, please check your network connection."
    exit 2
fi
