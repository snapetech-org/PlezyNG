// Updated only by scripts/visualizer/configure_catalog_trust.py from a reviewed,
// immutable MilkRust trust root. Public keys belong in source, not CI secrets.
// Empty Ed25519 keys close schema-v1 envelopes; the pinned keyless publisher
// route remains enabled for the canonical schema-v2 catalog.
const visualizerReleaseTrustJson = '{"keys":{},"minimumSequence":1,"threshold":1}';
const visualizerReleaseTrustRevision = '';
const visualizerReleaseTrustSha256 = '';
