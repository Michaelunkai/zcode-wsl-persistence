# Capture-WslWindow.ps1 — screenshot of exactly the WSLg-hosted "ZCode (Ubuntu)" window.
# Uses PrintWindow (PW_RENDERFULLCONTENT) so window z-order/foreground never matter.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Cap {
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$proc = Get-Process msrdc -ErrorAction Stop | Where-Object { $_.MainWindowTitle -eq 'ZCode (Ubuntu)' } | Select-Object -First 1
if (-not $proc) { throw 'ZCode (Ubuntu) window (msrdc) not found' }
$hwnd = $proc.MainWindowHandle

$rect = New-Object Win32Cap+RECT
[Win32Cap]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
$w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top
Write-Output "window rect: $($rect.Left),$($rect.Top) ${w}x${h}"

$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
# nFlags = 2 (PW_RENDERFULLCONTENT) captures DWM-composed / GPU-rendered content
$ok = [Win32Cap]::PrintWindow($hwnd, $hdc, 2)
$g.ReleaseHdc($hdc)
$g.Dispose()
if (-not $ok) { $bmp.Dispose(); throw 'PrintWindow failed' }
$out = 'F:\study\Platforms\linux\wsl2\Applications\Desktop\Persistence\Engine\zcode-wsl-persistence\docs\screenshots\wsl-window-signed-in.png'
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "saved: $out"
