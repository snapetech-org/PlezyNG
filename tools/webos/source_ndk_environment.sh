# Source the verified LG environment with the Python toolchain's loader path
# temporarily removed. The vendor setup script rejects any inherited
# LD_LIBRARY_PATH; after it installs the NDK paths, append the setup-python
# path so its Python 3.14 interpreter can still load libpython.
plezyng_source_ndk_environment() {
  if [[ "$#" -ne 1 || ! -f "$1" || -L "$1" ]]; then
    echo "Expected a regular verified NDK environment script." >&2
    return 2
  fi

  local environment_script="$1"
  local python_library_path="${LD_LIBRARY_PATH:-}"
  unset LD_LIBRARY_PATH

  if source "$environment_script"; then
    :
  else
    local source_status=$?
    if [[ -n "$python_library_path" ]]; then
      export LD_LIBRARY_PATH="$python_library_path"
    fi
    return "$source_status"
  fi

  if [[ -n "$python_library_path" ]]; then
    if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
      export LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:${python_library_path}"
    else
      export LD_LIBRARY_PATH="$python_library_path"
    fi
  fi
}
