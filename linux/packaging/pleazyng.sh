#!/usr/bin/env bash
# Wrapper script for Pleazyng. Works for both:
#   - Portable tarball (run from extracted directory)
#   - System packages (/usr/bin/pleazyng -> /opt/pleazyng/)

# Resolve the real path of this script, following symlinks
SCRIPT_PATH="$(readlink -f "$0")"
INSTALL_DIR="$(dirname "$SCRIPT_PATH")"

# If we're in /usr/bin, the actual install is in /opt/pleazyng
if [[ "$INSTALL_DIR" == "/usr/bin" ]]; then
    INSTALL_DIR="/opt/pleazyng"
fi

# Prepend bundled libraries to LD_LIBRARY_PATH
if [[ -d "$INSTALL_DIR/lib" ]]; then
    export LD_LIBRARY_PATH="$INSTALL_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# Fixed Steam decoder plugins matching the bundled GStreamer runtime.
if [[ -d "$INSTALL_DIR/lib/gstreamer-1.0" ]]; then
    export GST_PLUGIN_SYSTEM_PATH_1_0="$INSTALL_DIR/lib/gstreamer-1.0"
    export GST_PLUGIN_PATH_1_0=""
    export GST_PLUGIN_SCANNER_1_0="$INSTALL_DIR/lib/gstreamer-tools/gst-plugin-scanner"
fi

# gdk-pixbuf loaders
if [[ -f "$INSTALL_DIR/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" ]]; then
    export GDK_PIXBUF_MODULE_FILE="$INSTALL_DIR/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
fi

# GIO modules
if [[ -d "$INSTALL_DIR/lib/gio/modules" ]]; then
    export GIO_MODULE_DIR="$INSTALL_DIR/lib/gio/modules"
fi

# gio-launch-desktop: the bundled libgio spawns URL/desktop-file handlers
# through this helper. Its compiled-in path only exists on the build distro
# and glib's PATH fallback misses hosts that keep it in /usr/libexec, which
# broke every URL launch (#1477). Point libgio at the bundled copy.
if [[ -x "$INSTALL_DIR/lib/glib-2.0/gio-launch-desktop" ]]; then
    export GIO_LAUNCH_DESKTOP="$INSTALL_DIR/lib/glib-2.0/gio-launch-desktop"
fi

# Use the shipped input modules. Portable bundles can move after generation;
# keep their relocated cache in the user's cache directory, not the bundle.
im_cache="$INSTALL_DIR/lib/gtk-3.0/3.0.0/immodules.cache"
if [[ -f "$im_cache" ]]; then
    im_relocate=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^\"([^\"]+\.so)\" ]]; then
            [[ "${BASH_REMATCH[1]}" == "$INSTALL_DIR/lib/gtk-3.0/3.0.0/immodules/"* ]] || im_relocate=true
            break
        fi
    done < "$im_cache"
    if $im_relocate; then
        im_directory="${XDG_CACHE_HOME:-$HOME/.cache}/pleazyng/gtk-im"
        im_key=$(printf '%s' "$INSTALL_DIR" | sha256sum)
        im_destination="$im_directory/${im_key%% *}.cache"
        mkdir -p "$im_directory" || exit 1
        im_temporary=$(mktemp "$im_directory/.cache.XXXXXX") || exit 1
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^\"([^\"]+\.so)\" ]]; then
                im_module="$INSTALL_DIR/lib/gtk-3.0/3.0.0/immodules/${BASH_REMATCH[1]##*/}"
                if [[ ! -f "$im_module" ]]; then
                    rm -f -- "$im_temporary"
                    echo "Missing bundled GTK input module: $im_module" >&2
                    exit 1
                fi
                im_module="${im_module//\\/\\\\}"
                im_module="${im_module//\"/\\\"}"
                printf '"%s"\n' "$im_module"
            else
                printf '%s\n' "$line"
            fi
        done < "$im_cache" > "$im_temporary"
        mv -f -- "$im_temporary" "$im_destination" || exit 1
        im_cache="$im_destination"
    fi
    export GTK_IM_MODULE_FILE="$im_cache"
fi

# GTK module path (print backends, etc.)
if [[ -d "$INSTALL_DIR/lib/gtk-3.0" ]]; then
    export GTK_PATH="$INSTALL_DIR/lib/gtk-3.0"
fi

# GSettings schemas
if [[ -d "$INSTALL_DIR/share/glib-2.0/schemas" ]]; then
    export GSETTINGS_SCHEMA_DIR="$INSTALL_DIR/share/glib-2.0/schemas"
fi

exec "$INSTALL_DIR/pleazyng" "$@"
