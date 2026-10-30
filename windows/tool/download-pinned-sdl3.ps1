[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$lockPath = Join-Path $PSScriptRoot 'build-toolchain.lock.json'
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$sdl3 = $lock.sdl3
$version = [string]$sdl3.version
$filename = [string]$sdl3.filename
$url = [Uri][string]$sdl3.url
$expectedHash = [string]$sdl3.sha256
$expectedPath = "/libsdl-org/SDL/releases/download/release-$version/$filename"
if (
    $version -ne '3.2.8' -or
    $filename -ne "SDL3-$version.zip" -or
    $url.Scheme -ne 'https' -or
    $url.Host -ne 'github.com' -or
    $url.Port -ne 443 -or
    $url.AbsolutePath -cne $expectedPath -or
    $url.Query -ne '' -or
    $url.Fragment -ne '' -or
    $url.UserInfo -ne '' -or
    $expectedHash -notmatch '^[0-9a-fA-F]{64}$'
) {
    throw 'The locked SDL3 release URL or checksum is invalid.'
}

if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP) -or
    [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
    throw 'RUNNER_TEMP and GITHUB_ENV are required for the private JIT build.'
}
$proxy = $env:HTTPS_PROXY
if ([string]::IsNullOrWhiteSpace($proxy)) {
    throw 'The private JIT HTTPS proxy is required to download SDL3.'
}

$curlCandidates = [System.Collections.Generic.List[string]]::new()
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

$archive = Join-Path $env:RUNNER_TEMP $filename
$extractRoot = Join-Path $env:RUNNER_TEMP "plezyng-sdl3-$version-source"
$sourceDir = Join-Path $extractRoot "SDL3-$version"
Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
$curlArguments = @(
    '--proxy', $proxy,
    '--ssl-revoke-best-effort',
    '--fail',
    '--location',
    '--silent',
    '--show-error',
    '--connect-timeout', '20',
    '--max-time', '600',
    '--retry', '3',
    '--output', $archive,
    $url.AbsoluteUri
)
& $curlPath @curlArguments
if ($LASTEXITCODE -ne 0) {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    throw "Pinned SDL3 download failed with curl exit code $LASTEXITCODE."
}

$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    throw "Pinned SDL3 SHA-256 mismatch: expected $expectedHash, got $actualHash."
}

Expand-Archive -LiteralPath $archive -DestinationPath $extractRoot -Force
foreach ($relativePath in @('CMakeLists.txt', 'include/SDL3/SDL.h')) {
    $payload = Join-Path $sourceDir $relativePath
    if (-not (Test-Path -LiteralPath $payload -PathType Leaf)) {
        throw "The checksum-verified SDL3 archive is missing $relativePath."
    }
}

Add-Content -LiteralPath $env:GITHUB_ENV -Value "PLEZYNG_SDL3_SOURCE_DIR=$sourceDir" -Encoding utf8
Write-Host "Downloaded and verified the locked SDL3 $version source archive."
