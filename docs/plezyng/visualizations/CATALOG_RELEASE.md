# Catalog release configuration

The app compiles the same pinned trust material on every platform. The
canonical app catalog uses schema-v2 Sigstore bundles signed by the
`visualizer-catalog.yml` GitHub Actions identity on `main`; the client checks
the pinned publisher identity, Fulcio certificate, and Rekor entry. The
checked-in `content/visualizer-catalog.json` is published through this route
and currently contains only the sample fixture. Refresh remains an explicit
library action. Build environments cannot substitute the publisher identity
or signing trust material.

The app also supports schema-v1 Ed25519 envelopes. Empty committed Ed25519
keys disable that envelope route, but do not disable the canonical Sigstore
route. The separate upstream MilkRust Ed25519 root is currently unprovisioned,
so schema-v1 envelopes signed by it fail closed.

To activate the optional schema-v1 Ed25519 route, first provision signing keys
in approved custody and review the public root in MilkRust. Fetch
`content/catalog-trust.json` at that reviewed full commit and independently
record its SHA-256. In this repository run:

```sh
python3 scripts/visualizer/configure_catalog_trust.py \
  --input /path/to/public-catalog-trust.json \
  --source-revision "$REVIEWED_MILKRUST_COMMIT" \
  --sha256 "$REVIEWED_PUBLIC_ROOT_SHA256"
```

The tool accepts an active root with canonical distinct Ed25519 public keys,
valid quorum and a minimum sequence. It writes only the public Dart pin with
its source revision and digest. Review/commit that file, then ship it in the app
before bootstrapping the corresponding signed catalog. `--check` compares the
reviewed root with the committed source without writing. No private material
belongs in the app repository or this tool's input. Key custody and the protected
MilkRust publisher environment remain external provisioning requirements.

On first install the verifier rejects sequences below the release floor;
subsequent refreshes also enforce durable local sequence/digest checkpoints.
Rotation must overlap keys until supported app quorums and the existing signed
publication can both be verified. Raising the floor does not retroactively
qualify content or force a download.

Every remotely delivered broader pack needs a signed immutable qualification
report and all 13 targets required by `all-native-hosts-v1`. The publisher
checks per-preset evidence, source/artifact digests, rights review and the
required runner/device evidence, using compatible public GitHub-hosted runners
by default and private ephemeral JIT only where platform, device, or private
resource requirements demand it. The app validates the signed report summary
and links it in the library; report inspection is user-initiated. It does not
re-run GPU comparisons on the phone/TV. Labels describe the report's recorded
engine/device versions, not universal fidelity on all future hardware. The
exact authored sample archive retains the narrow `sample-fixture-only`
exception and is labeled unqualified. Old installed receipts without
qualification remain readable; they cannot authorize a new broader signed
download.

The schema-v1 Ed25519-root configuration route still requires owner-held keys
and a reviewed public root. The current keyless route has a published signed
catalog, but it contains only the unqualified sample fixture; no broader
qualified archive is active.
