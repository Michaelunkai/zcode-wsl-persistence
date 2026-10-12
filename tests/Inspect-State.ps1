# Inspect-State.ps1 — structural (names-only) inspection of ZCode state files.
# Never prints values: only JSON property names, sizes, and timestamps.
$ErrorActionPreference = 'SilentlyContinue'

function Show-JsonKeys($path, $label) {
    if (-not (Test-Path $path)) { Write-Output "$label : MISSING"; return }
    $fi = Get-Item $path
    Write-Output "$label : $($fi.Length) bytes, $($fi.LastWriteTime)"
    try {
        $j = Get-Content $path -Raw | ConvertFrom-Json
        if ($j -is [System.Management.Automation.PSCustomObject]) {
            Write-Output "  top-level keys: $($j.PSObject.Properties.Name -join ', ')"
            foreach ($p in $j.PSObject.Properties) {
                if ($p.Value -is [System.Management.Automation.PSCustomObject]) {
                    Write-Output "    $($p.Name).keys: $($p.Value.PSObject.Properties.Name -join ', ')"
                }
            }
        } else {
            Write-Output "  (array/scalar root)"
        }
    } catch { Write-Output "  (not JSON: $($_.Exception.Message))" }
}

$v2 = 'C:\Users\Admin\.zcode\v2'
Show-JsonKeys "$v2\provider_config.json" 'WIN provider_config.json'
Show-JsonKeys "$v2\setting.json"          'WIN setting.json'
Show-JsonKeys "$v2\onboarding-record.json" 'WIN onboarding-record.json'
Show-JsonKeys "$v2\credentials.json"      'WIN credentials.json'
Show-JsonKeys "$v2\telemetry-state.json"  'WIN telemetry-state.json'

Write-Output '--- electron store ---'
Get-ChildItem 'C:\Users\Admin\AppData\Roaming\ZCode\rum-electron-store' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Output "rum-electron-store/$($_.Name): $($_.Length) bytes" }

Write-Output '--- Local Storage leveldb (names+sizes only) ---'
Get-ChildItem 'C:\Users\Admin\AppData\Roaming\ZCode\session\Local Storage\leveldb' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Output "  $($_.Name): $($_.Length) bytes, $($_.LastWriteTime)" }
