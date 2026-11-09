# AppImage update contract

New x64 AppImage builds embed this fork's GitHub repository and the exact
`.AppImage.zsync` asset name. Gear Lever and AppImageUpdate can discover that
update feed. The existing Linux arm64 package formats remain available.

The release packager is shared with a small hosted Ubuntu CI fixture. It keeps
the existing AppDir layout, icon, pinned appimagetool and pinned runtime, and
requires zsyncmake. Verification inspects the ELF without executing it, checks
repository and filenames, and checks the sidecar's length, block data size and
whole-image digest. SHA-1 is a zsync protocol field; release SHA-256 manifests
and provenance cover both the image and sidecar.

Release assembly verifies advertised update contracts before publication.
Recovered historical images without update metadata retain their original
contract. A historical image with an orphan sidecar fails verification. This
preserves immutable release artifacts while requiring complete pairs for new
update-enabled images.

Local qualification used the real pinned packager and generated a matching
image and sidecar. Eight regression tests cover corruption, mismatched names,
foreign repositories, truncated control data, legacy handling and release
SHA-256 coverage. The hosted fixture checks the same packager on Ubuntu.
End-to-end update-client qualification follows the first published release
with this contract.

## Upstream sources

[d832b4212c](https://github.com/edde746/plezy/commit/d832b4212ceabc68bfee6785177f40bd2a724723) was contributed to upstream Plezy by [@nataloko](https://github.com/nataloko). Pleazyng independently adapted the update behavior to its existing packager, asset names, provenance and immutable-release recovery. See the [source ledger](../../UPSTREAM_ATTRIBUTION.md).
