# Uninstall-SilentBoot.ps1 — removes the Windows-side silent boot integration only.
# NEVER touches anything inside WSL, never touches C:\Users\Admin\.zcode.
#Requires -Version 5.1
$ErrorActionPreference = 'SilentlyContinue'
Unregister-ScheduledTask -TaskName 'ZCodeWslSilentBoot' -Confirm:$false
$BootDir = Join-Path $env:LOCALAPPDATA 'ZCodeWslBoot'
if (Test-Path $BootDir) { Remove-Item $BootDir -Recurse -Force }
Write-Output "[ok] Windows-side silent boot removed (scheduled task + ${BootDir})"
