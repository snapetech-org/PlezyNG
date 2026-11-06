#!/usr/bin/env python3
"""Check the installed user Flatpak against its runtime, not the build SDK.

Run after `flatpak install --user ./pleazyng-linux-<arch>.flatpak`.
This does not replace graphical playback verification on a Wayland desktop.
"""

import argparse
import subprocess

# The runtime includes Bash, od and its ELF loader, but not Python/readelf.
# Enumerate inside the sandbox: the host must not resolve these dependencies.
CHECK = r'''
set -euo pipefail
# App libraries must not replace the runtime's own Bash/readline while the
# checker runs. Ask its ELF loader to resolve each object with a scoped path.
unset LD_LIBRARY_PATH
case "$(uname -m)" in
  x86_64) loader=/lib64/ld-linux-x86-64.so.2 ;;
  aarch64) loader=/lib/ld-linux-aarch64.so.1 ;;
  *) echo "Unsupported Flatpak runtime architecture" >&2; exit 1 ;;
esac
for executable in /app/bin/pleazyng /app/pleazyng/pleazyng /app/pleazyng/pleazyng.sh; do
    test -x "$executable" || { echo "Not executable: $executable" >&2; exit 1; }
done
if test -f /app/pleazyng/lib/crashpad_handler; then
    test -x /app/pleazyng/lib/crashpad_handler
fi
count=0
while IFS= read -r -d '' object; do
    magic=$(od -An -tx1 -N4 "$object")
    if [[ "$magic" != *"7f 45 4c 46"* ]]; then continue; fi
    # Python's development files include relocatable .o files. Only executable
    # and shared-library ELF objects can be checked by the runtime loader.
    case "$(od -An -tu2 -j16 -N2 "$object" | tr -d '[:space:]')" in
      2|3) ;;
      *) continue ;;
    esac
    # The converter launches a separate process with its own library closure.
    # Its copies must neither satisfy nor override dependencies of the app.
    case "$object" in
      /app/pleazyng/tools/dv/*) libraries=/app/pleazyng/tools/dv/lib/runtime ;;
      *) libraries=/app/pleazyng/lib ;;
    esac
    dependencies=$("$loader" --list --library-path "$libraries" "$object" 2>&1) || { echo "$dependencies" >&2; exit 1; }
    if [[ "$dependencies" == *"not found"* ]]; then
        printf 'Unresolved dependency in %s:\n%s\n' "$object" "$dependencies" >&2
        exit 1
    fi
    count=$((count + 1))
done < <(find /app/pleazyng -type f -print0)
test "$count" -gt 0
/app/pleazyng/tools/dv/plezyng-dv-convert --self-test
printf 'Resolved all dependencies for %s ELF objects in the installed runtime.\n' "$count"
'''

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--arch", choices=("x64", "arm64"), help="defaults to the host architecture")
args = parser.parse_args()
architecture = {"x64": "x86_64", "arm64": "aarch64"}.get(args.arch)
arch_options = [f"--arch={architecture}"] if architecture else []

subprocess.run([
    "flatpak", "run", "--user", *arch_options, "--command=bash", "org.snapetech.pleazyng", "-c", CHECK,
], check=True)
