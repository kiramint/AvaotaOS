# AvaotaOS

Build scripts for **Avaota A1 (Allwinner T527)** images: Ubuntu 22.04/24.04, CLI or GNOME, BSP kernel 5.15 + mainline U-Boot.

Default login (unless you pass `-u` / `-p` / `-s`):

```
user: avaota / avaota
root: avaota
```

Serial: `ttyAS0`, 115200.

## Supported

| | |
|---|---|
| Board | `avaota-a1` only |
| Distro | `jammy` (22.04), `noble` (24.04) |
| Desktop | `cli`, `gnome` |
| Kernel | BSP `linux-5.15` (`-g bsp`) |
| Bootloader | mainline U-Boot v2026.07 + jernejsk ATF `a523-v4` |

Other boards, Debian suites, and xfce/kde/lxqt in the old parameter list are **not** wired up.

Status and hardware bring-up notes: [`status.md`](status.md), [`AGENTS.md`](AGENTS.md).

## Prebuilt images / GitHub Actions

Pushing a tag matching `v*` (for example `v0.3.1`) starts
[`.github/workflows/release-on-tag.yaml`](.github/workflows/release-on-tag.yaml):

1. Build `noble` + `gnome` (and `cli`) for `avaota-a1`
2. Create a GitHub Release for that tag
3. Upload `AvaotaOS-<VERSION>-noble-<type>-arm64-avaota-a1.img.xz`

```bash
git tag v0.3.1
git push origin v0.3.1
```

You can also run the workflow by hand from the Actions tab (`workflow_dispatch`).
A full GNOME image takes a long time and a lot of disk on the runner.

## Known issues (do not expect a full Ubuntu desktop from the image builder)

### 1. `ubuntu-desktop` looks empty

`ubuntu-desktop` is a metapackage. **Depends** are only the shell (GDM, gnome-shell, nautilus). Firefox, LibreOffice, Image Viewer, Evince, file-roller, gnome-software, Yaru, cups, etc. are **Recommends**.

`mmdebstrap --include` does **not** install Recommends. Installing `ubuntu-desktop` again after it is already present is a no-op (`already the newest version`), so those apps stay missing.

On a running board (after growing the rootfs):

```bash
sudo apt install --install-recommends ubuntu-desktop
```

Switching the builder from mmdebstrap to debootstrap does **not** fix this by itself; debootstrap also skips Recommends. The fix is to `apt-get install --install-recommends ubuntu-desktop` **before** the metapackage is already unpacked, or to expand Recommends by name.

Current `build_dir/rootfs-noble-gnome.tar.gz` (973 MB, 2026-09-18) is still this incomplete desktop.

### 2. snap / Firefox cannot be fully installed in the qemu-user chroot

Noble Firefox is a **snap**, not a normal deb. The `firefox` deb is a stub that talks to `snapd`.

Rootfs is built on an x86 host with **qemu-user** running aarch64 `dpkg` maintainer scripts. `snapd` postinst does `setcap` on `snap-confine` (`setxattr(security.capability)`). qemu-user often returns **`Operation not supported`**. Even if that passed, `snap install` needs a running systemd, loop/squashfs, and AppArmor — none of that works in this chroot.

That is **independent** of the board kernel. Canonical preinstalled images do **not** `snap install` in the chroot; they `snap download --arch=arm64` on the host and drop files into `/var/lib/snapd/seed/` so first boot seeds Firefox.

This tree does **not** seed snaps. After a kernel with `CONFIG_EXT4_FS_SECURITY` and `CONFIG_SQUASHFS_XATTR` (already in the board defconfig; **not in the kernel currently on the board**), install on the device:

```bash
sudo apt install snapd firefox
```

### 3. HDMI capture card (HDP-V104) showed a black frame

The capture-card EDID has a zero header, so the BSP HDMI driver fell back to **DVI** (no AVI infoframes) and the card recorded black. Kernel patch `0010` repairs the header and keeps HDMI. On a card that is already running, `scripts/fix-hdmi-edid.sh` is the workaround until that kernel is installed.

## How to build

Needs a Linux amd64 host, `sudo`, and qemu-user binfmt for aarch64.

```bash
git clone https://github.com/kiramint/AvaotaOS
cd AvaotaOS
sudo ./build_all.sh \
    -b avaota-a1 \
    -m https://mirrors.ustc.edu.cn/ubuntu-ports \
    -v noble \
    -t gnome \
    -u avaota \
    -p avaota \
    -s avaota \
    -k no \
    -g bsp \
    -i no \
    -o no \
    -e no
```

Output: `build_dir/AvaotaOS-<VERSION>-noble-gnome-arm64-avaota-a1.img.xz`.

Write to an SD card (replace `sdX`):

```bash
xz -dc build_dir/AvaotaOS-*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

First boot grows the root partition (`init-resize`). If the card was imaged from an older build, you may still need to `sfdisk` + `resize2fs` by hand — see `status.md`.

## Build parameters

| Flag | Meaning | Values |
|---|---|---|
| `-b` | Board | `avaota-a1` |
| `-v` | Ubuntu series | `jammy`, `noble` |
| `-t` | Image type | `cli`, `gnome` |
| `-m` | apt mirror | e.g. `https://mirrors.ustc.edu.cn/ubuntu-ports` |
| `-u` `-p` `-s` | user / user password / root password | default `avaota` |
| `-k` | kernel menuconfig | `yes` / `no` |
| `-g` | kernel tree | `bsp` |
| `-l` | use already-fetched sources | `yes` / `no` (do not use `yes` on the first run) |
| `-i` | GitHub mirror | `no` or a proxy URL |
| `-o` | kernel packages only | `yes` / `no` |
| `-e` | ccache | `yes` / `no` |

Caches (delete to rebuild that stage):

- kernel: `build_dir/avaota-a1-kernel-pkgs/.done`
- rootfs: `build_dir/rootfs-<version>-<type>.tar.gz`
- bootloader: `build_dir/bootloader-avaota-a1/.done`
