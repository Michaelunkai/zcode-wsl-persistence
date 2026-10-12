# Inspect-CredShape.ps1 — Windows credentials.json value SHAPES (no secrets).
$j = Get-Content 'C:\Users\Admin\.zcode\v2\credentials.json' -Raw | ConvertFrom-Json
foreach ($p in $j.PSObject.Properties) {
    $v = $p.Value
    if ($v -is [string]) {
        if ($v.Length -gt 24) {
            Write-Output "$($p.Name) => str(len=$($v.Length)) head=$($v.Substring(0,10))..."
        } else {
            Write-Output "$($p.Name) => short-string (len=$($v.Length))"
        }
    } else {
        Write-Output "$($p.Name) => $($v.GetType().Name)"
    }
}
