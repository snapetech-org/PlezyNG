#requires -Version 7.2
<# Prepare/check Steam's Windows x64/ARM64 SDKs on an idle private build agent.
   -Install provisions a new, separate VS instance; it never modifies a discovered
   installation. Default operation is read-only apart from the JSON report.
   Existing NuGet/packaging setup remains in prepare-build-toolchain.ps1. #>
[CmdletBinding()]
param(
    [switch]$Install,
    [string]$InstallRoot,
    [ValidateSet('x64', 'arm64')][string[]]$Architectures = @('x64', 'arm64'),
    [Parameter(Mandatory)][string]$Report
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    throw 'Windows SDK preparation must run on a Windows build agent.'
}
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$Report = [IO.Path]::GetFullPath($Report)
function Write-SdkReport($Value) {
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Report)) -Force | Out-Null
    $temporary = "$Report.$([guid]::NewGuid().ToString('N')).pending"
    try {
        $Value | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
        Move-Item -LiteralPath $temporary -Destination $Report -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}
Write-SdkReport ([ordered]@{ schema = 1; status = 'running'; sdkChecked = $false; applicationBuilt = $false })
try {
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'steam-sdk.lock.json') -Raw | ConvertFrom-Json
if ($lock.schema -ne 1 -or $lock.bootstrapper.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
    $lock.windowsSdk -cnotmatch '^10\.0\.\d+\.0$' -or
    ([uri]$lock.bootstrapper.url).Scheme -cne 'https' -or
    ([uri]$lock.bootstrapper.url).Host -cne 'download.visualstudio.microsoft.com') { throw 'Invalid Steam SDK lock.' }
if ($Install) {
    if ([string]::IsNullOrWhiteSpace($InstallRoot) -or -not [IO.Path]::IsPathFullyQualified($InstallRoot) -or
        $InstallRoot.IndexOfAny([char[]]"`r`n`"") -ge 0) { throw '-Install requires an absolute -InstallRoot.' }
    $InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
    $instance = Join-Path $InstallRoot 'VisualStudio'
    if (Test-Path -LiteralPath $instance) {
        throw 'The requested Visual Studio directory already exists. Check it without -Install or use a fresh root.'
    }
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    $bootstrapper = Join-Path $InstallRoot 'vs_BuildTools.exe'
    if (-not (Test-Path -LiteralPath $bootstrapper -PathType Leaf)) {
        $pending = "$bootstrapper.partial-$([guid]::NewGuid().ToString('N')).exe"
        Invoke-WebRequest -Uri $lock.bootstrapper.url -OutFile $pending -MaximumRedirection 3 -TimeoutSec 180
        if ((Get-FileHash -LiteralPath $pending -Algorithm SHA256).Hash.ToLowerInvariant() -cne $lock.bootstrapper.sha256) {
            throw 'Visual Studio bootstrapper checksum mismatch; file was not executed.'
        }
        Move-Item -LiteralPath $pending -Destination $bootstrapper
    }
    if ((Get-FileHash -LiteralPath $bootstrapper -Algorithm SHA256).Hash.ToLowerInvariant() -cne $lock.bootstrapper.sha256) {
        throw 'Cached Visual Studio bootstrapper checksum mismatch.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $bootstrapper
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne $lock.bootstrapper.publisher) {
        throw 'Visual Studio bootstrapper must have a valid Microsoft signature.'
    }
    $config = Join-Path $PSScriptRoot 'steam-sdk.vsconfig'
    $arguments = '--quiet --wait --norestart --installPath "{0}" --config "{1}"' -f $instance, $config
    $process = Start-Process -FilePath $bootstrapper -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -eq 3010) { throw 'SDK installation requires a reboot of this idle agent before verification.' }
    if ($process.ExitCode -ne 0) { throw "Visual Studio installation failed: $($process.ExitCode)." }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'Visual Studio Installer/vswhere is missing; provision with -Install.' }
$components = @('Microsoft.VisualStudio.Component.VC.Tools.x86.x64', 'Microsoft.VisualStudio.Component.VC.CMake.Project')
if ('arm64' -in $Architectures) { $components += 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' }
$raw = & $vswhere -products '*' -version $lock.visualStudioRange -requires $components -format json -utf8
if ($LASTEXITCODE -ne 0) { throw 'Visual Studio discovery failed.' }
$instances = @($raw | ConvertFrom-Json)
if ($InstallRoot) {
    $expectedInstance = [IO.Path]::GetFullPath((Join-Path $InstallRoot 'VisualStudio'))
    $instances = @($instances | Where-Object { $_.installationPath -ieq $expectedInstance })
}
if ($instances.Count -eq 0) { throw 'No supported Visual Studio 2022 instance contains the requested x64/ARM64 C++ tools.' }
$selected = $instances | Sort-Object { [version]$_.installationVersion } -Descending | Select-Object -First 1
$versionFile = Join-Path $selected.installationPath 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt'
$vcVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim()
if ($vcVersion -notmatch '^14\.\d+\.\d+$') { throw 'Unexpected MSVC toolset metadata.' }
$vc = Join-Path $selected.installationPath "VC/Tools/MSVC/$vcVersion"
$cmake = Join-Path $selected.installationPath 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
if (-not (Test-Path -LiteralPath $cmake -PathType Leaf)) { throw 'Visual Studio CMake is missing.' }
$cmakeVersion = (& $cmake --version | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or $cmakeVersion -notmatch '^cmake version (\d+)\.(\d+)' -or
    [version]"$($Matches[1]).$($Matches[2])" -lt [version]'3.22') { throw 'CMake 3.22+ is required.' }
$kits = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -Name KitsRoot10
$sdk = $lock.windowsSdk
foreach ($header in @('um/mfapi.h', 'um/audioclient.h', 'um/mmdeviceapi.h', 'um/xaudio2.h', 'shared/dxgi1_6.h', 'ucrt/stdio.h')) {
    if (-not (Test-Path -LiteralPath (Join-Path $kits "Include/$sdk/$header") -PathType Leaf)) {
        throw "Required Windows SDK header missing: $header ($sdk)."
    }
}
$compilers = [ordered]@{}
foreach ($arch in $Architectures) {
    $hostArch = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'Hostarm64' } else { 'Hostx64' }
    $compiler = Join-Path $vc "bin/$hostArch/$arch/cl.exe"
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw "Missing native MSVC compiler for $hostArch/$arch." }
    foreach ($library in @('mfplat.lib', 'mfuuid.lib', 'xaudio2_8.lib', 'ole32.lib', 'ksuser.lib', 'dxgi.lib', 'bcrypt.lib')) {
        if (-not (Test-Path -LiteralPath (Join-Path $kits "Lib/$sdk/um/$arch/$library") -PathType Leaf)) {
            throw "Required Windows SDK library missing: $arch/$library."
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $vc "lib/$arch/libcpmt.lib") -PathType Leaf)) { throw "Missing MSVC C++ runtime for $arch." }
    if (-not (Test-Path -LiteralPath (Join-Path $kits "Lib/$sdk/ucrt/$arch/ucrt.lib") -PathType Leaf)) { throw "Missing Universal CRT for $arch." }
    if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $compiler) 'link.exe') -PathType Leaf)) { throw "Missing MSVC linker for $arch." }
    $compilers[$arch] = $compiler
}
$sdkHost = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'x64' }
foreach ($tool in @('rc.exe', 'mt.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $kits "bin/$sdk/$sdkHost/$tool") -PathType Leaf)) { throw "Missing Windows SDK host tool $tool." }
}
$commit = (& git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not identify the source commit.' }
$dirty = [bool](& git -C $root status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the source worktree.' }
$result = [ordered]@{ schema = 1; status = 'passed'; commit = $commit; dirty = $dirty; visualStudio = $selected.installationVersion;
    visualStudioPath = $selected.installationPath; msvc = $vcVersion; windowsSdk = $sdk; sdkRoot = $kits;
    compilers = $compilers; cmake = $cmake; cmakeVersion = $cmakeVersion; sdkChecked = $true; applicationBuilt = $false }
Write-SdkReport $result
Write-Host "Verified Windows SDK $sdk and MSVC $vcVersion for $($Architectures -join ', '): $Report"
} catch {
    Write-SdkReport ([ordered]@{ schema = 1; status = 'failed'; sdkChecked = $false; applicationBuilt = $false; error = $_.Exception.Message })
    throw
}
