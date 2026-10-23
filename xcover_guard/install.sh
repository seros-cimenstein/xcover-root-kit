#!/usr/bin/env bash
# install.sh [install|uninstall|on|off|status] — xcover-guard on the rooted phone, over adb.
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

dir=/data/adb/xcover-guard
launcher=/data/adb/service.d/xcover-guard.sh

root() {
	adb shell "su -c '$1'"
}

case ${1:-install} in
install)
	[[ $(adb shell su -c id 2>/dev/null) == *uid=0* ]] || { echo "no root over adb (Magisk: allow Shell)" >&2; exit 1; }
	adb push guard.sh /data/local/tmp/xcover-guard.sh >/dev/null
	root "mkdir -p $dir && mv /data/local/tmp/xcover-guard.sh $dir/guard.sh && chmod 755 $dir/guard.sh"
	# Magisk runs service.d scripts after boot without waiting for them.
	printf '%s\n' '#!/system/bin/sh' \
		'# Installed by xcover_guard/install.sh: starts the XCover key listener after boot.' \
		'until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 5; done' \
		"exec $dir/guard.sh listen" |
		adb shell "su -c 'cat > $launcher && chmod 755 $launcher'"
	# Start (or restart) the listener now, detached from this adb shell.
	root "setsid nohup $dir/guard.sh listen >/dev/null 2>&1 </dev/null &"
	sleep 2
	root "$dir/guard.sh status"
	;;
uninstall)
	root "$dir/guard.sh off; for p in \$(cat $dir/listen.pid 2>/dev/null); do kill \$p; done; pkill -f \"getevent -lt /dev/input/event4\"; rm -rf $dir $launcher"
	echo "removed"
	;;
on | off | status)
	root "$dir/guard.sh $1"
	;;
*)
	echo "usage: $0 [install|uninstall|on|off|status]" >&2
	exit 2
	;;
esac
