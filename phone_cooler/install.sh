#!/usr/bin/env bash
# install.sh [install|uninstall|status|knobs|set PROFILE|apply KEY=VALUE...] — phone-cooler on the
# rooted phone, over adb.
# Uses $ANDROID_SERIAL, else the Tailscale address saved by phone-adb (remote_control), else
# the only adb device.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -z ${ANDROID_SERIAL:-} ]]; then
	ip=$(sed -n 's/^ip=//p' "${XDG_CONFIG_HOME:-$HOME/.config}/remote_control/phone-adb" 2>/dev/null || true)
	if [[ -n $ip ]] && adb devices | grep -q "^$ip:5555[[:space:]]*device"; then
		export ANDROID_SERIAL=$ip:5555
	fi
fi

dir=/data/adb/phone-cooler
launcher=/data/adb/service.d/phone-cooler.sh
apk=/data/local/tmp/cooler.apk

root() {
	adb shell "su -c '$1'"
}

# The pid is checked to still be the daemon (pids get reused).
stop_daemon() {
	root "p=\$(cat $dir/daemon.pid 2>/dev/null) && grep -q cool.sh /proc/\$p/cmdline 2>/dev/null && kill \$p; rm -f $dir/daemon.pid; true"
}

case ${1:-install} in
install)
	[[ $(adb shell su -c id 2>/dev/null) == *uid=0* ]] || { echo "no root over adb (Magisk: allow Shell)" >&2; exit 1; }
	android/build.sh
	adb push cool.sh /data/local/tmp/phone-cooler.sh >/dev/null
	root "mkdir -p $dir && mv /data/local/tmp/phone-cooler.sh $dir/cool.sh && chmod 755 $dir/cool.sh"
	# Magisk runs service.d scripts after boot without waiting for them. The daemon applies the
	# remembered profile at start and keeps it applied.
	printf '%s\n' '#!/system/bin/sh' \
		'# Installed by phone_cooler/install.sh: keeps the remembered clock caps after boot.' \
		'until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 5; done' \
		"exec $dir/cool.sh daemon" |
		adb shell "su -c 'cat > $launcher && chmod 755 $launcher'"
	# (Re)start the daemon now, detached from this adb shell, so it runs the new script.
	stop_daemon
	root "setsid nohup $dir/cool.sh daemon >/dev/null 2>&1 </dev/null &"
	# The app is only staged: installing it needs the phone unlocked for Play Protect.
	adb push cooler.apk "$apk" >/dev/null
	echo "APK staged at $apk; install it with: adb shell pm install -r $apk"
	sleep 1
	root "$dir/cool.sh status"
	;;
uninstall)
	stop_daemon
	root "[ -x $dir/cool.sh ] && $dir/cool.sh set off; rm -rf $dir $launcher $apk"
	echo "removed (stock clocks restored); the Cooler app, if installed, stays until you uninstall it"
	;;
status)
	root "$dir/cool.sh status"
	;;
set)
	root "$dir/cool.sh set ${2:?profile: off|mild|cool|cold|custom} && $dir/cool.sh status"
	;;
knobs)
	root "$dir/cool.sh knobs"
	;;
apply)
	shift
	(($#)) || { echo "usage: $0 apply KEY=VALUE ... (see: $0 knobs)" >&2; exit 2; }
	# Values are table entries (digits and governor names); cool.sh validates them again.
	root "$dir/cool.sh apply $* && $dir/cool.sh status"
	;;
*)
	echo "usage: $0 [install|uninstall|status|knobs|set off|mild|cool|cold|custom|apply KEY=VALUE...]" >&2
	exit 2
	;;
esac
