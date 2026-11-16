# Local build and GitHub release for WPods (ajjs1ajjs/wpods).
# Usage:
#   pwsh -NoProfile -File .\scripts\Release-Local.ps1
#   pwsh -NoProfile -File .\scripts\Release-Local.ps1 -Version 0.3.3
#   pwsh -NoProfile -File .\scripts\Release-Local.ps1 -Bump minor -Force
#   pwsh -NoProfile -File .\scripts\Release-Local.ps1 -SkipPublish
param(
    [ValidateSet('patch', 'minor', 'major')][string]$Bump = 'patch',
    [ValidatePattern('^(\d+\.\d+\.\d+)?$')][string]$Version = '',
    [switch]$SkipPublish,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot
$RepoSlug = 'ajjs1ajjs/wpods'

function Fail([string]$Message) {
    Write-Host "::error::$Message"
    exit 1
}

function Invoke-Native([scriptblock]$Block) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Block
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

foreach ($tool in @('git', 'gh', 'dotnet', 'node', 'npm')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Fail "$tool not found in PATH"
    }
}
if ((Invoke-Native { gh auth status 2>&1 | Out-Null }) -ne 0) { Fail 'gh not authenticated (run gh auth login)' }

if (-not $SkipPublish) {
    if (git status --porcelain) { Fail 'working tree is dirty - commit or stash first' }
    if ((git branch --show-current) -ne 'main') { Fail 'release must run from main' }
    if ((Invoke-Native { git fetch origin main --tags }) -ne 0) { Fail 'git fetch origin failed' }
    $div = (git rev-list --left-right --count origin/main...HEAD).Trim() -split '\s+'
    if ($div.Count -ne 2 -or $div[0] -ne '0' -or $div[1] -ne '0') {
        Fail 'main must match origin/main before release'
    }
}

$buildPs1 = Join-Path $RepoRoot 'build.ps1'
$buildText = [IO.File]::ReadAllText($buildPs1)
if ($buildText -notmatch "(?m)^\`$Version = '(\d+\.\d+\.\d+)'") {
    Fail 'Could not parse $Version from build.ps1'
}
$currentVer = $Matches[1]

if ($Version) {
    $next = $Version
} else {
    $v = [version]$currentVer
    $next = switch ($Bump) {
        'major' { "$($v.Major + 1).0.0" }
        'minor' { "$($v.Major).$($v.Minor + 1).0" }
        default { "$($v.Major).$($v.Minor).$($v.Build + 1)" }
    }
}
$tag = "v$next"

if (-not $SkipPublish -and -not $Force) {
    $ans = Read-Host "Build and publish $RepoSlug $tag? [y/N]"
    if ($ans -notin @('y', 'Y', 'yes', 'YES')) { exit 0 }
}

if (-not $SkipPublish -and $next -ne $currentVer) {
    $updated = $buildText -replace "(?m)^(\`$Version = ')\d+\.\d+\.\d+(')", "`${1}$next`$2"
    [IO.File]::WriteAllText($buildPs1, $updated, [Text.UTF8Encoding]::new($false))
    git add build.ps1
    git commit -m "chore: bump version to $next"
    if ($LASTEXITCODE -ne 0) { Fail 'git commit failed' }
}

$nativeBin = Join-Path $RepoRoot '.build\native\bin'
$hasNative = Test-Path (Join-Path $nativeBin 'wpods_native.dll')
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
$shellExe = if ($pwshCmd) { $pwshCmd.Source } else { (Get-Process -Id $PID).Path }
$prevPref = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    if ($hasNative) {
        & $shellExe -NoProfile -File $buildPs1 -SkipNative
    } else {
        & $shellExe -NoProfile -File $buildPs1
    }
    $buildExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevPref
}
if ($buildExit -ne 0) { Fail "build.ps1 failed ($buildExit)" }

$setup = Join-Path $RepoRoot 'dist\WPods-Setup.exe'
if (-not (Test-Path $setup)) { Fail "Missing $setup" }
$hash = (Get-FileHash $setup -Algorithm SHA256).Hash.ToLowerInvariant()
$sumsPath = Join-Path $RepoRoot 'dist\SHA256SUMS.txt'
[IO.File]::WriteAllText($sumsPath, "$hash  WPods-Setup.exe`n", [Text.UTF8Encoding]::new($false))
Write-Host "SHA256: $hash  WPods-Setup.exe"

if ($SkipPublish) {
    Write-Host "SkipPublish set; local artifact ready at $setup"
    exit 0
}

if ((Invoke-Native { git tag -a $tag -m "WPods $tag (local build)" }) -ne 0) { Fail "git tag $tag failed" }
if ((Invoke-Native { git push origin main --tags }) -ne 0) { Fail 'git push failed' }

$notes = @"
Local build of WPods $tag (fork of FPNDev/wpods).

Includes MediaTek MT7921 combined USB Bluetooth adapter support (``WinUsb.cs``, ``RadioLink.cs``) and fork updater endpoint (``ajjs1ajjs/wpods``).
Unsigned local build (``SHA256SUMS.txt`` included).
"@
if ((Invoke-Native { gh release create $tag $setup $sumsPath -R $RepoSlug --title $tag --notes $notes }) -ne 0) {
    Fail "gh release create $tag failed"
}
Write-Host "Published $RepoSlug $tag"
