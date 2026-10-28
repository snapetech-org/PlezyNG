# Catalog release configuration

The app compiles `visualizer_release_trust.dart` on every platform. A build
environment cannot substitute catalog keys; the old `MILKRUST_CATALOG_KEYS`
and `MILKRUST_CATALOG_THRESHOLD` defines are no longer inputs. Empty committed
keys explicitly disable remote refresh. This is the current state, not a
provisioned production deployment.

After the owner creates keys in approved custody and reviews the public root in
MilkRust, fetch `content/catalog-trust.json` at that reviewed full commit and
independently record its SHA-256. In this repository run:

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
report and all 13 targets required by `all-native-hosts-v1`. The publisher checks
per-preset evidence, source/artifact digests, rights review and a physical-device
private JIT run. The app validates the signed report summary and links it in the
library; report inspection is user-initiated. It does not re-run GPU comparisons
on the phone/TV. Labels describe the report's recorded engine/device versions,
not universal fidelity on all future hardware. The exact authored sample archive
retains the narrow `sample-fixture-only` exception and is labeled unqualified.
Old installed receipts without qualification remain readable; they cannot
authorize a new broader signed download.

Source changes and regression cases have not been executed. No production key,
signed endpoint or qualified broader archive was created by this increment.
