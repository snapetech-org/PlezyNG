ARG RUST_IMAGE=docker.io/library/rust@sha256:b07b1bc9cb80ea8f48f304fe469feb759f54cfd30c6ec545a1b0ec3af822daf0
FROM ${RUST_IMAGE} AS rust
FROM docker.io/library/ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517
COPY --from=rust /usr/local/rustup /usr/local/rustup
COPY --from=rust /usr/local/cargo /usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo PATH=/opt/venv/bin:/usr/local/cargo/bin:$PATH CARGO_BUILD_JOBS=2
RUN apt-get update -o Acquire::Retries=3 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3-dev python3-venv build-essential pkg-config libssl-dev git curl ca-certificates cmake ninja-build nasm \
    libx264-dev libx265-dev libzimg-dev zstd && \
    python3 -m venv /opt/venv && /opt/venv/bin/pip install meson==1.10.0 && \
    cargo install cargo-c --version 0.10.26 --locked && rm -rf /var/lib/apt/lists/*
WORKDIR /appsrc
ENTRYPOINT ["/opt/venv/bin/python", "/appsrc/tools/dv-engine/build_offline_tools.py", "--inside"]
