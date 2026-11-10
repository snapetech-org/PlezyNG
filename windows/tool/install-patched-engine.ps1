# Download the published flutter-plezy patched Windows engine (DirectComposition
# + resize-wedge fix) and install it into the active Flutter SDK's artifact cache.
#
# Pleazyng requires this engine on Windows: it honors the FLUTTER_WINDOWS_DCOMP
# environment variable (set in windows/runner/main.cpp) and presents the Flutter
# UI on a topmost DirectComposition visual, so the mpv video window composites
# *beneath* the UI in a single HWND (window capture works, no transparency
# hacks). It also heals the embedder resize-synchronization wedge that leaves
# the window blank when a window manager (e.g. PowerToys FancyZones) resizes it
# around the first frame (flutter/flutter#159630). On a stock engine both are
# absent: the flag is a no-op and compositing breaks.
#
# Used by CI (.github/workflows/build.yml) and by contributors building locally.
# Engine developers who build their own artifacts use swap-engine.ps1 instead.
#
# The flutter tool validates the engine cache by engine.stamp string only (no
# file hashing), so the swap sticks - but `flutter upgrade` /
# `flutter precache --force` silently restore the stock engine; re-run this
# afterwards. Run `flutter precache --windows` once before this script so the
# cache layout and engine.stamp exist.
#
# Usage:
#   flutter precache --windows
#   windows/tool/install-patched-engine.ps1
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant(),
    [string]$Url = '',
    [string]$Sha256 = '',
    [string]$ExpectedEngine = 'cf636b1dfb818dd6a3ff16e390e93b1a036969c8'
)

if ([string]::IsNullOrWhiteSpace($Url)) {
    $Url = "https://github.com/snapetech-org/pleazyng/releases/download/flutter-security-3.47.8/flutter-pleazyng-windows-3.47.8-$Architecture.zip"
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        $Sha256 = @{
            x64 = '409ec2ffd14f5d9c0de7964a43ec8cdcb6d9530775b909a6e973f4c7431f9126'
            arm64 = '7c0d3a3679a05956c5c48ac5d04ceab83ad875a4bf2c5ed4fe760b1a806e86e9'
        }[$Architecture]
    }
} elseif ([string]::IsNullOrWhiteSpace($Sha256)) {
    throw 'A custom engine URL requires an explicit SHA-256 digest'
}

$ErrorActionPreference = 'Stop'

$flutterCmd = Get-Command flutter.bat -ErrorAction SilentlyContinue
if (-not $flutterCmd) { $flutterCmd = Get-Command flutter }
$sdkRoot = Split-Path -Parent (Split-Path -Parent $flutterCmd.Source)

$stampPath = Join-Path $sdkRoot 'bin\cache\engine.stamp'
if (-not (Test-Path $stampPath)) {
    Write-Error "engine.stamp not found at $stampPath - run 'flutter precache --windows' first"
}
$stamp = (Get-Content $stampPath -Raw).Trim()
if ($stamp -ne $ExpectedEngine) {
    Write-Error "SDK engine.stamp is $stamp but the patched engine targets $ExpectedEngine - this flutter-plezy build is for a different SDK"
}

$engineDir = Join-Path $sdkRoot 'bin\cache\artifacts\engine'
if (-not (Test-Path $engineDir)) {
    Write-Error "engine cache not found: $engineDir - run 'flutter precache --windows' first"
}

$zip = Join-Path ([System.IO.Path]::GetTempPath()) 'flutter-plezy-windows.zip'

# Invoke-WebRequest renders a per-byte progress bar in Windows PowerShell that
# makes large downloads crawl; silence it.
$ProgressPreference = 'SilentlyContinue'
Write-Output "Downloading patched engine from $Url ..."
$downloadHelper = Join-Path $PSScriptRoot '..\..\scripts\prepare_native_downloads.py'
python $downloadHelper --github-url $Url --expected-sha $Sha256 --output $zip
if ($LASTEXITCODE -ne 0) { throw 'Verified patched engine download failed' }

$actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $Sha256.ToLower()) {
    Remove-Item $zip -Force
    Write-Error "SHA256 mismatch: expected $Sha256 but got $actual"
}

# The zip holds top-level windows-x64/ (debug) and windows-x64-release/ folders;
# extracting over the engine dir swaps both cache variants in place.
Write-Output "Extracting patched engine into $engineDir ..."
Expand-Archive -Path $zip -DestinationPath $engineDir -Force
Remove-Item $zip -Force

Write-Output "Installed patched DComp engine ($Architecture debug and release)."
