This self-signed localhost certificate and deliberately public private key are
only TLS test fixtures. Tests install them with the debug CertificateTrust hook
and an isolated HttpOverrides scope, then reset that trust during teardown.
Production networking does not trust them. SANs: localhost and 127.0.0.1. No user's key or
credential is included. Do not use these fixtures for any deployed service.
