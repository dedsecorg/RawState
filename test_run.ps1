$log    = 'C:\RawState\test_output_v2.json'
$script = 'C:\Users\wf\Documents\RawState\RawState_v5.ps1'

# Ensure state dir exists
if (-not (Test-Path 'C:\RawState')) { New-Item -ItemType Directory 'C:\RawState' | Out-Null }
Remove-Item $log -ErrorAction SilentlyContinue

$results = [System.Collections.Generic.List[object]]::new()

function Run-Mode {
    param([string]$Mode, [string[]]$ExtraArgs = @())
    $start = Get-Date
    $raw = & pwsh -NoProfile -File $script -Mode $Mode -OutputFormat Json -Quiet @ExtraArgs 2>&1
    $elapsed = ((Get-Date) - $start).TotalSeconds
    $parsed = try { $raw | ConvertFrom-Json } catch { [PSCustomObject]@{ Success = $false; RawOutput = "$raw" } }
    [PSCustomObject]@{ Result = $parsed; ElapsedSeconds = [math]::Round($elapsed, 1) }
}

function Test-Network {
    $ping = Test-Connection 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue
    [PSCustomObject]@{ Reachable = $ping; Timestamp = (Get-Date -Format 'HH:mm:ss') }
}

$results.Add([PSCustomObject]@{ Step = '1_StatusBefore'; Network = (Test-Network); Data = (Run-Mode 'Status') })
$results.Add([PSCustomObject]@{ Step = '2_Enable';        Network = (Test-Network); Data = (Run-Mode 'Enable') })
$results.Add([PSCustomObject]@{ Step = '3_NetworkCheck';  Network = (Test-Network); Data = $null })
$results.Add([PSCustomObject]@{ Step = '4_StatusAfter';   Network = (Test-Network); Data = (Run-Mode 'Status') })
$results.Add([PSCustomObject]@{ Step = '5_Disable';       Network = (Test-Network); Data = (Run-Mode 'Disable') })
$results.Add([PSCustomObject]@{ Step = '6_NetworkCheck';  Network = (Test-Network); Data = $null })
$results.Add([PSCustomObject]@{ Step = '7_StatusFinal';   Network = (Test-Network); Data = (Run-Mode 'Status') })

$results | ConvertTo-Json -Depth 10 | Set-Content -Path $log -Encoding UTF8
Write-Host "Test complete. Output -> $log"
