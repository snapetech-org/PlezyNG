$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$expectedCommit = '6655482ec06e547f90abf8ae7590466f4415978d'
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP) -or
    [string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE) -or
    $env:CMAKE_GENERATOR -ne 'Visual Studio 18 2026' -or
    $env:CMAKE_GENERATOR_TOOLSET -ne 'ClangCL') {
  throw 'The hybrid Windows ARM64 Flutter patch environment is incomplete.'
}

$runnerTempRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$flutterRoot = [IO.Path]::GetFullPath((Join-Path $runnerTempRoot 'flutter'))
if (-not $flutterRoot.StartsWith($runnerTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Refusing to patch Flutter outside RUNNER_TEMP: $flutterRoot"
}
if (-not (Test-Path -LiteralPath (Join-Path $flutterRoot '.git') -PathType Container)) {
  throw "Pinned Flutter checkout was not found at $flutterRoot"
}

$git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
$actualCommit = (& $git.Source -C $flutterRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $expectedCommit) {
  throw "Refusing to patch Flutter $actualCommit; expected $expectedCommit"
}

$patchPath = Join-Path $env:GITHUB_WORKSPACE 'windows\tool\flutter-3.47.1-windows-arm64-clangcl.patch'
$sourcePath = Join-Path $flutterRoot 'packages/flutter_tools/lib/src/windows/build_windows.dart'
if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
  throw 'The pinned Flutter tool patch or target source file is missing.'
}

& $git.Source -C $flutterRoot apply --check $patchPath
if ($LASTEXITCODE -ne 0) {
  throw 'The pinned Flutter ARM64 CMake patch does not apply cleanly.'
}
& $git.Source -C $flutterRoot apply $patchPath
if ($LASTEXITCODE -ne 0) {
  throw 'Unable to patch the pinned Flutter ARM64 CMake invocation.'
}

$source = [IO.File]::ReadAllText($sourcePath)
if (-not $source.Contains("if (targetPlatform == TargetPlatform.windows_arm64) ...<String>[")) {
  throw 'The patched Flutter CMake invocation does not pass the ARM64 ClangCL toolset.'
}

$cacheRoot = Join-Path $flutterRoot 'bin/cache'
$dart = Join-Path $cacheRoot 'dart-sdk/bin/dart.exe'
$packageConfig = Join-Path $flutterRoot 'packages/flutter_tools/.dart_tool/package_config.json'
$toolEntrypoint = Join-Path $flutterRoot 'packages/flutter_tools/bin/flutter_tools.dart'
$snapshot = Join-Path $cacheRoot 'flutter_tools.snapshot'
$stamp = Join-Path $cacheRoot 'flutter_tools.stamp'
if (-not (Test-Path -LiteralPath $dart -PathType Leaf) -or
    -not (Test-Path -LiteralPath $packageConfig -PathType Leaf) -or
    -not (Test-Path -LiteralPath $toolEntrypoint -PathType Leaf)) {
  throw 'The bootstrapped Flutter toolchain is incomplete.'
}
if (-not [string]::IsNullOrWhiteSpace($env:FLUTTER_TOOL_ARGS)) {
  throw 'Unexpected FLUTTER_TOOL_ARGS; the pinned Flutter tool cache key is no longer default.'
}

# Flutter's normal cache key is the SDK commit, so force a new snapshot after this source-only patch.
foreach ($cachePath in @(
    $snapshot,
    $stamp
  )) {
  if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
    Remove-Item -LiteralPath $cachePath -Force
  }
}

& $dart --verbosity=error "--snapshot=$snapshot" --snapshot-kind=app-jit "--packages=$packageConfig" --no-enable-mirrors $toolEntrypoint
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $snapshot -PathType Leaf)) {
  throw 'The patched Flutter tool failed to rebuild.'
}
Set-Content -LiteralPath $stamp -Value "${expectedCommit}:" -Encoding ascii

& (Join-Path $flutterRoot 'bin/flutter.bat') --version
if ($LASTEXITCODE -ne 0) {
  throw 'The rebuilt Flutter tool snapshot did not start successfully.'
}

Write-Host "Patched Flutter $expectedCommit to pass -T ClangCL for Windows ARM64."
