<#
.SYNOPSIS
    Installs what Ideal Video Encoder needs, if it is missing: FFmpeg (full build), ExifTool and mpv.net (all required).
.DESCRIPTION
    Safe to run repeatedly: tools that are already on PATH and complete are left alone.
    Uses winget (per-user, no admin) when available; otherwise downloads the official builds:
      FFmpeg   - gyan.dev full build (GitHub: GyanD/codexffmpeg)
      ExifTool - exiftool.org Windows package
      mpv.net  - portable build (GitHub: mpvnet-player/mpv.net)
    into %LOCALAPPDATA%\Programs and adds FFmpeg/ExifTool to the user PATH.
    Exit code 0 = everything required is available, 1 = something required is still missing.
.PARAMETER CheckOnly
    Report what is present or missing; install nothing.
.PARAMETER NoWinget
    Skip winget and use the direct downloads.
.PARAMETER Force
    Install even if a tool is already present (testing).
.PARAMETER ToolsRoot
    Where direct downloads go (default %LOCALAPPDATA%\Programs\Ideal Video Encoder\tools).
.PARAMETER MpvDir
    Where the portable mpv.net goes (default %LOCALAPPDATA%\Programs\mpv.net, one of the places the app looks).
.PARAMETER NoPathChange
    Don't modify the user PATH (testing).
.PARAMETER LogPath
    Also write the output to this file.
#>
# SPDX-License-Identifier: GPL-3.0-or-later
param(
    [switch]$CheckOnly,
    [switch]$NoWinget,
    [switch]$Force,
    [string]$ToolsRoot = (Join-Path $env:LOCALAPPDATA 'Programs\Ideal Video Encoder\tools'),
    [string]$MpvDir = (Join-Path $env:LOCALAPPDATA 'Programs\mpv.net'),
    [switch]$NoPathChange,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is far faster without the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Say([string]$text, [string]$color = 'Gray') {
    Write-Host $text -ForegroundColor $color
    if ($LogPath) { Add-Content -LiteralPath $LogPath -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $text) }
}

# PATH as a freshly started process would see it (machine + user), so installs made earlier in this run count
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Find-Tool([string]$name) {
    $c = Get-Command "$name.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}

function Find-MpvNet {
    foreach ($d in @($MpvDir, (Join-Path $env:ProgramFiles 'mpv.net'), (Join-Path $env:LOCALAPPDATA 'Programs\mpv.net'))) {
        if ($d -and (Test-Path -LiteralPath (Join-Path $d 'libmpv-2.dll'))) { return $d }
    }
    return $null
}

# Encoders/filters the app relies on
function Get-FfmpegGaps([string]$ffmpeg) {
    $enc = (& $ffmpeg -hide_banner -encoders 2>&1) -join "`n"
    $flt = (& $ffmpeg -hide_banner -filters 2>&1) -join "`n"
    $gaps = @()
    foreach ($e in 'libx265', 'libsvtav1') { if ($enc -notmatch "\b$e\b") { $gaps += $e } }
    foreach ($f in 'zscale', 'lut3d', 'lutyuv', 'libvmaf') { if ($flt -notmatch "\b$f\b") { $gaps += $f } }
    return , $gaps
}

function Add-UserPath([string]$dir) {
    if ($NoPathChange) { Say "  (not adding $dir to PATH: -NoPathChange)"; $env:Path = "$dir;$env:Path"; return }
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($user -split ';' | Where-Object { $_ })
    if ($parts -notcontains $dir) {
        [Environment]::SetEnvironmentVariable('Path', (@($dir) + $parts) -join ';', 'User')
        Say "  Added to your PATH: $dir"
    }
    Update-SessionPath
}

# Tell Explorer (and apps it starts) that the environment changed
function Publish-EnvironmentChange {
    if ($NoPathChange) { return }
    if (-not ('IVE.Env' -as [type])) {
        Add-Type -Namespace IVE -Name Env -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $r = [UIntPtr]::Zero
    [void][IVE.Env]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r)
}

function Invoke-Winget([string]$id) {
    Say "  winget install $id (per-user)..."
    $out = & winget install --id $id -e --scope user --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
    $code = $LASTEXITCODE
    if ($LogPath) { Add-Content -LiteralPath $LogPath -Value ($out | Out-String) }
    # 0 = installed; -1978335189 (0x8A15002B) = already installed / no newer version
    if ($code -ne 0 -and $code -ne -1978335189) { Say "  winget exited with $code" 'Yellow'; return $false }
    Update-SessionPath
    return $true
}

function Get-GitHubAsset([string]$repo, [string]$pattern) {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'IdealVideoEncoder-Setup' }
    $a = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $a) { throw "No asset matching '$pattern' in the latest $repo release" }
    return $a.browser_download_url
}

function Save-Download([string]$url, [string]$name) {
    if (-not $name) { $name = [IO.Path]::GetFileName(([uri]$url).AbsolutePath) }
    $file = Join-Path ([IO.Path]::GetTempPath()) ("ive-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '-' + $name)
    Say "  Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -Headers @{ 'User-Agent' = 'IdealVideoEncoder-Setup' }
    return $file
}

function Install-FfmpegDirect {
    $zip = Save-Download (Get-GitHubAsset 'GyanD/codexffmpeg' '^ffmpeg-[\d\.]+-full_build\.zip$')
    $dest = Join-Path $ToolsRoot 'ffmpeg'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
    Remove-Item $zip -Force
    $bin = Get-ChildItem $dest -Recurse -Filter ffmpeg.exe | Select-Object -First 1
    if (-not $bin) { throw 'ffmpeg.exe not found in the download' }
    Add-UserPath $bin.DirectoryName
}

function Install-ExifToolDirect {
    # The homepage links the current Windows package (currently hosted on SourceForge)
    $ver = (Invoke-WebRequest -Uri 'https://exiftool.org/ver.txt' -UseBasicParsing).Content.Trim()
    $page = (Invoke-WebRequest -Uri 'https://exiftool.org/' -UseBasicParsing).Content
    $m = [regex]::Match($page, 'href="([^"]*exiftool-[\d\.]+_64\.zip[^"]*)"')
    $url = if ($m.Success) { $m.Groups[1].Value } else { "https://sourceforge.net/projects/exiftool/files/exiftool-${ver}_64.zip/download" }
    if ($url -notmatch '^https?://') { $url = "https://exiftool.org/$url" }
    $zip = Save-Download $url "exiftool-${ver}_64.zip"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ive-exiftool-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    Remove-Item $zip -Force
    $exe = Get-ChildItem $tmp -Recurse -Filter 'exiftool*.exe' | Select-Object -First 1
    if (-not $exe) { throw 'exiftool executable not found in the download' }
    $dest = Join-Path $ToolsRoot 'exiftool'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    # The package ships "exiftool(-k).exe" (pauses at exit) next to an exiftool_files folder; the app needs exiftool.exe
    Copy-Item -LiteralPath $exe.FullName -Destination (Join-Path $dest 'exiftool.exe')
    $files = Join-Path $exe.DirectoryName 'exiftool_files'
    if (Test-Path $files) { Copy-Item -LiteralPath $files -Destination $dest -Recurse }
    Remove-Item $tmp -Recurse -Force
    Add-UserPath $dest
}

function Install-MpvDirect {
    $zip = Save-Download (Get-GitHubAsset 'mpvnet-player/mpv.net' 'portable-x64\.zip$')
    if (Test-Path $MpvDir) { Remove-Item $MpvDir -Recurse -Force }
    New-Item -ItemType Directory -Path $MpvDir -Force | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $MpvDir -Force
    Remove-Item $zip -Force
    # Flatten if the zip had a top-level folder
    if (-not (Test-Path (Join-Path $MpvDir 'libmpv-2.dll'))) {
        $inner = Get-ChildItem $MpvDir -Recurse -Filter 'libmpv-2.dll' | Select-Object -First 1
        if ($inner) { Get-ChildItem $inner.DirectoryName | Move-Item -Destination $MpvDir -Force }
    }
}

# ---------------------------------------------------------------------------------------------
if ($LogPath) { New-Item -ItemType File -Path $LogPath -Force | Out-Null }
Say 'Ideal Video Encoder - prerequisites' 'Cyan'
Update-SessionPath
$useWinget = -not $NoWinget -and [bool](Get-Command winget -ErrorAction SilentlyContinue)
if (-not $CheckOnly) { Say ("Install method: " + $(if ($useWinget) { 'winget (per-user)' } else { 'direct download' })) }
$failed = @()

# FFmpeg + ffprobe (full build)
$ff = Find-Tool 'ffmpeg'; $fp = Find-Tool 'ffprobe'
$gaps = if ($ff) { Get-FfmpegGaps $ff } else { @('not installed') }
if ($ff -and $fp -and $gaps.Count -eq 0 -and -not $Force) {
    Say "[ok] FFmpeg: $ff" 'Green'
} elseif ($CheckOnly) {
    Say ("[missing] FFmpeg: " + $(if ($ff) { "$ff lacks $($gaps -join ', ')" } else { 'not found' })) 'Yellow'; $failed += 'FFmpeg'
} else {
    if ($ff -and $gaps.Count) { Say "FFmpeg at $ff lacks: $($gaps -join ', '). Installing the full build." 'Yellow' } else { Say 'Installing FFmpeg (full build)...' }
    try {
        if (-not ($useWinget -and (Invoke-Winget 'Gyan.FFmpeg'))) { Install-FfmpegDirect }
    } catch { Say "  FFmpeg install failed: $($_.Exception.Message)" 'Red' }
    $ff = Find-Tool 'ffmpeg'; $fp = Find-Tool 'ffprobe'
    $gaps = if ($ff) { Get-FfmpegGaps $ff } else { @('not installed') }
    if ($ff -and $fp -and $gaps.Count -eq 0) { Say "[ok] FFmpeg: $ff" 'Green' }
    else {
        Say ("[problem] FFmpeg: " + $(if ($ff) { "$ff still lacks $($gaps -join ', '). An older FFmpeg is probably earlier on PATH; remove it or move the new one first." } else { 'still not found' })) 'Red'
        $failed += 'FFmpeg'
    }
}

# ExifTool
$et = Find-Tool 'exiftool'
if ($et -and -not $Force) {
    Say "[ok] ExifTool: $et" 'Green'
} elseif ($CheckOnly) {
    Say '[missing] ExifTool: not found' 'Yellow'; $failed += 'ExifTool'
} else {
    Say 'Installing ExifTool...'
    try {
        if (-not ($useWinget -and (Invoke-Winget 'OliverBetz.ExifTool'))) { Install-ExifToolDirect }
    } catch { Say "  ExifTool install failed: $($_.Exception.Message)" 'Red' }
    $et = Find-Tool 'exiftool'
    if ($et) { Say "[ok] ExifTool: $et" 'Green' } else { Say '[problem] ExifTool: still not found' 'Red'; $failed += 'ExifTool' }
}

# mpv.net (the app's preview runs on its libmpv)
$mpv = Find-MpvNet
if ($mpv -and -not $Force) {
    Say "[ok] mpv.net: $mpv" 'Green'
} elseif ($CheckOnly) {
    Say '[missing] mpv.net: not found' 'Yellow'; $failed += 'mpv.net'
} else {
    Say 'Installing mpv.net...'
    try {
        if ($useWinget -and -not $Force) { [void](Invoke-Winget 'mpv.net') }
        # winget can install it somewhere the app doesn't look; the portable build goes where it does
        if (-not (Find-MpvNet) -or $Force) { Install-MpvDirect }
    } catch { Say "  mpv.net install failed: $($_.Exception.Message)" 'Red' }
    $mpv = Find-MpvNet
    if ($mpv) { Say "[ok] mpv.net: $mpv" 'Green' } else { Say '[problem] mpv.net: still not found' 'Red'; $failed += 'mpv.net' }
}

if (-not $CheckOnly) { Publish-EnvironmentChange }
if ($failed.Count) {
    Say ("Still missing: " + ($failed -join ', ')) 'Red'
    exit 1
}
Say 'All required tools are available.' 'Green'
exit 0
