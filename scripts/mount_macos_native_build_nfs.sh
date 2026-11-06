#!/bin/sh
# Installed as /usr/local/sbin/plezyng-native-build-mount.sh on the Apple host.
set -eu

server_host="kspld0.tail.snape.local"
server_ip="100.64.0.6"
client_ip="100.64.0.3"
server="${server_host}:/mnt/disks/gamespool0/plezyng-native-build-20261027"

network_ready() {
  resolved=$(/usr/bin/dscacheutil -q host -a name "$server_host" | /usr/bin/awk '/ip_address:/ && $2 ~ /^[0-9.]+$/ { print $2; exit }')
  interface=$(/sbin/route -n get "$server_ip" 2>/dev/null | /usr/bin/awk '/interface:/ { print $2; exit }')
  [ "$resolved" = "$server_ip" ] || return 1
  /usr/bin/printf '%s' "$interface" | /usr/bin/grep -Eq '^utun[0-9]+$' || return 1
  /sbin/ifconfig "$interface" | /usr/bin/grep -Fq "inet $client_ip " || return 1
  for port in 111 20048 2049; do
    /usr/bin/nc -G 2 -z "$server_ip" "$port" >/dev/null 2>&1 || return 1
  done
}

# The GUI client's CLI can hang while the tunnel itself is healthy. Test the
# actual authenticated route and NFS services first. Reconnect only the saved
# VPN service when necessary; credentials and profile configuration stay intact.
if ! network_ready; then
  /usr/bin/python3 - <<'PY'
import subprocess
try:
    result = subprocess.run(['scutil', '--nc', 'start', 'Tailscale'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            timeout=10)
    if result.returncode:
        raise SystemExit(75)
except subprocess.TimeoutExpired:
    raise SystemExit(75)
PY
  if ! network_ready; then
    echo "The saved Tailscale route or NFS services are not ready; retrying on the next launch interval." >&2
    exit 75
  fi
fi

mount_one() {
  target="$1"
  if /sbin/mount | /usr/bin/grep -Fq "$server on $target ("; then
    return 0
  fi
  if /sbin/mount | /usr/bin/grep -Fq " on $target ("; then
    echo "Refusing to replace an unexpected mount at $target" >&2
    exit 1
  fi
  /bin/mkdir -p "$target"
  /sbin/mount_nfs -o vers=3,tcp,hard,resvport,nosuid "$server" "$target"
}

mount_one /Volumes/plezyng-native-build-kspld0
mount_one /Volumes/p
