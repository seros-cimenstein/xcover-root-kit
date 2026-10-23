#!/system/bin/sh
# xcover-guard: hold the XCover key (left side) to switch guard mode on or off.
# Guard mode: backlight off and touches ignored, while the phone stays awake and unlocked, so
# agents keep driving it over adb (input, uiautomator, screencap) but nothing you touch reaches
# it. Runs as root (Magisk); installed by install.sh on the laptop.
#
#   guard.sh on|off|toggle|status   switch it by hand (e.g. adb shell su -c '... on')
#   guard.sh listen                  key listener + watchdog (started at boot from service.d)

DIR=/data/adb/xcover-guard
STATE=$DIR/state          # exists while guard mode is on; holds what to restore
PIDS=$DIR/listen.pid
GRAB=$DIR/touchgrab       # holds an exclusive grab on the touchscreen (see touchgrab.c)
# The panel driver relights the backlight whenever Android writes a brightness, even with
# bl_power off; so guard mode also sets Android's brightness to its minimum (1 of 306: a write
# lights almost nothing) and the watchdog puts the raw brightness back to 0 within 0.5 s.
BLPOWER=/sys/class/backlight/panel/bl_power
BL=/sys/class/backlight/panel/brightness
KEYCODE=00fc              # XCover key as `getevent -l` names it (code 252)
HOLD_S=0.7                # hold at least this long; shorter presses (pocket bumps) do nothing
NO_TIMEOUT=2147483647

# /dev/input/eventN of the input device named $1 (numbers can change between boots).
input_dev() {
	awk -v name="$1" '
		/^N: / { hit = ($0 == "N: Name=\"" name "\"") }
		hit && /^H: / { for (i = 1; i <= NF; i++) if ($i ~ /^event/) { print "/dev/input/" $i; exit } }
	' /proc/bus/input/devices
}

# Grab the touchscreen (only one grab; a dead one is replaced).
grab_touch() {
	pid=$(sed -n 's/^grab=//p' "$STATE" 2>/dev/null)
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
	"$GRAB" "$(input_dev sec_touchscreen)" &
	sed -i '/^grab=/d' "$STATE"
	echo "grab=$!" >>"$STATE"
}

buzz() {
	cmd vibrator_manager synced -f oneshot "$1" >/dev/null 2>&1
}

awake() {
	dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake'
}

guard_on() {
	[ -f "$STATE" ] && return 0
	if ! awake; then
		echo "screen is off: wake and unlock the phone first" >&2
		return 1
	fi
	{
		echo "timeout=$(settings get system screen_off_timeout)"
		echo "brightness=$(settings get system screen_brightness)"
	} >"$STATE"
	# Never time out, so the phone stays awake and unlocked for the agent.
	settings put system screen_off_timeout $NO_TIMEOUT
	grab_touch
	settings put system screen_brightness 1
	echo 0 >"$BL"
	echo 4 >"$BLPOWER"
	buzz 90
	log -t xcover-guard "on"
}

# $1 = "screen-off": the screen went off by itself (power key); no buzz then.
guard_off() {
	[ -f "$STATE" ] || return 0
	pid=$(sed -n 's/^grab=//p' "$STATE")
	[ -n "$pid" ] && kill "$pid" 2>/dev/null
	timeout=$(sed -n 's/^timeout=//p' "$STATE")
	brightness=$(sed -n 's/^brightness=//p' "$STATE")
	rm -f "$STATE"
	echo 0 >"$BLPOWER"
	case $brightness in '' | null | 0 | 1) brightness=100 ;; esac
	# Android writes the panel brightness itself when its setting changes.
	settings put system screen_brightness "$brightness"
	case $timeout in '' | null) timeout=60000 ;; esac
	settings put system screen_off_timeout "$timeout"
	if [ "$1" != screen-off ]; then
		buzz 60
		sleep 0.15
		buzz 60
	fi
	log -t xcover-guard "off${1:+ ($1)}"
}

status() {
	if [ -f "$STATE" ]; then echo "guard: on"; else echo "guard: off"; fi
	if [ -f "$PIDS" ] && kill -0 "$(head -n1 "$PIDS")" 2>/dev/null; then
		echo "listener: running"
	else
		echo "listener: not running"
	fi
	pid=$(sed -n 's/^grab=//p' "$STATE" 2>/dev/null)
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then g=grabbed; else g=free; fi
	echo "touch=$g backlight=$([ "$(cat $BLPOWER)" = 0 ] && echo on || echo off)"
}

# While on: keep the backlight off and the touchscreen grabbed (every 0.5 s), and turn guard
# mode off if the screen goes off (checked every 2 s), so the phone is usable when woken.
watchdog() {
	n=0
	while :; do
		if [ -f "$STATE" ]; then
			n=$((n + 1))
			if [ $((n % 4)) = 0 ] && ! awake; then
				guard_off screen-off
			else
				[ "$(cat $BL)" = 0 ] || echo 0 >"$BL"
				[ "$(cat $BLPOWER)" = 4 ] || echo 4 >"$BLPOWER"
				[ $((n % 4)) = 0 ] && grab_touch
			fi
			sleep 0.5
		else
			n=0
			sleep 2
		fi
	done
}

listen() {
	mkdir -p "$DIR"
	keydev=$(input_dev gpio_keys)
	# One listener: stop a previous one (re-install or manual restart).
	if [ -f "$PIDS" ]; then
		for p in $(cat "$PIDS"); do kill "$p" 2>/dev/null; done
		pkill -f "getevent -lt $keydev" 2>/dev/null
	fi
	echo $$ >"$PIDS"
	# A boot or restart never leaves guard mode half on.
	[ -f "$STATE" ] && guard_off
	watchdog &
	echo $! >>"$PIDS"
	while :; do
		getevent -lt "$keydev" 2>/dev/null |
			awk -v code="$KEYCODE" -v hold="$HOLD_S" '
				$0 ~ code {
					gsub(/[\[\]]/, "")
					if ($NF == "DOWN") d = $1
					else if ($NF == "UP") {
						if (d != "" && $1 - d >= hold) { print "toggle"; fflush() }
						d = ""
					}
				}' |
			while read -r _; do
				if [ -f "$STATE" ]; then guard_off; else guard_on; fi
			done
		sleep 2
	done
}

case $1 in
on) guard_on ;;
off) guard_off ;;
toggle) if [ -f "$STATE" ]; then guard_off; else guard_on; fi ;;
status) status ;;
listen) listen ;;
*)
	echo "usage: $0 on|off|toggle|status|listen" >&2
	exit 2
	;;
esac
