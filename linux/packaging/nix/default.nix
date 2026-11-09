{ pkgs ? import <nixpkgs> { } }:
let
  release = builtins.fromJSON (builtins.readFile ./release.json);
  template = builtins.readFile ./pleazyng.nix.template;
  rendered = builtins.replaceStrings
    [ "@@VERSION@@" "@@TAG@@" "@@X64_SHA256@@" "@@ARM64_SHA256@@" ]
    [ release.version release.tag release.sha256.x64 release.sha256.arm64 ]
    template;
in
import (builtins.toFile "pleazyng-release.nix" rendered) {
  inherit pkgs;
  desktopFile = ../org.snapetech.pleazyng.desktop;
  relocateCaches = ../flatpak/relocate-caches.py;
  webkitMetadata = ../webkit-runtime.json;
  webkitInstaller = ../install-webkit-helpers.py;
  rebuildPixbuf = ../rebuild-pixbuf-cache.py;
}
