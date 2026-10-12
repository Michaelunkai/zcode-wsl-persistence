' zcode-wsl-silent-boot.vbs — ZERO-VISIBILITY Windows boot hook.
'
' Why this is flash-free:
'   * wscript.exe is a GUI-subsystem binary: launching it never creates a console.
'   * WshShell.Run(..., 0, False) starts wsl.exe with a fully hidden window style,
'     so no console window, no command prompt, no terminal ever appears — during
'     boot, logon, or manual invocation.
'   * The VBS returns immediately (non-blocking); WSL keeps booting in the
'     background and the ZCode GUI attaches itself onto the desktop via WSLg.
'
' Deployed by Install-SilentBoot.ps1 to %LOCALAPPDATA%\ZCodeWslBoot\
' and invoked by the hidden scheduled task "ZCodeWslSilentBoot" at logon.
Option Explicit
Dim shell, fso, logPath, logFile
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

logPath = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\ZCodeWslBoot\boot.log"
On Error Resume Next
Set logFile = fso.OpenTextFile(logPath, 8, True)
If Err.Number = 0 Then
  logFile.WriteLine Now() & " silent boot: starting WSL Ubuntu -> tmux zcode (hidden)"
  logFile.Close
End If
On Error GoTo 0

' intWindowStyle 0 = hidden; bWaitOnReturn False = fire-and-forget.
shell.Run "wsl.exe -d Ubuntu -u ubuntu --exec /bin/bash /home/ubuntu/zcode-wsl-migration/boot_zcode.sh", 0, False
