# Parse-Gate.ps1 — PS 5.1 syntax gate for every PowerShell file in windows/.
$ErrorActionPreference = 'Stop'
$dir = 'F:\study\Platforms\linux\wsl2\Applications\Desktop\Persistence\Engine\zcode-wsl-persistence\windows'
$fail = 0
Get-ChildItem -Path $dir -Filter *.ps1 | ForEach-Object {
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs) | Out-Null
    if ($errs.Count) {
        Write-Output "PARSE FAIL: $($_.Name)"
        $errs | ForEach-Object { Write-Output "  $($_.Message)" }
        $fail++
    } else {
        Write-Output "PARSE OK: $($_.Name)"
    }
}
if ($fail) { exit 1 } else { Write-Output 'ALL PARSE GATES PASSED'; exit 0 }
