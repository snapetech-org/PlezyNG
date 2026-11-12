# flutter_secure_storage_webos

The webOS implementation of [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage).

## Supported platforms

This plugin is supported on webOS 26 media or above.

## Usage

This package is not an _endorsed_ implementation of `flutter_secure_storage`.
Therefore, you have to include `flutter_secure_storage_webos` alongside `flutter_secure_storage` as dependencies in your `pubspec.yaml` file.

**pubspec.yaml:**

```yaml
dependencies:
  flutter_secure_storage: ^10.3.4
  flutter_secure_storage_webos:
    path: packages/webos_plugins/flutter_secure_storage_webos
```

This is the dependency configuration used by Pleazyng. The webOS adapter is
maintained in this repository and contains changes beyond the upstream plugin.

**Import:**

```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
```

For detailed usage, see https://pub.dev/packages/flutter_secure_storage#getting-started.

## Required configurations

Add the following ACGs to your `appinfo.json`:

```json
"requiredACG": [
  "securitykey.operation"
]
```

## Example

The package does not include a standalone example app. Pleazyng uses the
standard `FlutterSecureStorage` API through its
[credential key store](../../../lib/services/credential_key_store.dart).

## API Reference

See the [webOS API reference](API_REFERENCE.md) for supported operations,
options, migration, and error behavior.

## Limitations

- Platform-specific options (`IOSOptions`, `AndroidOptions`, `WebOptions`) are ignored on webOS.
- Data is stored in a local SQLite database with AES-256-CBC encryption, not in a system keychain/keystore.

## PlezyNG storage recovery

This vendored adapter uses the webOS key service for AES keys. Reads preserve
the stored row on key-service and database errors. Writes stage independent
keys and atomically compare/replace the SQLite row before retiring old keys.
Legacy envelopes remain readable; new writes use versioned envelopes and require
this Dart implementation and its matching native `compareAndStore` method.
Older plugin versions cannot read those new envelopes after a downgrade.

See the repository's `docs/security/2026-10-26-remediation.md` for the format,
failure behavior and host regression checks.
