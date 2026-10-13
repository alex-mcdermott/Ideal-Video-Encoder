<#
.SYNOPSIS
    Builds dist\Ideal-Video-Encoder.exe (via ..\build.ps1) and then dist\Ideal-Video-Encoder-Setup-<version>.exe with Inno Setup 6.
.DESCRIPTION
    The version is read from build.ps1. Install Inno Setup first if needed:
        winget install --id JRSoftware.InnoSetup -e --scope user
#>
# SPDX-License-Identifier: GPL-3.0-or-later
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

& (Join-Path $root 'build.ps1') | Out-Null

$version = [regex]::Match((Get-Content (Join-Path $root 'build.ps1') -Raw), "-version '([^']+)'").Groups[1].Value
if (-not $version) { throw 'Could not read -version from build.ps1' }

$iscc = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 not found. Install it with: winget install --id JRSoftware.InnoSetup -e --scope user' }

& $iscc /Q "/DAppVersion=$version" (Join-Path $PSScriptRoot 'IdealVideoEncoder.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
Get-Item (Join-Path $root "dist\Ideal-Video-Encoder-Setup-$version.exe") | Select-Object FullName, Length
