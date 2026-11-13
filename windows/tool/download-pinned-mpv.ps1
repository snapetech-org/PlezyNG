[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture
)

$ErrorActionPreference = 'Stop'

$lockPath = Join-Path $PSScriptRoot '..\..\mpv-build.lock.json'
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$repo = [string]$lock.repo
$mpv = $lock.artifacts.windows
$assetArchitecture = if ($Architecture -eq 'arm64') { 'aarch64' } else { 'x86_64' }
$assetProperty = $mpv.assets.PSObject.Properties[$assetArchitecture]
if ($null -eq $assetProperty) {
    throw "The Windows MPV lock has no $assetArchitecture artifact."
}

$asset = [string]$assetProperty.Value.asset
$expectedHash = [string]$assetProperty.Value.checksum
$nativeWindows = $lock.nativePackages.windows
if ($null -eq $nativeWindows) {
    throw 'The Windows MPV lock has no nativePackages.windows FEL receipts.'
}
$receiptProperty = $nativeWindows.PSObject.Properties[$assetArchitecture]
if ($null -eq $receiptProperty) {
    throw "The Windows MPV lock has no FEL receipt for $assetArchitecture."
}
$packageReceipt = $receiptProperty.Value
$capabilities = $packageReceipt.capabilities
if (
    [string]$packageReceipt.asset -cne $asset -or
    [string]$packageReceipt.checksum -cne $expectedHash -or
    [int]$capabilities.inspectionSchema -ne 5 -or
    [string]$capabilities.felEngineId -cne 'plezyng-dv-fel-v1' -or
    [string]$capabilities.artifactSha256 -cne $expectedHash
) {
    throw 'The Windows MPV package receipt does not attest plezyng-dv-fel-v1 for the locked archive checksum.'
}
$base = [Uri][string]$mpv.assetBase
$expectedAssetBase = "https://github.com/$repo/releases/download/binaries-windows"
if (
    $repo -cne 'snapetech-org/mpv-build' -or
    $base.Scheme -ne 'https' -or
    $base.Host -ne 'github.com' -or
    $base.Port -ne 443 -or
    $base.AbsoluteUri.TrimEnd('/') -cne $expectedAssetBase -or
    $asset -notmatch '^[A-Za-z0-9_.-]+\.zip$' -or
    $expectedHash -notmatch '^[0-9a-fA-F]{64}$'
) {
    throw 'The locked Windows MPV download location or checksum is invalid.'
}

$proxy = $env:HTTPS_PROXY
$allowDirect = $env:PLEZYNG_ALLOW_DIRECT_DOWNLOADS -eq '1'
if ([string]::IsNullOrWhiteSpace($proxy) -and -not $allowDirect) {
    throw 'The private JIT HTTPS proxy is required to download Windows MPV.'
}

$curlCandidates = [System.Collections.Generic.List[string]]::new()
$explicitCurl = $env:PLEZYNG_WINDOWS_CURL_PATH
if (-not [string]::IsNullOrWhiteSpace($explicitCurl)) {
    $curlCandidates.Add($explicitCurl)
}
foreach ($command in (Get-Command curl.exe -CommandType Application -All -ErrorAction SilentlyContinue)) {
    if (-not $curlCandidates.Contains($command.Source)) {
        $curlCandidates.Add($command.Source)
    }
}

$curlPath = $null
foreach ($candidate in $curlCandidates) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        continue
    }
    $versionOutput = & $candidate --version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch 'Schannel') {
        continue
    }
    $helpOutput = & $candidate --help all 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $helpOutput.Contains('--ssl-revoke-best-effort')) {
        $curlPath = $candidate
        break
    }
}
if ($null -eq $curlPath) {
    throw 'No Windows Schannel curl with --ssl-revoke-best-effort is available.'
}

$archive = Join-Path $env:RUNNER_TEMP "plezyng-mpv-$Architecture.zip"
$url = "$($base.AbsoluteUri.TrimEnd('/'))/$asset"
$curlArguments = @(
    '--ssl-revoke-best-effort',
    '--fail',
    '--location',
    '--silent',
    '--show-error',
    '--connect-timeout', '20',
    '--max-time', '600',
    '--retry', '3',
    '--output', $archive,
    $url
)
if (-not [string]::IsNullOrWhiteSpace($proxy)) {
    $curlArguments = @('--proxy', $proxy) + $curlArguments
}
if ($env:GH_TOKEN) {
    $downloadHelper = Join-Path $PSScriptRoot '..\..\scripts\prepare_native_downloads.py'
    python $downloadHelper --github-url ([string]$url) --expected-sha $expectedHash --output $archive
} else {
    & $curlPath @curlArguments
}
if ($LASTEXITCODE -ne 0) {
    throw "Pinned Windows MPV download failed with curl exit code $LASTEXITCODE."
}

$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    throw "Pinned Windows MPV SHA-256 mismatch: expected $expectedHash, got $actualHash."
}

Add-Content -LiteralPath $env:GITHUB_ENV -Value "PLEZYNG_MPV_ARCHIVE_PATH=$archive" -Encoding utf8
Add-Content -LiteralPath $env:GITHUB_ENV -Value "PLEZYNG_WINDOWS_CURL_PATH=$curlPath" -Encoding utf8
Write-Host "Downloaded and verified the locked Windows MPV archive for $Architecture."
