# zcode-wsl-boot.ps1 — hidden PowerShell boot body (alternative to the VBS hop).
# Always launched with -WindowStyle Hidden from a GUI-subsystem parent (wscript),
# so no console window can ever flash on the Windows desktop.
#Requires -Version 5.1
$ErrorActionPreference = 'SilentlyContinue'

$logDir = Join-Path $env:LOCALAPPDATA 'ZCodeWslBoot'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
"$((Get-Date).ToString('s')) ps-boot: starting WSL Ubuntu -> tmux zcode (hidden)" |
    Out-File -FilePath (Join-Path $logDir 'boot.log') -Append -Encoding utf8

# Start the distro (boots systemd -> cron @reboot hook) and run the idempotent
# boot script directly. CreationFlags 0x08000000 (CREATE_NO_WINDOW) is belt and
# braces so wsl.exe can never surface a console in any launch context.
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = "$env:WINDIR\System32\wsl.exe"
$psi.Arguments              = '-d Ubuntu -u ubuntu --exec /bin/bash /home/ubuntu/zcode-wsl-migration/boot_zcode.sh'
$psi.WindowStyle            = 'Hidden'
$psi.CreateNoWindow         = $true
$psi.UseShellExecute        = $false
[System.Diagnostics.Process]::Start($psi) | Out-Null
