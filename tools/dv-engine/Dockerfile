FROM docker.io/library/ubuntu:26.10@sha256:b5194b8e58989da0865ebc80078bf9f5f8742ec6a867c53f6ae699f6036756f7

# Package versions are recorded in the output; the apt archive is not frozen.
# This is a pinned-source experiment, not a claim of bit-identical rebuilds.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y --no-install-recommends \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential git ca-certificates python3 meson ninja-build pkg-config zlib1g-dev \
    nasm xz-utils libass-dev libdav1d-dev libgnutls28-dev libdrm-dev libva-dev \
    libegl-dev libgl-dev libgles-dev libgbm-dev liblcms2-dev liblua5.2-dev \
    libasound2-dev libpulse-dev libpipewire-0.3-dev libx11-dev libxrandr-dev \
    libxext-dev libxpresent-dev libxss-dev libxv-dev libxkbcommon-dev \
    libwayland-dev wayland-protocols libdisplay-info-dev libcurl4-gnutls-dev \
    libgl1-mesa-dri \
    && rm -f /usr/bin/pebble \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
ENTRYPOINT ["python3", "/src/tools/dv-engine/build_linux.py"]
