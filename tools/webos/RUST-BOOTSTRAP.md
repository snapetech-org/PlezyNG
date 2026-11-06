# Disposable webOS Rust prerequisites

The private Linux x86_64 JIT image does not need a preinstalled `rustup`.
`build_milkrust_runtime.sh` calls `bootstrap_rustup.py` after verifying the LG NDK.
The helper downloads the exact official Rust manager archive named in
`compatibility.json` (`rustupBootstrap`), checks its committed SHA-256 before
execution, and checks the installed manager version. Updating the manager requires
reviewing both the immutable archive version and checksum from
`https://static.rust-lang.org/rustup/archive/<version>/x86_64-unknown-linux-gnu/rustup-init.sha256`.

The helper exclusively creates `rustup-bootstrap`, `rustup-home`, and `cargo-home`
inside the existing job task root with mode 0700. Existing directories or symlinks
cause failure. It uses no sudo, modifies no shell profiles or global PATH, and
installs no default compiler. The caller invokes the task-local manager by absolute
path, with task-local `RUSTUP_HOME` and `CARGO_HOME`.

The separate `milkrustBuild` compiler and target pins remain authoritative. Their
installation uses `--no-self-update` so the verified manager is not replaced
implicitly. A fresh job needs outbound HTTPS to the official Rust distribution
service, plus the existing source/crate endpoints needed by the locked build.
There is no shared Rust installation or cache dependency. The normal disposable
job cleanup owns these files; do not remove another job's directories.

Run the focused suite with an existing task-owned temporary directory:

```bash
PLEZY_WEBOS_TEST_TMP=/path/to/task-temp python3 -m unittest discover -s tools/webos/tests -v
```

The bootstrap tests exercise checksum rejection before execution, isolation when
the image PATH has no rustup, stale/symlink rejection, and the caller's disabled
self-update. Bootstrap tests do not establish a successful full webOS native build
or device validation; those remain release gates on the corrected source revision.
