#!/bin/bash
# AIC8800 BT = UART HCI on uart1 (ttyAS1). Chip sleeps until bt_wake (PG11)
# is high AND rfkill has released bt_rst (PG12).
# Current kernel: aic8800_btlpm probe fails (wake IRQ EBUSY) so
# /proc/bluetooth/sleep/btwrite does not exist — drive PG11 via gpio sysfs.

LOG=/var/log/avaota-bluetooth.log
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== $(date -Is) start ==="

dead_hci0() {
	hciconfig hci0 2>/dev/null | grep -q '00:00:00:00:00:00'
}

kill_stale() {
	killall hciattach btattach 2>/dev/null || true
	sleep 1
}

if hciconfig hci0 >/dev/null 2>&1 && ! dead_hci0; then
	echo "hci0 already present"
	hciconfig -a || true
	exit 0
fi

kill_stale

modprobe aic8800_btlpm 2>/dev/null || true

# Unblock both sunxi-bt (releases PG12 reset) and the generic bluetooth rfkill.
rfkill unblock bluetooth 2>/dev/null || true
rfkill unblock all 2>/dev/null || true
for s in /sys/class/rfkill/rfkill*/type; do
	[ -f "$s" ] || continue
	[ "$(cat "$s")" = bluetooth ] || continue
	echo 1 > "$(dirname "$s")/state" 2>/dev/null || true
done
sleep 1

wake_pg11_sysfs() {
	local n chip
	if [ -r /sys/kernel/debug/gpio ]; then
		n=$(sed -n 's/^ gpio-\([0-9][0-9]*\).*PG11.*/\1/p' /sys/kernel/debug/gpio | head -1)
	fi
	if [ -z "$n" ]; then
		# sunxi numbers from PA: PG11 = 6*32+11 = 203
		for chip in /sys/class/gpio/gpiochip*; do
			[ -f "$chip/base" ] || continue
			base=$(cat "$chip/base")
			ngpio=$(cat "$chip/ngpio")
			if [ 203 -ge "$base" ] && [ 203 -lt $((base + ngpio)) ]; then
				n=203
				break
			fi
		done
	fi
	[ -n "$n" ] || return 1
	[ -d /sys/class/gpio/gpio$n ] || echo "$n" > /sys/class/gpio/export 2>/dev/null || true
	[ -d /sys/class/gpio/gpio$n ] || return 1
	echo out > /sys/class/gpio/gpio$n/direction
	echo 1 > /sys/class/gpio/gpio$n/value
	echo "woke PG11 via sysfs gpio$n"
}

wake_bt() {
	if [ -w /proc/bluetooth/sleep/btwrite ]; then
		echo 1 > /proc/bluetooth/sleep/btwrite
		echo "woke via /proc/bluetooth/sleep/btwrite"
		return 0
	fi
	# libgpiod v2 (Ubuntu 24.04)
	if gpioset -c 0 PG11=1 2>/dev/null; then
		echo "woke via gpioset -c 0 PG11"
		return 0
	fi
	if command -v gpiofind >/dev/null 2>&1; then
		line=$(gpiofind PG11 2>/dev/null || true)
		if [ -n "$line" ]; then
			# libgpiod v1: "gpiochipN offset"
			# shellcheck disable=SC2086
			gpioset ${line}=1 2>/dev/null && echo "woke via gpiofind $line" && return 0
		fi
	fi
	wake_pg11_sysfs && return 0
	echo "WARN: could not assert bt_wake PG11"
	return 1
}

wake_bt || true
sleep 1

TTY=""
for c in /dev/ttyAS1 /dev/ttyS1; do
	if [ -c "$c" ]; then
		TTY=$c
		break
	fi
done
if [ -z "$TTY" ]; then
	echo "no BT UART node (ttyAS1/ttyS1)"
	exit 0
fi
echo "using $TTY  rfkill=$(rfkill list bluetooth 2>/dev/null | tr '\n' ' ')"

try_attach() {
	if command -v hciattach >/dev/null 2>&1; then
		hciattach -s 1500000 "$TTY" any 1500000 flow nosleep
	elif command -v btattach >/dev/null 2>&1; then
		btattach -B "$TTY" -P h4 -S 1500000 >/dev/null 2>&1 &
		sleep 2
		return 0
	else
		echo "hciattach/btattach not installed (need bluez)"
		return 1
	fi
}

n=0
while [ $n -lt 4 ]; do
	if try_attach; then
		sleep 2
		if hciconfig hci0 >/dev/null 2>&1 && ! dead_hci0; then
			hciconfig hci0 up 2>/dev/null || true
			hciconfig -a || true
			echo "hci0 up"
			exit 0
		fi
	fi
	echo "attach attempt $n failed (still no chip response)"
	kill_stale
	wake_bt || true
	n=$((n + 1))
	sleep 2
done

echo "failed to attach Bluetooth HCI"
hciconfig -a 2>/dev/null || true
rfkill list || true
exit 0
