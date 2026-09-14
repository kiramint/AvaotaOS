#!/usr/bin/env bash
#
# Repair HDMI DDC EDIDs whose first 8-16 bytes are 0x00.
# Seen on the HDP-V104 / demoset-1 capture card: drm_get_edid rejects the
# block, the BSP HDMI driver falls back to DVI, and the card captures nothing.
# Kernel patch 0010 does the same in-driver; this script is a reboot
# workaround for kernels that do not have 0010 yet.
#
# Usage: sudo ./fix-hdmi-edid.sh
#
set -euo pipefail

ATTR=/sys/devices/virtual/hdmi/hdmi/attr
CACHE=/var/lib/avaota/hdmi-edid.bin
I2C_BUS=31

[[ ${EUID} -eq 0 ]] || { echo "run as root"; exit 1; }

wait_for() {
	local path=$1 n=0
	while [[ ! -e ${path} && ${n} -lt 50 ]]; do
		sleep 0.2
		n=$((n + 1))
	done
	[[ -e ${path} ]]
}

wait_for ${ATTR}/edid_data || { echo "hdmi sysfs not ready"; exit 0; }
wait_for /dev/i2c-${I2C_BUS} || { echo "hdmi i2c not ready"; exit 0; }

python3 - "${I2C_BUS}" "${CACHE}" "${ATTR}" << 'PY'
import sys, subprocess, pathlib

bus, cache_path, attr = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
hdr = bytes([0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00])

def xfer(off, n):
    out = subprocess.check_output(
        ["i2ctransfer", "-y", bus, f"w1@0x50", hex(off), f"r{n}"],
        text=True,
    )
    return bytearray(int(x, 16) for x in out.split())

def cksum(blk):
    blk[127] = 0
    blk[127] = (256 - (sum(blk) & 0xff)) & 0xff

def repairable(b0, b1):
    if b0[0:8] == hdr:
        return False
    if b0[0x12] == 0x01 and b0[0x13] <= 0x04:
        return True
    if b0[126] >= 1 and b1 and b1[0] == 0x02:
        return True
    return False

edid = None
try:
    b0 = xfer(0x00, 128)
    b1 = xfer(0x80, 128) if b0[126] >= 1 else bytearray()
    if repairable(b0, b1):
        b0[0:8] = hdr
        cksum(b0)
        if b1:
            cksum(b1)
            edid = bytes(b0 + b1)
        else:
            edid = bytes(b0)
except Exception as e:
    print("ddc read failed:", e)

if edid is None and cache_path.exists():
    edid = cache_path.read_bytes()
    print("using cached edid", cache_path)

if edid is None:
    sys.exit(0)

cache_path.parent.mkdir(parents=True, exist_ok=True)
cache_path.write_bytes(edid)
(attr / "edid_data").write_bytes(edid)
(attr / "edid_debug").write_text("1\n")
print("injected repaired edid,", len(edid), "bytes")
PY

# Re-read connector so GDM/mutter pick HDMI (not DVI) modes.
if [[ -w ${ATTR}/hpd_mask ]]; then
	echo 0x10 > ${ATTR}/hpd_mask || true
	sleep 0.5
	echo 0x11 > ${ATTR}/hpd_mask || true
	sleep 0.5
	echo 0x00 > ${ATTR}/hpd_mask || true
fi
