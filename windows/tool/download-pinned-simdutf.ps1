[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$lockPath = Join-Path $PSScriptRoot '..\..\linux\packaging\native-inputs.json'
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$simdutf = $lock.inputs.simdutf
$url = [Uri][string]$simdutf.url
$version = [string]$simdutf.version
$expectedHash = [string]$simdutf.sha256
$releasePathPattern = (
    '^/simdutf/simdutf/releases/download/v{0}/singleheader\.zip$' -f
    [regex]::Escape($version)
)
if (
    $url.Scheme -ne 'https' -or
    $url.Host -ne 'github.com' -or
    $url.Port -ne 443 -or
    $url.AbsolutePath -notmatch $releasePathPattern -or
    $url.Query -ne '' -or
    $url.Fragment -ne '' -or
    $url.UserInfo -ne '' -or
    $expectedHash -notmatch '^[0-9a-fA-F]{64}$'
) {
    throw 'The locked simdutf release URL or checksum is invalid.'
}

$proxy = $env:HTTPS_PROXY
if ([string]::IsNullOrWhiteSpace($proxy)) {
    throw 'The private JIT HTTPS proxy is required to download simdutf.'
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

$archive = Join-Path $env:RUNNER_TEMP "plezyng-simdutf-$version.zip"
Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
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
    throw "Pinned simdutf download failed with curl exit code $LASTEXITCODE."
}

$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    throw "Pinned simdutf SHA-256 mismatch: expected $expectedHash, got $actualHash."
}

Add-Content -LiteralPath $env:GITHUB_ENV -Value "PLEZYNG_SIMDUTF_ARCHIVE_PATH=$archive" -Encoding utf8
Write-Host "Downloaded and verified the locked simdutf $version archive."
