[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$lockPath = Join-Path $PSScriptRoot 'build-toolchain.lock.json'
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$archives = @(
    [pscustomobject]@{
        key = 'boost'
        version = '1.86.0'
        tag = 'boost-1.86.0'
        repository = 'boostorg/boost'
        filename = 'boost-1.86.0-b2-nodocs.tar.xz'
        sourceDirectory = 'boost-1.86.0'
        tarFlags = 'xJf'
        environmentName = 'PLEZYNG_BOOST_SOURCE_DIR'
        requiredFiles = @('boost/version.hpp', 'LICENSE_1_0.txt')
    },
    [pscustomobject]@{
        key = 'libtorrent'
        version = '2.0.11'
        tag = 'v2.0.11'
        repository = 'arvidn/libtorrent'
        filename = 'libtorrent-rasterbar-2.0.11.tar.gz'
        sourceDirectory = 'libtorrent-rasterbar-2.0.11'
        tarFlags = 'xzf'
        environmentName = 'PLEZYNG_LIBTORRENT_SOURCE_DIR'
        requiredFiles = @('CMakeLists.txt', 'include/libtorrent/version.hpp', 'COPYING')
    }
)

foreach ($spec in $archives) {
    $pin = $lock.PSObject.Properties[$spec.key].Value
    $url = [Uri][string]$pin.url
    $expectedPath = "/$($spec.repository)/releases/download/$($spec.tag)/$($spec.filename)"
    if (
        [string]$pin.version -ne $spec.version -or
        [string]$pin.filename -ne $spec.filename -or
        $url.Scheme -ne 'https' -or
        $url.Host -ne 'github.com' -or
        $url.Port -ne 443 -or
        $url.AbsolutePath -cne $expectedPath -or
        $url.Query -ne '' -or
        $url.Fragment -ne '' -or
        $url.UserInfo -ne '' -or
        [string]$pin.sha256 -notmatch '^[0-9a-fA-F]{64}$'
    ) {
        throw "The locked $($spec.key) release URL or checksum is invalid."
    }
}

if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP) -or
    [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
    throw 'RUNNER_TEMP and GITHUB_ENV are required for the private JIT build.'
}
$proxy = $env:HTTPS_PROXY
if ([string]::IsNullOrWhiteSpace($proxy)) {
    throw 'The private JIT HTTPS proxy is required to download the torrent dependencies.'
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

$cmakeCommand = Get-Command cmake.exe -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $cmakeCommand) {
    throw 'CMake is required to extract the pinned .tar.xz and .tar.gz archives.'
}

foreach ($spec in $archives) {
    $pin = $lock.PSObject.Properties[$spec.key].Value
    $archive = Join-Path $env:RUNNER_TEMP $spec.filename
    $extractRoot = Join-Path $env:RUNNER_TEMP "plezyng-$($spec.key)-$($spec.version)-source"
    $sourceDir = Join-Path $extractRoot $spec.sourceDirectory
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
        [string]$pin.url
    )
    & $curlPath @curlArguments
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        throw "Pinned $($spec.key) download failed with curl exit code $LASTEXITCODE."
    }

    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    if ($actualHash -ne ([string]$pin.sha256).ToLowerInvariant()) {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        throw "Pinned $($spec.key) SHA-256 mismatch: expected $($pin.sha256), got $actualHash."
    }

    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    Push-Location -LiteralPath $extractRoot
    try {
        & $cmakeCommand.Source -E tar $spec.tarFlags $archive
        if ($LASTEXITCODE -ne 0) {
            throw "Could not extract the verified $($spec.key) archive with CMake."
        }
    } finally {
        Pop-Location
    }

    foreach ($relativePath in $spec.requiredFiles) {
        $payload = Join-Path $sourceDir $relativePath
        if (-not (Test-Path -LiteralPath $payload -PathType Leaf)) {
            throw "The verified $($spec.key) archive is missing $relativePath."
        }
    }

    Add-Content -LiteralPath $env:GITHUB_ENV -Value "$($spec.environmentName)=$sourceDir" -Encoding utf8
}

Write-Host 'Downloaded, checksum-verified, and extracted the locked Boost and libtorrent sources.'
