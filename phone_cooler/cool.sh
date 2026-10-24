#!/system/bin/sh
# phone-cooler: caps the CPU and GPU clocks of the rooted Galaxy XCover Pro (Exynos 9611) so it
# runs colder. Runs as root (Magisk); installed to /data/adb/phone-cooler by install.sh.
#
#   cool.sh set off|mild|cool|cold   apply a profile and remember it (survives reboot)
#   cool.sh get                      print the remembered profile
#   cool.sh next                     cycle off -> mild -> cool -> cold -> off, print the new one
#   cool.sh status                   profile, clocks and temperatures
#   cool.sh daemon                   apply the remembered profile and keep it applied
#                                    (started at boot from /data/adb/service.d/phone-cooler.sh)
#
# Who else writes these knobs (measured, see README):
# - CPU scaling_max_freq: only the kernel's thermal cooling, which lowers it for a moment and
#   then returns to our value. Samsung's SSRM/HyperHAL boosts and throttles through
#   /sys/power/cpufreq_{min,max}_limit instead; the min boosts do not lift our max.
# - GPU gpu_max_clock: HyperHAL (for SSRM) rewrites it every few seconds, often back to the
#   full 1053 MHz. While a profile is on, the file is chowned to root so those writes fail; "off"
#   gives it back to system. The kernel's own GPU thermal limit (TMU lock) still works.

DIR=/data/adb/phone-cooler
STATE=$DIR/profile
PIDFILE=$DIR/daemon.pid
CPU=/sys/devices/system/cpu/cpufreq
LITTLE=$CPU/policy0
BIG=$CPU/policy4
GPU=/sys/kernel/gpu
# Safety-net poll: nothing was seen rewriting the caps once the GPU file is locked, so a slow
# round (three builtin reads, no forks) is enough to catch surprises.
POLL_S=30
TICK=$DIR/tick

# Sets CAP_L CAP_B CAP_G (little, big, GPU max in kHz) for profile $1; fails for unknown names.
caps() {
	case $1 in
	off) CAP_L=1742000 CAP_B=2314000 CAP_G=1053000 ;;
	mild) CAP_L=1742000 CAP_B=1898000 CAP_G=764000 ;;
	cool) CAP_L=1456000 CAP_B=1508000 CAP_G=572000 ;;
	cold) CAP_L=1222000 CAP_B=1248000 CAP_G=455000 ;;
	*) return 1 ;;
	esac
}

# Sets P to the remembered profile (off if none).
load_profile() {
	P=
	[ -f "$STATE" ] && read -r P <"$STATE"
	caps "$P" || { P=off; caps off; }
}

# Writes max $2 to the max file $1, but never below the min in file $3 (a max below the current
# min is invalid; boosts raise the min for a moment).
cap() {
	read -r min <"$3"
	want=$2
	[ "$min" -gt "$want" ] 2>/dev/null && want=$min
	echo "$want" >"$1"
}

# Applies the caps of profile $1.
apply() {
	caps "$1"
	cap "$LITTLE/scaling_max_freq" "$CAP_L" "$LITTLE/scaling_min_freq"
	cap "$BIG/scaling_max_freq" "$CAP_B" "$BIG/scaling_min_freq"
	cap "$GPU/gpu_max_clock" "$CAP_G" "$GPU/gpu_min_clock"
	if [ "$1" = off ]; then
		chown system:system "$GPU/gpu_max_clock"
	else
		chown root:root "$GPU/gpu_max_clock"
	fi
}

set_profile() {
	caps "$1" || { echo "unknown profile: $1 (off|mild|cool|cold)" >&2; return 2; }
	mkdir -p "$DIR"
	echo "$1" >"$STATE"
	apply "$1"
}

# millidegrees -> "54.0"
celsius() {
	echo "$(($1 / 1000)).$(($1 % 1000 / 100))"
}

daemon_pid() {
	[ -f "$PIDFILE" ] && read -r pid <"$PIDFILE" && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

status() {
	load_profile
	echo "profile: $P (caps: little $((CAP_L / 1000)) MHz, big $((CAP_B / 1000)) MHz, GPU $((CAP_G / 1000)) MHz)"
	for c in LITTLE:$LITTLE BIG:$BIG; do
		read -r cur <"${c#*:}/scaling_cur_freq"
		read -r max <"${c#*:}/scaling_max_freq"
		echo "${c%%:*}: $((cur / 1000)) MHz now, max $((max / 1000)) MHz"
	done
	read -r cur <"$GPU/gpu_clock"
	read -r max <"$GPU/gpu_max_clock"
	echo "GPU: $((cur / 1000)) MHz now, max $((max / 1000)) MHz"
	t=
	for z in /sys/class/thermal/thermal_zone*; do
		read -r type <"$z/type"
		read -r temp <"$z/temp"
		t="$t $type $(celsius "$temp")C"
	done
	echo "temps:$t"
	if pid=$(daemon_pid); then
		echo "daemon: running (pid $pid)"
	else
		echo "daemon: not running"
	fi
}

daemon() {
	pid=$(daemon_pid)
	if [ -n "$pid" ] && [ "$pid" != $$ ]; then
		echo "daemon already running (pid $pid)" >&2
		return 1
	fi
	mkdir -p "$DIR"
	[ -p "$TICK" ] || mkfifo "$TICK"
	echo $$ >"$PIDFILE"
	applied=
	while :; do
		load_profile
		read -r l <"$LITTLE/scaling_max_freq"
		read -r b <"$BIG/scaling_max_freq"
		read -r g <"$GPU/gpu_max_clock"
		if [ "$P" != "$applied" ]; then
			# Boot, or a profile switched by `set` (already applied; re-applying is harmless).
			apply "$P"
			applied=$P
		elif [ "$l" -gt "$CAP_L" ] || [ "$b" -gt "$CAP_B" ] || [ "$g" -gt "$CAP_G" ]; then
			# Only values above the cap count: thermal limits below it are left alone.
			log -t phone-cooler "caps raised to $l $b $g, re-applying $P"
			apply "$P"
		fi
		# A timed read on a fifo nobody writes to: sleeps without forking a `sleep`.
		read -t $POLL_S _ <>"$TICK"
	done
}

case $1 in
set) set_profile "$2" ;;
get)
	load_profile
	echo "$P"
	;;
next)
	load_profile
	case $P in
	off) n=mild ;;
	mild) n=cool ;;
	cool) n=cold ;;
	*) n=off ;;
	esac
	set_profile "$n" && echo "$n"
	;;
status) status ;;
daemon) daemon ;;
*)
	echo "usage: cool.sh set off|mild|cool|cold | get | next | status | daemon" >&2
	exit 2
	;;
esac
