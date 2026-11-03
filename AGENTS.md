## Runner policy — PlezyNG 3.0.0 release, 2026-11-03

GitHub-hosted runners are authorized for compatible trusted-main PlezyNG 3.0.0
build, test, scan, packaging and release jobs while the organization has Actions
capacity. Use hosted runners for compatible Linux, Android, Tizen, Windows x64
and native Windows ARM64 jobs when their OS, architecture, toolchain, storage
and egress requirements are met. Keep Apple builds and jobs requiring private
NFS/APFS, gated WebOS output retention or other private storage on compatible
private ephemeral JIT runners. WebOS builds need at least 60 GiB in `RUNNER_TEMP`.
The hybrid workflow's proxy and egress preflights must pass before longer hosted
Android or Tizen builds run.

Select each runner route explicitly in the workflow; do not add automatic
hosted fallback for a failed or unavailable private job. Verify hosted image,
architecture and billing capacity before dispatch. Preserve native OS and
architecture requirements; do not substitute emulation or cross-compilation
for a native platform job. Preserve active builds and other agents' work, and
do not restart the private JIT broker while it owns running guests.

Public-fork and other untrusted code remains isolated in a disposable VM-backed
JIT sandbox with no secrets, minimal permissions and restricted egress. Do not
widen trusted runner-group access to make untrusted code run.

Packer provisions the private ephemeral JIT lanes; compatible GitHub-hosted
jobs do not require Packer. Private source routing, deployed broker policy,
runner-group access and live capacity must still agree for every private job.
Validate workflow changes on the selected route; rerunning an old run uses its
original workflow revision. Do not report the release route ready from YAML
changes or hosted-runner availability alone.

