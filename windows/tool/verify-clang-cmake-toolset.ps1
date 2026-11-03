$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP) -or
    [string]::IsNullOrWhiteSpace($env:CMAKE_GENERATOR) -or
    [string]::IsNullOrWhiteSpace($env:CMAKE_GENERATOR_TOOLSET) -or
    $env:CMAKE_GENERATOR_TOOLSET -ne 'ClangCL' -or
    $env:CC -ne 'clang-cl' -or
    $env:CXX -ne 'clang-cl') {
  throw 'The hybrid Windows ARM64 ClangCL environment is incomplete.'
}

$runId = if ($env:GITHUB_RUN_ID -match '^\d+$') { $env:GITHUB_RUN_ID } else { throw 'GITHUB_RUN_ID is invalid.' }
$attempt = if ($env:GITHUB_RUN_ATTEMPT -match '^\d+$') { $env:GITHUB_RUN_ATTEMPT } else { throw 'GITHUB_RUN_ATTEMPT is invalid.' }
$probeRoot = Join-Path $env:RUNNER_TEMP "plezyng-clangcl-probe-$runId-$attempt"
$sourceRoot = Join-Path $probeRoot 'source'
$buildRoot = Join-Path $probeRoot 'build'

if (Test-Path -LiteralPath $probeRoot) {
  throw "Refusing to reuse existing CMake probe directory: $probeRoot"
}

try {
  New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'c-language') -Force | Out-Null
  @'
cmake_minimum_required(VERSION 3.21)
project(plezyng_clangcl_probe LANGUAGES CXX)
add_subdirectory(c-language)
'@ | Set-Content -LiteralPath (Join-Path $sourceRoot 'CMakeLists.txt') -Encoding ascii

  @'
enable_language(C)
file(WRITE "${CMAKE_BINARY_DIR}/compiler-identities.txt" "${CMAKE_C_COMPILER_ID};${CMAKE_CXX_COMPILER_ID};${CMAKE_VS_PLATFORM_TOOLSET}")
'@ | Set-Content -LiteralPath (Join-Path $sourceRoot 'c-language/CMakeLists.txt') -Encoding ascii

  $cmakeCommand = Get-Command cmake -CommandType Application -ErrorAction Stop
  & $cmakeCommand.Source -S $sourceRoot -B $buildRoot -G $env:CMAKE_GENERATOR -T ClangCL -A ARM64
  if ($LASTEXITCODE -ne 0) {
    throw "CMake could not configure the hybrid Windows ARM64 ClangCL probe (exit $LASTEXITCODE)."
  }

  $identitiesPath = Join-Path $buildRoot 'compiler-identities.txt'
  if (-not (Test-Path -LiteralPath $identitiesPath -PathType Leaf)) {
    throw 'CMake did not write its compiler identity report.'
  }
  $identities = (Get-Content -LiteralPath $identitiesPath -Raw).Trim()
  if ($identities -ne 'Clang;Clang;ClangCL') {
    Get-Content -LiteralPath (Join-Path $buildRoot 'CMakeCache.txt') |
      Select-String 'CMAKE_(C|CXX)_COMPILER(:|_ID:)|CMAKE_VS_PLATFORM_TOOLSET:' |
      ForEach-Object { Write-Host $_.Line }
    throw "Expected Clang;Clang;ClangCL, got '$identities'."
  }

  Write-Host "Verified native ARM64 CMake compilers and toolset: $identities"
} finally {
  if (Test-Path -LiteralPath $probeRoot -PathType Container) {
    $runnerTempRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolvedProbeRoot = [IO.Path]::GetFullPath($probeRoot)
    if (-not $resolvedProbeRoot.StartsWith($runnerTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to remove CMake probe outside RUNNER_TEMP: $resolvedProbeRoot"
    }
    Remove-Item -LiteralPath $resolvedProbeRoot -Recurse -Force
  }
}
