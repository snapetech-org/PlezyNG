#!/usr/bin/env bash
# Install the existing Linux ARM64 application as a private, paired music host.
# Configure a Plex profile in the normal Pleazyng UI before enabling this unit.
set -euo pipefail

unit_name=pleazyng-music-endpoint.service
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
launcher_dir="${XDG_DATA_HOME:-$HOME/.local/share}/pleazyng/music-endpoint"
launcher="$launcher_dir/launch.sh"

usage() {
  cat <<'USAGE'
Usage: install.sh install [path-to-pleazyng]
       install.sh status
       install.sh remove

The Pi must run a 64-bit Linux build of Pleazyng. First open the normal app,
sign in, select its profile, and verify music plays. The endpoint uses that
profile and the existing encrypted companion pairing code. A locked or
unconfigured profile cannot accept remote playback. Install xvfb and xauth
through your distribution, then install this user service as the same user.
Updates come from the Pleazyng package; restart this unit after an upgrade.
USAGE
}

case "${1:-}" in
  status)
    status=0
    systemctl --user status "$unit_name" --no-pager || status=$?
    journalctl --user -u "$unit_name" -n 30 --no-pager || true
    exit "$status"
    ;;
  remove)
    if [[ -f "$unit_dir/$unit_name" || -f "$launcher" ]]; then
      systemctl --user disable --now "$unit_name"
    fi
    rm -f -- "$unit_dir/$unit_name" "$launcher"
    systemctl --user daemon-reload
    exit 0
    ;;
  install) ;;
  *) usage; exit 2 ;;
esac

if [[ "$(id -u)" == 0 ]]; then
  echo 'Run as the Pleazyng profile owner, not root.' >&2
  exit 1
fi
for dependency in systemctl xvfb-run xauth; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "Missing $dependency. Install the distribution package before enabling the endpoint." >&2
    exit 1
  fi
done

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
if [[ -n "${2:-}" ]]; then
  binary="$2"
elif [[ -x /usr/bin/pleazyng ]]; then
  binary=/usr/bin/pleazyng
else
  binary="$source_dir/pleazyng"
fi
if [[ ! -x "$binary" ]]; then
  echo "Pleazyng executable not found: $binary" >&2
  exit 1
fi
binary="$(readlink -f -- "$binary")"
if [[ "$launcher" != /* || "$unit_dir" != /* || "$launcher" == *\"* ||
      "$launcher" == *%* || "$launcher" == *\\* || "$launcher" == *\$* ||
      "$launcher" =~ [[:cntrl:]] ]]; then
  echo 'Unsupported character in the user service path.' >&2
  exit 1
fi

mkdir -p -- "$launcher_dir" "$unit_dir"
chmod 700 "$launcher_dir"
temporary_launcher="$(mktemp "$launcher_dir/.launch.XXXXXX")"
temporary_unit="$(mktemp "$unit_dir/.endpoint.XXXXXX")"
trap 'rm -f -- "$temporary_launcher" "$temporary_unit"' EXIT
printf -v quoted_binary '%q' "$binary"
cat > "$temporary_launcher" <<LAUNCHER
#!/usr/bin/env bash
set -euo pipefail
export GDK_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1
exec xvfb-run -a --server-args='-screen 0 1280x720x24 -nolisten tcp' $quoted_binary --pleazyng-music-endpoint
LAUNCHER
chmod 700 "$temporary_launcher"
cat > "$temporary_unit" <<UNIT
[Unit]
Description=Pleazyng paired music endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
ExecStart="$launcher"
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
UNIT
chmod 600 "$temporary_unit"
mv -f -- "$temporary_launcher" "$launcher"
mv -f -- "$temporary_unit" "$unit_dir/$unit_name"
systemctl --user daemon-reload
systemctl --user enable "$unit_name"
systemctl --user restart "$unit_name"
if command -v loginctl >/dev/null 2>&1 &&
   [[ "$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null || true)" != yes ]]; then
  echo "For startup before login, enable user lingering: sudo loginctl enable-linger $(id -un)"
fi
echo "Endpoint installed. Check it with: $0 status"
