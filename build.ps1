<#
.SYNOPSIS
    Builds Ideal-Video-Encoder.exe with ps2exe.
.DESCRIPTION
    64-bit (the embedded preview loads mpv.net's 64-bit libmpv), STA for WPF, no console window,
    and a per-monitor DPI-aware manifest. Installs the ps2exe module for the current user if needed.
#>
param([string]$OutDir = (Join-Path $PSScriptRoot 'dist'))
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name ps2exe)) { Install-Module -Name ps2exe -Scope CurrentUser -Force }
Import-Module ps2exe

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$exe = Join-Path $OutDir 'Ideal-Video-Encoder.exe'
Invoke-PS2EXE -InputFile (Join-Path $PSScriptRoot 'Ideal-Video-Encoder.ps1') -OutputFile $exe `
    -noConsole -STA -x64 -DPIAware -supportOS -iconFile (Join-Path $PSScriptRoot 'assets\app.ico') `
    -title 'Ideal Video Encoder' -product 'Ideal Video Encoder' -copyright 'Alex McDermott, GPL-3.0-or-later' -version '1.3.2'
Get-Item $exe | Select-Object FullName, Length
