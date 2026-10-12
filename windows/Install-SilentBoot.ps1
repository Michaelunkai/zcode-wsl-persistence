# Install-SilentBoot.ps1 — registers the ZERO-POPUP Windows logon boot integration
# for the ZCode WSL2 GUI persistence engine.
#
# What it installs:
#   %LOCALAPPDATA%\ZCodeWslBoot\zcode-wsl-silent-boot.vbs   (flash-free launcher)
#   %LOCALAPPDATA%\ZCodeWslBoot\zcode-wsl-boot.ps1          (hidden PS alternative)
#   Scheduled task "ZCodeWslSilentBoot" — At logon, runs wscript.exe (GUI subsystem,
#   hidden window style 0). No console window can ever appear at boot or logon.
#
# Usage (Windows PowerShell 5.1):
#   powershell -NoProfile -ExecutionPolicy Bypass -File Install-SilentBoot.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File Install-SilentBoot.ps1 -Uninstall
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$TaskName  = 'ZCodeWslSilentBoot'
$BootDir   = Join-Path $env:LOCALAPPDATA 'ZCodeWslBoot'
$VbsDest   = Join-Path $BootDir  'zcode-wsl-silent-boot.vbs'
$Ps1Dest   = Join-Path $BootDir  'zcode-wsl-boot.ps1'
$SrcDir    = $PSScriptRoot

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $BootDir) { Remove-Item $BootDir -Recurse -Force }
    Write-Output "[ok] removed scheduled task '${TaskName}' and ${BootDir}"
    return
}

# --- deploy boot assets -----------------------------------------------------
New-Item -ItemType Directory -Path $BootDir -Force | Out-Null
Copy-Item (Join-Path $SrcDir 'zcode-wsl-silent-boot.vbs') $VbsDest -Force
Copy-Item (Join-Path $SrcDir 'zcode-wsl-boot.ps1')         $Ps1Dest -Force
Write-Output "[ok] boot assets -> ${BootDir}"

# --- register the hidden logon task -----------------------------------------
$action     = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $VbsDest)
$trigger    = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings   = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 300)
$principal  = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null

# --- verify ------------------------------------------------------------------
$t = Get-ScheduledTask -TaskName $TaskName
if ($t.State -ne 'Disabled') {
    Write-Output "[ok] scheduled task '${TaskName}' registered (State=$($t.State), trigger=AtLogOn, hidden via wscript + window style 0)"
} else {
    throw "task registered but disabled"
}
Write-Output "[ok] test-run: $(Start-ScheduledTask -TaskName $TaskName; 'started')"
Write-Output '[info] verify inside WSL with: tmux ls  (session "zcode" should appear)'
