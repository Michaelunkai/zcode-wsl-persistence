# Take-Proof.ps1 — capture the full Windows virtual screen as GUI proof PNG.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$out = 'F:\study\Platforms\linux\wsl2\Applications\Desktop\Persistence\Engine\zcode-wsl-persistence\docs\screenshots\gui-proof.png'
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmp.Size)
$g.Dispose()
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "saved: $out ($($vs.Width)x$($vs.Height))"
