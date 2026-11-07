# Runs integration_test/ on this computer in a throwaway home folder, so the
# real ~/.gitconfig and ~/.gita are never touched. Windows only; on macOS or
# Linux set HOME and GIT_CONFIG_GLOBAL the same way and run
# `flutter test integration_test -d macos` (or linux).
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$home_ = Join-Path ([IO.Path]::GetTempPath()) ("gita-it-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $home_ | Out-Null
Set-Content -Path (Join-Path $home_ 'gita-test-home') -Value 'throwaway home for integration tests'
$gitconfig = Join-Path $home_ '.gitconfig'
Set-Content -Path $gitconfig -Encoding ascii -Value "[user]`n`tname = Me`n`temail = me@gmail.com`n[init]`n`tdefaultBranch = main"

# Keep Flutter's and Dart's own caches where they are.
if (-not $env:PUB_CACHE) { $env:PUB_CACHE = Join-Path $env:LOCALAPPDATA 'Pub\Cache' }
$env:USERPROFILE = $home_
$env:HOME = $home_
$env:HOMEDRIVE = Split-Path -Qualifier $home_
$env:HOMEPATH = Split-Path -NoQualifier $home_
$env:GIT_CONFIG_GLOBAL = $gitconfig
$env:GIT_CONFIG_NOSYSTEM = '1'
$env:GIT_TERMINAL_PROMPT = '0'

Write-Host "Test home: $home_"
Push-Location $repo
try {
  flutter test integration_test -d windows
  $code = $LASTEXITCODE
} finally {
  Pop-Location
}
if ($code -eq 0) { Remove-Item -Recurse -Force $home_ } else { Write-Host "Kept $home_ to look at." }
exit $code
