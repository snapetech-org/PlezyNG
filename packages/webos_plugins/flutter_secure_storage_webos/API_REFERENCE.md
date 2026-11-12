# webOS API reference

This plugin implements the platform interface used by
[`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage).
Application code uses the standard `FlutterSecureStorage` API; the plugin is
registered as the webOS implementation by Flutter's plugin registration.

## Supported operations

The adapter implements `write`, `read`, `containsKey`, `delete`, `readAll`, and
`deleteAll`. It stores values in the webOS plugin's SQLite row and protects the
stored data through the webOS security key service. It does not use the
system keychain or keystore.

The inherited `options` map is accepted for interface compatibility. This
implementation does not interpret platform-specific storage options.

## Legacy migration

`FlutterSecureStorageWebos.migrateRegisteredLegacy()` explicitly migrates
legacy rows when this adapter is the registered platform implementation. It
returns normally when another implementation is registered. The app calls this
through [Pleazyng's credential key store](../../../lib/services/credential_key_store.dart)
as part of its storage startup gate. Ordinary reads do not perform migration
or write storage.

Migration returns no count through this static entry point. The adapter's
instance method `migrateLegacy()` returns the number of secret entries it
rewrapped. Migration errors propagate so startup can remain retryable; they do
not trigger a plaintext fallback or a store reset. See the
[security recovery record](../../../docs/security/2026-10-26-remediation.md)
for the on-disk format and recovery behavior.

## Error behavior

Invalid empty keys and values are rejected. Storage, key-service, and corrupt
data errors are surfaced as `PlatformException`s. Callers should preserve the
existing row and retry after a transient service failure rather than clearing
or recreating the store.

The native plugin requires the `securitykey.operation` ACG listed in
`appinfo.json`; see the package [setup notes](README.md#required-configurations).
