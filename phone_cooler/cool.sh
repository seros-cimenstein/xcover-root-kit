#!/system/bin/sh
# phone-cooler: caps the CPU and GPU clocks of the rooted Galaxy XCover Pro (Exynos 9611) so it
# runs colder, or applies a custom set of clocks, governors and cores. Runs as root (Magisk);
# installed to /data/adb/phone-cooler by install.sh.
#
#   cool.sh set off|mild|cool|cold|custom  apply a profile and remember it (survives reboot)
#   cool.sh get                      print the remembered profile
#   cool.sh next                     cycle off -> mild -> cool -> cold [-> custom] -> off, print it
#   cool.sh status                   profile, clocks, online cores and temperatures
#   cool.sh knobs                    every knob: key=live value, key.options=allowed values,
#                                    key.stock=stock value, key.want=value of the profile in use
#   cool.sh apply key=value ...      change custom settings (unnamed knobs keep the value of the
#                                    profile in use), apply them and switch to the custom profile
#   cool.sh daemon                   apply the remembered profile and keep it applied
#                                    (started at boot from /data/adb/service.d/phone-cooler.sh)
#
# Who else writes these knobs (measured, see README):
# - CPU scaling_max_freq: only the kernel's thermal cooling, which lowers it for a moment and
#   then returns to our value. Samsung's SSRM/HyperHAL boosts and throttles through
#   /sys/power/cpufreq_{min,max}_limit instead; the min boosts do not lift our max.
# - GPU gpu_max_clock: HyperHAL (for SSRM) rewrites it every few seconds, often back to the
#   full 1053 MHz. While a profile is on, the file is chowned to root so those writes fail; "off"
#   gives it back to system. A custom GPU min above the lowest clock is held the same way. The
#   kernel's own GPU thermal limit (TMU lock) still works.
# - Nothing else was seen rewriting governors, online cores, the GPU governor, CL boost or the
#   Interactive tunables; the daemon checks them anyway.
# - Not offered: the schedutil up/down_rate_limit_us. Samsung's freqvar-tune rewrites them from
#   its per-frequency tables (policy*/schedutil/freqvar_*) on every frequency change.

DIR=/data/adb/phone-cooler
STATE=$DIR/profile
CUSTOM=$DIR/custom
PIDFILE=$DIR/daemon.pid
SYS=/sys/devices/system/cpu
LITTLE=$SYS/cpufreq/policy0
BIG=$SYS/cpufreq/policy4
GPU=/sys/kernel/gpu
MALI=/sys/devices/platform/11500000.mali
# Safety-net poll: nothing was seen rewriting the knobs once the GPU files are locked, so a slow
# round (builtin reads only, no forks) is enough to catch surprises.
POLL_S=30
TICK=$DIR/tick

# Every knob. cpu0 is listed so `knobs` shows it, but its only allowed value is 1: taking cpu0
# offline hung and rebooted the phone.
KEYS="little_min little_max little_governor big_min big_max big_governor \
cpu0 cpu1 cpu2 cpu3 cpu4 cpu5 cpu6 cpu7 \
gpu_min gpu_max gpu_governor gpu_cl_boost gpu_highspeed_clock gpu_highspeed_load"
# GPU Interactive governor: load (%) above which it jumps straight to highspeed_clock.
LOADS="50 55 60 65 70 75 80 85 90 95 100"

# Sets CAP_L CAP_B CAP_G (little, big, GPU max in kHz) for preset $1; fails for other names.
caps() {
	case $1 in
	off) CAP_L=1742000 CAP_B=2314000 CAP_G=1053000 ;;
	mild) CAP_L=1742000 CAP_B=1898000 CAP_G=764000 ;;
	cool) CAP_L=1456000 CAP_B=1508000 CAP_G=572000 ;;
	cold) CAP_L=1222000 CAP_B=1248000 CAP_G=455000 ;;
	*) return 1 ;;
	esac
}

# Sets P to the remembered profile (off if none, or custom without saved settings).
load_profile() {
	P=
	[ -f "$STATE" ] && read -r P <"$STATE"
	[ "$P" = custom ] && [ -f "$CUSTOM" ] && return
	caps "$P" || P=off
}

# "a  b c " -> "a b c" in R; asc reverses as well (the cpufreq tables are descending).
words() {
	R=
	for x in $1; do R="${R:+$R }$x"; done
}
asc() {
	R=
	for x in $1; do R="$x${R:+ $R}"; done
}

# Reads the frequency and governor tables into LF BF GF (ascending kHz) and LG BG GG.
tables() {
	read -r x <"$LITTLE/scaling_available_frequencies"
	asc "$x"
	LF=$R
	read -r x <"$BIG/scaling_available_frequencies"
	asc "$x"
	BF=$R
	read -r x <"$GPU/gpu_freq_table"
	words "$x"
	GF=$R
	read -r x <"$LITTLE/scaling_available_governors"
	words "$x"
	LG=$R
	read -r x <"$BIG/scaling_available_governors"
	words "$x"
	BG=$R
	# Static is the driver's test pattern (steps through the clocks regardless of load).
	read -r x <"$GPU/gpu_available_governor"
	GG=
	for g in $x; do [ "$g" = Static ] || GG="${GG:+$GG }$g"; done
}

# F = sysfs file of knob $1.
file() {
	case $1 in
	gpu_min) F=$GPU/gpu_min_clock ;;
	gpu_max) F=$GPU/gpu_max_clock ;;
	gpu_governor) F=$GPU/gpu_governor ;;
	gpu_cl_boost) F=$GPU/gpu_cl_boost_disable ;;
	gpu_highspeed_*) F=$MALI/${1#gpu_} ;;
	cpu*) F=$SYS/$1/online ;;
	*)
		case $1 in little_*) d=$LITTLE ;; *) d=$BIG ;; esac
		case ${1#*_} in
		min) F=$d/scaling_min_freq ;;
		max) F=$d/scaling_max_freq ;;
		governor) F=$d/scaling_governor ;;
		esac
		;;
	esac
}

# O = allowed values of knob $1 (needs tables).
options() {
	case $1 in
	little_min | little_max) O=$LF ;;
	big_min | big_max) O=$BF ;;
	little_governor) O=$LG ;;
	big_governor) O=$BG ;;
	gpu_governor) O=$GG ;;
	cpu0) O=1 ;;
	cpu*) O="0 1" ;;
	gpu_min | gpu_max | gpu_highspeed_clock) O=$GF ;;
	gpu_cl_boost) O="0 1" ;;
	gpu_highspeed_load) O=$LOADS ;;
	esac
}

# S = stock value of knob $1 (needs tables).
stock() {
	options "$1"
	case $1 in
	*_min) S=${O%% *} ;;
	*_max) S=${O##* } ;;
	gpu_governor) S=Interactive ;;
	*_governor) S=schedutil ;;
	gpu_highspeed_clock) S=764000 ;;
	gpu_highspeed_load) S=75 ;;
	*) S=1 ;; # cores online, CL boost on
	esac
}

# L = live value of knob $1, "-" if its file is absent.
live() {
	file "$1"
	L=-
	[ -e "$F" ] && read -r L <"$F"
	[ "$1" = gpu_cl_boost ] && [ "$L" != - ] && L=$((1 - L))
}

# Writes value $2 to knob $1; a refused write is added to ERR.
put() {
	file "$1"
	v=$2
	[ "$1" = gpu_cl_boost ] && v=$((1 - v))
	{ echo "$v" >"$F"; } 2>/dev/null || ERR="$ERR $1=$2"
}

# Sets v_<key> for every knob to the wanted values of profile $1: stock plus the preset's caps,
# or the saved custom settings (stock for any knob the file lacks).
want() {
	for k in $KEYS; do
		stock "$k"
		eval "v_$k=\$S"
	done
	if [ "$1" = custom ]; then
		[ -f "$CUSTOM" ] || return 0
		while IFS== read -r k v; do
			case " $KEYS " in *" $k "*) eval "v_$k=\$v" ;; esac
		done <"$CUSTOM"
	else
		caps "$1"
		v_little_max=$CAP_L v_big_max=$CAP_B v_gpu_max=$CAP_G
	fi
}

# Writes the min/max pair of cluster $1 (little|big|gpu) in an order the kernel accepts: cpufreq
# refuses a max below the current min and a min above the current max. A CPU max is never
# written below the current min (boosts raise the min for a moment; the daemon catches up).
pair() {
	eval "lo=\$v_$1_min hi=\$v_$1_max"
	live "$1_min"
	if [ "$1" = gpu ]; then
		# The Mali driver takes any order (a min above the max loses to the max lock).
		[ "$L" != "$lo" ] && put gpu_min "$lo"
		live gpu_max
		[ "$L" != "$hi" ] && put gpu_max "$hi"
		return
	fi
	if [ "$hi" -ge "$L" ]; then
		live "$1_max"
		[ "$L" != "$hi" ] && put "$1_max" "$hi"
		live "$1_min"
		[ "$L" != "$lo" ] && put "$1_min" "$lo"
	else
		put "$1_min" "$lo"
		live "$1_min"
		w=$hi
		[ "$L" -gt "$w" ] && w=$L
		put "$1_max" "$w"
	fi
}

# Writes every knob of the wanted values (v_*) that differs from its live value, then sets the
# owners of the GPU files for profile $1. With $2 = keep-offline, cores the kernel took offline
# stay offline (the daemon does not fight Samsung's thermal hotplug).
apply_all() {
	ERR=
	for k in cpu1 cpu2 cpu3 cpu4 cpu5 cpu6 cpu7; do
		eval "w=\$v_$k"
		live "$k"
		[ "$w" = 1 ] && [ "$L" = 0 ] && [ "$2" != keep-offline ] && put "$k" 1
	done
	for k in cpu1 cpu2 cpu3 cpu4 cpu5 cpu6 cpu7; do
		eval "w=\$v_$k"
		live "$k"
		[ "$w" = 0 ] && [ "$L" = 1 ] && put "$k" 0
	done
	for k in little_governor big_governor gpu_governor gpu_cl_boost gpu_highspeed_clock \
		gpu_highspeed_load; do
		eval "w=\$v_$k"
		live "$k"
		[ "$L" != - ] && [ "$L" != "$w" ] && put "$k" "$w"
	done
	pair little
	pair big
	pair gpu
	if [ "$1" = off ]; then
		chown system:system "$GPU/gpu_max_clock"
	else
		chown root:root "$GPU/gpu_max_clock"
	fi
	stock gpu_min
	if [ "$1" = custom ] && [ "$v_gpu_min" != "$S" ]; then
		chown root:root "$GPU/gpu_min_clock"
	else
		chown system:system "$GPU/gpu_min_clock"
	fi
	[ -z "$ERR" ]
}

# Applies profile $1 and remembers it.
set_profile() {
	if [ "$1" = custom ]; then
		[ -f "$CUSTOM" ] || { echo "no custom settings saved yet: use cool.sh apply key=value ..." >&2; return 2; }
	else
		caps "$1" || { echo "unknown profile: $1 (off|mild|cool|cold|custom)" >&2; return 2; }
	fi
	mkdir -p "$DIR"
	echo "$1" >"$STATE"
	tables
	want "$1"
	apply_all "$1" || { echo "not applied now (the kernel refused):$ERR" >&2; return 1; }
}

# apply key=value ...: validates everything first; nothing is written unless all of it is valid.
# Starts from the profile in use (the saved custom settings, or a preset's values).
apply_custom() {
	tables
	load_profile
	want "$P"
	bad=
	for a in "$@"; do
		k=${a%%=*}
		v=${a#*=}
		case " $KEYS " in
		*" $k "*) ;;
		*)
			bad="$bad
unknown knob: $k"
			continue
			;;
		esac
		options "$k"
		if [ "$a" = "$k" ] || [ -z "$v" ]; then
			bad="$bad
$k: missing value (one of: $O)"
		elif [ "$k" = cpu0 ] && [ "$v" != 1 ]; then
			bad="$bad
cpu0 can't be taken offline"
		else
			case " $O " in
			*" $v "*) eval "v_$k=\$v" ;;
			*) bad="$bad
$k: $v is not one of: $O" ;;
			esac
		fi
	done
	for c in little big gpu; do
		eval "lo=\$v_${c}_min hi=\$v_${c}_max"
		[ "$lo" -gt "$hi" ] && bad="$bad
${c}_min $lo is above ${c}_max $hi"
	done
	[ "$v_cpu4$v_cpu5$v_cpu6$v_cpu7" = 0000 ] && bad="$bad
cpu4-cpu7 all offline: keep at least one big core online"
	if [ -n "$bad" ]; then
		echo "rejected, nothing changed:$bad" >&2
		return 2
	fi
	mkdir -p "$DIR"
	for k in $KEYS; do
		eval "echo \"$k=\$v_$k\""
	done >"$CUSTOM.tmp" && mv "$CUSTOM.tmp" "$CUSTOM"
	echo custom >"$STATE"
	apply_all custom || { echo "saved, but not applied now (the kernel refused):$ERR" >&2; return 1; }
	echo "custom applied"
}

knobs() {
	load_profile
	tables
	want "$P"
	echo "profile=$P"
	for k in $KEYS; do
		live "$k"
		stock "$k"
		echo "$k=$L"
		echo "$k.options=$O"
		echo "$k.stock=$S"
		eval "echo \"$k.want=\$v_$k\""
	done
}

# millidegrees -> "54.0"
celsius() {
	echo "$(($1 / 1000)).$(($1 % 1000 / 100))"
}

# DPID = the daemon's pid if it runs. The pid file can be left from a previous boot, its number
# now used by another process, so the command line must be ours: with `kill -0` alone a
# media.codec thread passed for the daemon and the daemon never started again after a reboot.
daemon_running() {
	DPID= dc=
	[ -f "$PIDFILE" ] && read -r DPID <"$PIDFILE" || return 1
	read -r dc 2>/dev/null <"/proc/$DPID/cmdline"
	case $dc in */cool.sh*daemon) ;; *) DPID= && return 1 ;; esac
}

status() {
	load_profile
	tables
	want "$P"
	echo "profile: $P (caps: little $((v_little_max / 1000)) MHz, big $((v_big_max / 1000)) MHz, GPU $((v_gpu_max / 1000)) MHz)"
	for c in LITTLE:$LITTLE BIG:$BIG; do
		read -r cur <"${c#*:}/scaling_cur_freq"
		read -r max <"${c#*:}/scaling_max_freq"
		echo "${c%%:*}: $((cur / 1000)) MHz now, max $((max / 1000)) MHz"
	done
	read -r cur <"$GPU/gpu_clock"
	read -r max <"$GPU/gpu_max_clock"
	echo "GPU: $((cur / 1000)) MHz now, max $((max / 1000)) MHz"
	on=0
	for i in 1 2 3 4 5 6 7; do
		read -r o <"$SYS/cpu$i/online"
		[ "$o" = 1 ] && on="$on $i"
	done
	echo "cores online: $on"
	t=
	for z in /sys/class/thermal/thermal_zone*; do
		read -r type <"$z/type"
		read -r temp <"$z/temp"
		t="$t $type $(celsius "$temp")C"
	done
	echo "temps:$t"
	if daemon_running; then
		echo "daemon: running (pid $DPID)"
	else
		echo "daemon: not running"
	fi
}

# Sets D to the knobs of profile $1 (wanted values in v_*) that something else rewrote. Only the
# direction that undoes our setting counts: a max raised above it, a min lowered below it, an
# offline core brought online, any other knob changed. Thermal limits (a lower max, an offline
# core) are left alone. Presets only hold their caps, as before custom existed.
drift() {
	D=
	for k in $KEYS; do
		[ "$1" = custom ] || case $k in little_max | big_max | gpu_max) ;; *) continue ;; esac
		eval "w=\$v_$k"
		live "$k"
		[ "$L" = - ] && continue
		case $k in
		*_max) [ "$L" -gt "$w" ] ;;
		gpu_min) [ "$L" -lt "$w" ] ;;
		*_min)
			# Below the wanted min only because thermal pulled the max under it: not ours to fix.
			file "${k%_min}_max"
			read -r m <"$F"
			[ "$L" -lt "$w" ] && [ "$m" -ge "$w" ]
			;;
		cpu*) [ "$w" = 0 ] && [ "$L" = 1 ] ;;
		*) [ "$L" != "$w" ] ;;
		esac && D="$D $k=$L"
	done
}

daemon() {
	if daemon_running && [ "$DPID" != $$ ]; then
		echo "daemon already running (pid $DPID)" >&2
		return 1
	fi
	mkdir -p "$DIR"
	[ -p "$TICK" ] || mkfifo "$TICK"
	echo $$ >"$PIDFILE"
	tables
	applied=
	while :; do
		load_profile
		want "$P"
		if [ "$P" != "$applied" ]; then
			# Boot, or a profile switched by `set`/`apply` (already applied; re-applying is harmless).
			apply_all "$P"
			applied=$P
		else
			drift "$P"
			if [ -n "$D" ]; then
				log -t phone-cooler "rewritten:$D, re-applying $P"
				apply_all "$P" keep-offline
			fi
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
	cold) [ -f "$CUSTOM" ] && n=custom || n=off ;;
	*) n=off ;;
	esac
	set_profile "$n" && echo "$n"
	;;
status) status ;;
knobs) knobs ;;
apply)
	shift
	if [ $# = 0 ]; then set_profile custom; else apply_custom "$@"; fi
	;;
daemon) daemon ;;
*)
	echo "usage: cool.sh set off|mild|cool|cold|custom | get | next | status | knobs | apply key=value ... | daemon" >&2
	exit 2
	;;
esac
