#!/bin/bash
# Expand the root partition to fill the boot disk, then grow the ext4 fs.
# First-boot oneshot: disable itself after a successful pass.

LOG=/var/log/resize-root.log
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== $(date -Is) start ==="

ROOT_PART="$(findmnt -n -o SOURCE /)"
ROOT_DEV="/dev/$(lsblk -no pkname "$ROOT_PART")"
PART_NUM="${ROOT_PART##*[!0-9]}"

echo "root=$ROOT_PART disk=$ROOT_DEV part=$PART_NUM"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$ROOT_DEV" || true

grow_partition() {
	if command -v growpart >/dev/null 2>&1; then
		# 1 = already at max (NOCHANGE), not a failure
		growpart "$ROOT_DEV" "$PART_NUM" && return 0
		echo "growpart: no change or skipped"
		return 0
	fi
	echo ",+" | sfdisk --no-reread -N "$PART_NUM" "$ROOT_DEV" || {
		echo "sfdisk grow skipped (already at max?)"
		return 0
	}
}

grow_partition
partx -u "$ROOT_DEV" 2>/dev/null || partprobe "$ROOT_DEV" 2>/dev/null || true
sleep 1

if ! resize2fs "$ROOT_PART"; then
	echo "resize2fs failed"
	exit 1
fi

echo "resize done"
df -hT /
systemctl disable init-resize.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/multi-user.target.wants/init-resize.service
echo "=== $(date -Is) finish ==="
