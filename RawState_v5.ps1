# ====================================================================
# FTS: RawState  |  Gaming Mode Toggle  |  Build v5.0 (Performance)
# ====================================================================
# Target: Competitive Latency Reduction & OS De-bloating
# License: Asymmetric Honor System (State 0 / State 1)
# ====================================================================
# Standalone use:
#   pwsh -File .\RawState_v5.ps1 -Mode Toggle
#   pwsh -File .\RawState_v5.ps1 -Mode Enable
#   pwsh -File .\RawState_v5.ps1 -Mode Enable -EnableMsiMode -DisableSysMain -HardwareGpuScheduling
#   pwsh -File .\RawState_v5.ps1 -Mode Disable
#   pwsh -File .\RawState_v5.ps1 -Mode Status -OutputFormat Json
#   pwsh -File .\RawState_v5.ps1 -Mode Init
#
# OpenClaw / Discord bot integration:
#   Create a Task Scheduler task with "Run with highest privileges" and
#   trigger it on demand from the bot. Use -OutputFormat Json -Quiet so
#   the bot gets exactly one parseable JSON object on stdout.
#
#   Task Scheduler action:
#     Program : pwsh.exe
#     Arguments: -NonInteractive -File C:\OpenClaw\RawState_v5.ps1
#                -Mode Toggle -OutputFormat Json -Quiet
#
#   IMPORTANT: HKCU tweaks (GameDVR, FSO, VisualEffects, GameBar) only
#   affect the registry hive of the user the process runs as. If the bot
#   runs the task as SYSTEM or a different user account, HKCU tweaks
#   will not apply to the gaming user. Run the task as the gaming user's
#   account with highest privileges for full coverage.
#
# DO NOT run without reviewing first.
# ====================================================================

[CmdletBinding()]
param(
    [ValidateSet('Enable','Disable','Toggle','Status','Init')]
    [string]$Mode = 'Toggle',

    [string]$StateRoot = 'C:\RawState',

    # ---- Opt-in tweaks (require explicit flags) ----

    # C-state disable: forces static V-F curve. Can reduce boost headroom on
    # Zen 2+ / 10th-gen Intel+. Only enable if your CPU profile benefits.
    [switch]$DisableCStates,

    # Full MSI-X IRQ affinity pin on NIC via HKLM\...\Enum.
    # Requires TrustedInstaller ownership. RSS pinning always applies regardless.
    [switch]$IsolateNicIrq,
    [ValidateRange(0,63)]
    [int]$IrqTargetCpu = 2,

    # Hardware-Accelerated GPU Scheduling (HwSchMode).
    # Requires Turing/RDNA2+ GPU and Windows 10 2004+. Needs reboot.
    [switch]$HardwareGpuScheduling,

    # MSI interrupt mode for GPU and NIC.
    # Eliminates shared IRQ contention. Requires TrustedInstaller access on Enum keys.
    [switch]$EnableMsiMode,

    # NIC advanced tweaks: interrupt moderation off, LSO off, flow control off, RSS pin.
    # Causes a brief internet dropout while the NIC adapter restarts. Longer on Wi-Fi.
    [switch]$NicAdvancedTweaks,

    # Disable SysMain (Superfetch). No benefit on NVMe; may help on SATA SSD/HDD.
    [switch]$DisableSysMain,

    # ---- OpenClaw / bot flags ----
    [ValidateSet('Text','Json')]
    [string]$OutputFormat = 'Text',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$script:StateFile = Join-Path $StateRoot 'gaming_mode_state.json'

# ====================================================================
# HELPERS
# ====================================================================
function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = [Security.Principal.WindowsPrincipal]::new($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell session.'
    }
}

function Test-IsSystem {
    return ([Security.Principal.WindowsIdentity]::GetCurrent().Name -eq 'NT AUTHORITY\SYSTEM')
}

function Write-Status {
    param([string]$Message)
    if (-not $script:Quiet) { Write-Host $Message }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$Arguments = @()
    )
    $out = & $File @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$File $($Arguments -join ' ') failed (exit $LASTEXITCODE): $out"
    }
    return $out
}

function New-BackupDir {
    if (-not (Test-Path $StateRoot)) { New-Item -ItemType Directory -Path $StateRoot | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir   = Join-Path $StateRoot $stamp
    New-Item -ItemType Directory -Path $dir | Out-Null
    return $dir
}

function Export-RegKey {
    param([Parameter(Mandatory)][string]$KeyPath, [Parameter(Mandatory)][string]$OutFile)
    Invoke-Native -File 'reg.exe' -Arguments @('export', $KeyPath, $OutFile, '/y') | Out-Null
}

function Export-RegKeyIfExists {
    # Exports a registry key only if it exists; writes a .absent sentinel otherwise.
    param([Parameter(Mandatory)][string]$KeyPath, [Parameter(Mandatory)][string]$OutFile)
    $query = & reg.exe query $KeyPath 2>&1
    if ($LASTEXITCODE -eq 0) {
        Export-RegKey $KeyPath $OutFile
        return $true
    } else {
        Set-Content -Path ([IO.Path]::ChangeExtension($OutFile, '.absent')) -Value '' -Encoding ASCII
        return $false
    }
}

function Import-RegFile {
    param([Parameter(Mandatory)][string]$File)
    Invoke-Native -File 'reg.exe' -Arguments @('import', $File) | Out-Null
}

function Get-PhysicalAdapters {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' }
}

function Get-GamingModeState {
    if (Test-Path $script:StateFile) {
        return Get-Content $script:StateFile -Raw | ConvertFrom-Json
    }
    return $null
}

function Set-GamingModeState {
    param([hashtable]$State)
    if (-not (Test-Path $StateRoot)) { New-Item -ItemType Directory -Path $StateRoot | Out-Null }
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $script:StateFile -Encoding UTF8
}

function Emit-Result {
    param(
        [bool]$Success,
        [string]$GamingMode,
        [string]$Message,
        [string[]]$AppliedTweaks  = @(),
        [bool]$RequiresReboot = $false
    )
    if ($OutputFormat -eq 'Json') {
        [PSCustomObject]@{
            Success        = $Success
            GamingMode     = $GamingMode
            Message        = $Message
            AppliedTweaks  = $AppliedTweaks
            RequiresReboot = $RequiresReboot
        } | ConvertTo-Json -Compress | Write-Output
    } else {
        Write-Host ''
        Write-Host "Gaming Mode    : $GamingMode"
        Write-Host "Status         : $(if ($Success) { 'OK' } else { 'ERROR' })"
        Write-Host "Message        : $Message"
        if ($AppliedTweaks.Count -gt 0) {
            Write-Host "Applied Tweaks : $($AppliedTweaks -join ', ')"
        }
        if ($RequiresReboot) {
            Write-Host 'NOTE           : Reboot required for BCDEdit / GPU scheduler / MSI mode changes.'
        }
    }
}

# ====================================================================
# CONFIG / INIT
# ====================================================================
function Get-RawStateConfig {
    $configFile = Join-Path $StateRoot 'config.json'
    if (Test-Path $configFile) {
        return Get-Content $configFile -Raw | ConvertFrom-Json
    }
    return $null
}

function Invoke-Prompt {
    # Interactive Y/N prompt with a default value.
    param([string]$Question, [bool]$Default = $false)
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $ans = Read-Host "  $Question $hint"
        if ($ans -eq '')              { return $Default }
        if ($ans -match '^[Yy]')      { return $true    }
        if ($ans -match '^[Nn]')      { return $false   }
        Write-Host '  Please enter Y or N.'
    }
}

function Apply-Config {
    # Merges saved config into script-level switches.
    # Uses [switch]$true to ensure correct SwitchParameter type when overriding defaults.
    # Config only applies when the CLI switch was not explicitly provided (i.e. still $false).
    param($Config)
    if (-not $Config) { return }
    if ($Config.disableCStates        -and -not $script:DisableCStates)        { $script:DisableCStates        = [switch]$true }
    if ($Config.isolateNicIrq         -and -not $script:IsolateNicIrq)         { $script:IsolateNicIrq         = [switch]$true }
    if ($null -ne $Config.irqTargetCpu -and $script:IrqTargetCpu -eq 2)        { $script:IrqTargetCpu          = [int]$Config.irqTargetCpu }
    if ($Config.hardwareGpuScheduling -and -not $script:HardwareGpuScheduling) { $script:HardwareGpuScheduling = [switch]$true }
    if ($Config.enableMsiMode         -and -not $script:EnableMsiMode)         { $script:EnableMsiMode         = [switch]$true }
    if ($Config.nicAdvancedTweaks     -and -not $script:NicAdvancedTweaks)     { $script:NicAdvancedTweaks     = [switch]$true }
    if ($Config.disableSysMain        -and -not $script:DisableSysMain)        { $script:DisableSysMain        = [switch]$true }
}

function Invoke-Init {
    Write-Host ''
    Write-Host '  ================================================================'
    Write-Host '  FTS: RawState  |  Setup'
    Write-Host '  ================================================================'
    Write-Host '  Opt-in tweaks are OFF by default. Each has trade-offs.'
    Write-Host '  Read each description before answering.'
    Write-Host ''

    Write-Host '  [1] C-state Disable'
    Write-Host '      Forces CPU to hold full clock frequency. On Zen 2+ / Intel 10th-gen+'
    Write-Host '      this can REDUCE boost headroom and raise idle temps. Only enable'
    Write-Host '      if you have tested this benefits your specific CPU.'
    $cstates = Invoke-Prompt 'Enable C-state disable?' $false

    Write-Host ''
    Write-Host '  [2] NIC IRQ Affinity Pin'
    Write-Host '      Pins NIC interrupts to a specific logical CPU core via the registry.'
    Write-Host '      Requires TrustedInstaller key ownership and may silently fail.'
    Write-Host '      RSS base-processor pinning always applies regardless of this option.'
    $irq    = Invoke-Prompt 'Enable IRQ affinity pin?' $false
    $irqCpu = 2
    if ($irq) {
        $cpuStr = Read-Host '  Target CPU index (0-63, default 2)'
        if ($cpuStr -match '^\d+$' -and [int]$cpuStr -le 63) { $irqCpu = [int]$cpuStr }
    }

    Write-Host ''
    Write-Host '  [3] Hardware GPU Scheduling'
    Write-Host '      Lets the GPU manage its own work queue instead of the CPU driver.'
    Write-Host '      Requires: Turing (RTX 20xx) / RDNA2 (RX 6000) or newer GPU.'
    Write-Host '      Windows 10 2004+ required. Reboot required to take effect.'
    $hags   = Invoke-Prompt 'Enable hardware GPU scheduling?' $false

    Write-Host ''
    Write-Host '  [4] MSI Interrupt Mode (GPU + NIC)'
    Write-Host '      Forces Message Signaled Interrupts, eliminating shared IRQ contention.'
    Write-Host '      Measurable DPC latency reduction. Requires TrustedInstaller access'
    Write-Host '      on Enum registry keys. Reboot required to take effect.'
    $msi    = Invoke-Prompt 'Enable MSI mode?' $false

    Write-Host ''
    Write-Host '  [5] Disable SysMain (Superfetch)'
    Write-Host '      Stops and disables the prefetch service. No benefit on NVMe SSDs.'
    Write-Host '      May reduce background I/O pressure on SATA SSD or HDD.'
    $sysmain = Invoke-Prompt 'Disable SysMain?' $false

    Write-Host ''
    Write-Host '  [6] NIC Advanced Tweaks (interrupt moderation off, LSO off, flow control off, RSS pin)'
    Write-Host '      Reduces NIC interrupt overhead and DPC latency.'
    Write-Host '      WARNING: your internet connection will drop while the adapter restarts.'
    Write-Host '      On Wi-Fi, reconnection may take 30 seconds or longer.'
    $nicAdv  = Invoke-Prompt 'Enable NIC advanced tweaks?' $false

    Write-Host ''
    $remember = Invoke-Prompt 'Save these choices for future runs?' $true

    $config = @{
        configuredAt          = (Get-Date -Format 'o')
        rememberSettings      = $remember
        disableCStates        = $cstates
        isolateNicIrq         = $irq
        irqTargetCpu          = $irqCpu
        hardwareGpuScheduling = $hags
        enableMsiMode         = $msi
        nicAdvancedTweaks     = $nicAdv
        disableSysMain        = $sysmain
    }

    if ($remember) {
        if (-not (Test-Path $StateRoot)) { New-Item -ItemType Directory -Path $StateRoot | Out-Null }
        $config | ConvertTo-Json | Set-Content -Path (Join-Path $StateRoot 'config.json') -Encoding UTF8
        Write-Host ''
        Write-Host "  Configuration saved -> $StateRoot\config.json"
        Write-Host "  Run '-Mode Init' at any time to reconfigure."
    }

    Write-Host ''
    return [PSCustomObject]$config
}

# ====================================================================
# BACKUP
# ====================================================================
function Invoke-Backup {
    $dir = New-BackupDir
    Write-Status "  Backup directory: $dir"

    $isSystem = Test-IsSystem
    if ($isSystem) {
        Write-Warning 'Running as SYSTEM: HKCU-based backups (GameDVR, FSO, VisualEffects) will capture the SYSTEM hive, not the gaming user. Re-run as the gaming user for full HKCU coverage.'
    }

    # [1] TCP/IP v4 + v6 interfaces
    Export-RegKey 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'  (Join-Path $dir 'TCP_v4.reg')
    Export-RegKey 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces' (Join-Path $dir 'TCP_v6.reg')
    Write-Status '  [1]  TCP/IP interfaces backed up (v4 + v6).'

    # [2] MMCSS SystemProfile
    Export-RegKey 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' (Join-Path $dir 'MMCSS.reg')
    Write-Status '  [2]  MMCSS SystemProfile backed up.'

    # [3] Win32PrioritySeparation
    Export-RegKey 'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl' (Join-Path $dir 'PriorityControl.reg')
    Write-Status '  [3]  PriorityControl backed up.'

    # [4] Active power plan
    $activeText = (powercfg /getactivescheme) -join "`n"
    if ($activeText -notmatch '([0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})') {
        throw "Could not parse active power scheme GUID from: $activeText"
    }
    $activeGuid = $matches[1]
    Invoke-Native -File 'powercfg.exe' -Arguments @('/export', (Join-Path $dir 'PowerPlan.pow'), $activeGuid) | Out-Null
    Set-Content -Path (Join-Path $dir 'PowerPlan.guid') -Value $activeGuid -Encoding ASCII
    Write-Status "  [4]  Power plan backed up (GUID: $activeGuid)."

    # [5] BCDEdit - 'default' means value absent; Disable will deletevalue to revert cleanly.
    $bcdRaw = (& bcdedit.exe /enum '{current}') -join "`n"
    @{
        disabledynamictick = if ($bcdRaw -match 'disabledynamictick\s+(\S+)') { $matches[1] } else { 'default' }
        useplatformtick    = if ($bcdRaw -match 'useplatformtick\s+(\S+)')    { $matches[1] } else { 'default' }
    } | ConvertTo-Json | Set-Content -Path (Join-Path $dir 'BCDEdit.json') -Encoding ASCII
    Write-Status '  [5]  BCDEdit state backed up.'

    # [6] NIC advanced properties (per adapter)
    $adapters = Get-PhysicalAdapters
    if ($adapters) {
        $adapters | ForEach-Object {
            $n = $_.Name
            Get-NetAdapterAdvancedProperty -Name $n -ErrorAction SilentlyContinue |
                Select-Object @{n='AdapterName';e={$n}}, RegistryKeyword, RegistryValue
        } | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $dir 'NIC_AdvancedProps.json') -Encoding UTF8
        Write-Status '  [6]  NIC advanced properties backed up.'
    }

    # [7] Psched (may not exist)
    $pschedExisted = Export-RegKeyIfExists 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Psched' (Join-Path $dir 'Psched.reg')
    Write-Status "  [7]  Psched $(if ($pschedExisted) { 'backed up.' } else { 'absent; sentinel written.' })"

    # [8] GPU scheduler (opt-in)
    if ($script:HardwareGpuScheduling) {
        Export-RegKey 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' (Join-Path $dir 'GraphicsDrivers.reg')
        Write-Status '  [8]  GraphicsDrivers (GPU scheduler) backed up.'
    }

    # [9] Power throttling (may not exist)
    $ptExisted = Export-RegKeyIfExists 'HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' (Join-Path $dir 'PowerThrottling.reg')
    Write-Status "  [9]  PowerThrottling $(if ($ptExisted) { 'backed up.' } else { 'absent; sentinel written.' })"

    # [10] GameConfigStore + GameBar + GameDVR (HKCU)
    Export-RegKeyIfExists 'HKCU\System\GameConfigStore'                                           (Join-Path $dir 'GameConfigStore.reg')  | Out-Null
    Export-RegKeyIfExists 'HKCU\Software\Microsoft\GameBar'                                       (Join-Path $dir 'GameBar.reg')          | Out-Null
    Export-RegKeyIfExists 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR'                (Join-Path $dir 'GameDVR_User.reg')     | Out-Null
    Write-Status '  [10] GameConfigStore / GameBar / GameDVR (user) backed up.'

    # [11] GameDVR policy (HKLM)
    Export-RegKeyIfExists 'HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR' (Join-Path $dir 'GameDVR_Policy.reg') | Out-Null
    Write-Status '  [11] GameDVR policy (HKLM) backed up.'

    # [12] Visual effects (HKCU)
    Export-RegKeyIfExists 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' (Join-Path $dir 'VisualEffects.reg') | Out-Null
    Write-Status '  [12] VisualEffects backed up.'

    # [13] SysMain service startup type
    $sysMain = Get-Service -Name SysMain -ErrorAction SilentlyContinue
    $sysMainState = if ($sysMain) { $sysMain.StartType.ToString() } else { 'NotFound' }
    Set-Content -Path (Join-Path $dir 'SysMain_State.txt') -Value $sysMainState -Encoding ASCII
    Write-Status "  [13] SysMain service state backed up ($sysMainState)."

    # [14] NIC power management settings (per adapter, JSON)
    if ($adapters) {
        $adapters | ForEach-Object {
            $pm = Get-NetAdapterPowerManagement -Name $_.Name -ErrorAction SilentlyContinue
            if ($pm) {
                [PSCustomObject]@{
                    AdapterName        = $_.Name
                    WakeOnMagicPacket  = $pm.WakeOnMagicPacket.ToString()
                    WakeOnPattern      = $pm.WakeOnPattern.ToString()
                    D0PacketCoalescing = $pm.D0PacketCoalescing.ToString()
                }
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $dir 'NIC_PowerMgmt.json') -Encoding UTF8
        Write-Status '  [14] NIC power management backed up.'
    }

    # [15] netsh TCP global settings
    $tcpGlobalRaw = (& netsh.exe int tcp show global) -join "`n"
    $tcpHeuristicsRaw = (& netsh.exe int tcp show heuristics) -join "`n"
    @{
        autotuninglevel     = if ($tcpGlobalRaw -match 'Auto-Tuning Level\s*:\s*(\S+)')        { $matches[1] } else { 'normal'   }
        ecncapability       = if ($tcpGlobalRaw -match 'ECN Capability\s*:\s*(\S+)')           { $matches[1] } else { 'disabled' }
        timestamps          = if ($tcpGlobalRaw -match 'RFC 1323 Timestamps\s*:\s*(\S+)')      { $matches[1] } else { 'disabled' }
        nonsackrttresiliency = if ($tcpGlobalRaw -match 'Non Sack Rtt Resiliency\s*:\s*(\S+)') { $matches[1] } else { 'disabled' }
        heuristics          = if ($tcpHeuristicsRaw -match 'enabled')                          { 'enabled'   } else { 'disabled' }
    } | ConvertTo-Json | Set-Content -Path (Join-Path $dir 'netsh_tcp_settings.json') -Encoding ASCII
    Set-Content -Path (Join-Path $dir 'netsh_tcp_global_raw.txt') -Value $tcpGlobalRaw -Encoding UTF8
    Write-Status '  [15] netsh TCP settings backed up.'

    # [16] Kernel key (GlobalTimerResolutionRequests)
    Export-RegKey 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' (Join-Path $dir 'Kernel.reg')
    Write-Status '  [16] Kernel (GlobalTimerResolutionRequests) backed up.'

    # [17] MSI mode per-device (opt-in)
    if ($script:EnableMsiMode) {
        $msiDevices = @()
        $gpu = Get-PnpDevice -Class Display -Status OK |
               Where-Object { $_.FriendlyName -notmatch 'Microsoft' } |
               Select-Object -First 1
        $nic = Get-PnpDevice -Class Net -Status OK |
               Where-Object { $_.InstanceId } |
               Select-Object -First 1
        foreach ($dev in @($gpu, $nic) | Where-Object { $_ }) {
            $msiKey = "HKLM\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
            $safeName = ($dev.InstanceId -replace '[\\/:*?"<>|]', '_')
            $existed = Export-RegKeyIfExists $msiKey (Join-Path $dir "MSI_$safeName.reg")
            if (-not $existed) {
                Set-Content -Path (Join-Path $dir "MSI_$safeName.absent") -Value $dev.InstanceId -Encoding ASCII
            }
            $msiDevices += [PSCustomObject]@{ InstanceId = $dev.InstanceId; SafeName = $safeName }
        }
        $msiDevices | ConvertTo-Json | Set-Content -Path (Join-Path $dir 'MSI_Devices.json') -Encoding ASCII
        Write-Status '  [17] MSI mode device keys backed up.'
    }

    return $dir
}

# ====================================================================
# APPLY TWEAKS
# Each function returns its label string on success, $null on skip.
# ====================================================================

function Set-TcpTweaks {
    $adapters = Get-PhysicalAdapters
    if (-not $adapters) { Write-Warning 'No connected physical adapters; skipping TCP tweaks.'; return $null }
    foreach ($root in @(
        'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces',
        'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces'
    )) {
        foreach ($a in $adapters) {
            $path = Join-Path $root "{$($a.InterfaceGuid.Trim('{','}'))}"
            if (-not (Test-Path $path)) { continue }
            New-ItemProperty -Path $path -Name 'TcpAckFrequency' -Value 1 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path $path -Name 'TcpDelAckTicks'  -Value 0 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path $path -Name 'TCPNoDelay'      -Value 1 -PropertyType DWord -Force | Out-Null
        }
    }
    Write-Status '  [1]  TCP tweaks applied (v4+v6, physical adapters).'
    return 'TCP'
}

function Set-MmcssTweaks {
    $sysProfile = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    New-ItemProperty -Path $sysProfile -Name 'NetworkThrottlingIndex' -Value 0xffffffff -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $sysProfile -Name 'SystemResponsiveness'   -Value 10         -PropertyType DWord -Force | Out-Null
    $gamesPath = Join-Path $sysProfile 'Tasks\Games'
    if (-not (Test-Path $gamesPath)) { New-Item -Path $gamesPath -Force | Out-Null }
    New-ItemProperty -Path $gamesPath -Name 'GPU Priority'        -Value 8      -PropertyType DWord  -Force | Out-Null
    New-ItemProperty -Path $gamesPath -Name 'Priority'            -Value 6      -PropertyType DWord  -Force | Out-Null
    New-ItemProperty -Path $gamesPath -Name 'Scheduling Category' -Value 'High' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $gamesPath -Name 'SFIO Priority'       -Value 'High' -PropertyType String -Force | Out-Null
    Write-Status '  [2]  MMCSS tweaks applied.'
    return 'MMCSS'
}

function Set-Win32PriorityTweak {
    # 0x26 = fixed quantum, max foreground boost, short time slices.
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' `
        -Name 'Win32PrioritySeparation' -Value 0x26 -PropertyType DWord -Force | Out-Null
    Write-Status '  [3]  Win32PrioritySeparation = 0x26.'
    return 'Win32Priority'
}

function Set-PowerTweaks {
    param([switch]$DisableCStates)
    # Aggressive boost mode (AC + DC)
    Invoke-Native -File 'powercfg.exe' -Arguments @('/setacvalueindex','scheme_current','sub_processor','PERFBOOSTMODE','2')     | Out-Null
    Invoke-Native -File 'powercfg.exe' -Arguments @('/setdcvalueindex','scheme_current','sub_processor','PERFBOOSTMODE','2')     | Out-Null
    # Minimum clock floor: 100%
    Invoke-Native -File 'powercfg.exe' -Arguments @('/setacvalueindex','scheme_current','sub_processor','PROCTHROTTLEMIN','100') | Out-Null
    Invoke-Native -File 'powercfg.exe' -Arguments @('/setdcvalueindex','scheme_current','sub_processor','PROCTHROTTLEMIN','100') | Out-Null
    # PCI-E ASPM off (sub_pciexpress may be absent on some power plans; non-fatal)
    try {
        Invoke-Native -File 'powercfg.exe' -Arguments @('/setacvalueindex','scheme_current','sub_pciexpress','ASPM','0') | Out-Null
        Invoke-Native -File 'powercfg.exe' -Arguments @('/setdcvalueindex','scheme_current','sub_pciexpress','ASPM','0') | Out-Null
    } catch { Write-Warning "  Power: ASPM skipped (sub_pciexpress not present on this plan). $_" }
    # USB selective suspend off (subgroup GUIDs may be absent; non-fatal)
    try {
        Invoke-Native -File 'powercfg.exe' -Arguments @('/setacvalueindex','scheme_current','2a737441-1930-4402-8d77-b2bebba308a3','48e6b7a6-50f5-4782-a5d4-53bb8f07e226','0') | Out-Null
        Invoke-Native -File 'powercfg.exe' -Arguments @('/setdcvalueindex','scheme_current','2a737441-1930-4402-8d77-b2bebba308a3','48e6b7a6-50f5-4782-a5d4-53bb8f07e226','0') | Out-Null
    } catch { Write-Warning "  Power: USB selective suspend skipped (subgroup not present on this plan). $_" }
    if ($DisableCStates) {
        Invoke-Native -File 'powercfg.exe' -Arguments @('/setacvalueindex','scheme_current','sub_processor','IDLEDISABLE','1') | Out-Null
        Invoke-Native -File 'powercfg.exe' -Arguments @('/setdcvalueindex','scheme_current','sub_processor','IDLEDISABLE','1') | Out-Null
        Write-Status '  [4]  Power: boost aggressive, min 100%, ASPM off, USB suspend off, C-states disabled.'
    } else {
        Write-Status '  [4]  Power: boost aggressive, min 100%, ASPM off, USB suspend off.'
    }
    Invoke-Native -File 'powercfg.exe' -Arguments @('/setactive','scheme_current') | Out-Null
    return 'Power'
}

function Set-CoreParkingTweak {
    # CPMINCORES 100: keeps all CPU cores un-parked at all times.
    # Distinct from PROCTHROTTLEMIN (clock floor). Particularly relevant on
    # AMD Ryzen systems where parking can push threads to a less-optimal CCD.
    # CPMINCORES may be absent in some OEM-stripped power plans; non-fatal.
    try {
        Invoke-Native -File 'powercfg.exe' -Arguments @('/setacvalueindex','scheme_current','sub_processor','CPMINCORES','100') | Out-Null
        Invoke-Native -File 'powercfg.exe' -Arguments @('/setdcvalueindex','scheme_current','sub_processor','CPMINCORES','100') | Out-Null
        Invoke-Native -File 'powercfg.exe' -Arguments @('/setactive','scheme_current') | Out-Null
        Write-Status '  [5]  Core parking disabled (CPMINCORES 100).'
    } catch { Write-Warning "  CoreParking: CPMINCORES not available on this power plan; skipped. $_" }
    return 'CoreParking'
}

function Set-BcdTweaks {
    Invoke-Native -File 'bcdedit.exe' -Arguments @('/set','disabledynamictick','yes') | Out-Null
    Invoke-Native -File 'bcdedit.exe' -Arguments @('/set','useplatformtick','yes')    | Out-Null
    Write-Status '  [6]  BCDEdit timer tweaks applied (reboot required).'
    return 'BCDEdit'
}

function Set-NicTweaks {
    param([switch]$NicAdvancedTweaks, [switch]$IsolateNicIrq, [int]$IrqTargetCpu)
    $adapters = Get-PhysicalAdapters
    if (-not $adapters) { Write-Warning 'No connected physical adapters; skipping NIC tweaks.'; return $null }

    if ($NicAdvancedTweaks) {
        Write-Warning '  NIC advanced tweaks: internet/network connection will drop while the adapter restarts. On Wi-Fi this may take 30+ seconds.'
        $keywords = @(
            @{ Name = '*InterruptModeration'; Value = '0' }
            @{ Name = '*LsoV2IPv4';           Value = '0' }
            @{ Name = '*LsoV2IPv6';           Value = '0' }
            @{ Name = '*FlowControl';         Value = '0' }
        )
        foreach ($a in $adapters) {
            # Apply all properties first, then do one controlled restart to batch the cycles.
            foreach ($kw in $keywords) {
                try { Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $kw.Name -RegistryValue $kw.Value -ErrorAction SilentlyContinue } catch { }
            }
            try { Set-NetAdapterRss    -Name $a.Name -BaseProcessorNumber $IrqTargetCpu -ErrorAction SilentlyContinue } catch { }
            try { Enable-NetAdapterRss -Name $a.Name -ErrorAction SilentlyContinue } catch { }
            # NIC power management — also adapter-touching; applied here so it is batched into the same restart below.
            try {
                Set-NetAdapterPowerManagement -Name $a.Name -WakeOnMagicPacket Disabled -WakeOnPattern Disabled -ErrorAction SilentlyContinue
                try { Set-NetAdapterPowerManagement -Name $a.Name -D0PacketCoalescing Disabled -ErrorAction SilentlyContinue } catch { }
            } catch { }
            # Single controlled restart — batches all property changes into one adapter cycle.
            try {
                Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                Enable-NetAdapter -Name $a.Name -ErrorAction SilentlyContinue
            } catch { Write-Warning "  Could not restart adapter '$($a.Name)': $_" }
        }
        Write-Status "  [7]  NIC advanced tweaks applied (interrupt moderation off, LSO off, flow control off, RSS -> CPU $IrqTargetCpu, power management off). Single adapter restart."
    } else {
        Write-Status '  [7]  NIC advanced tweaks skipped (opt-in — run -Mode Init or pass -NicAdvancedTweaks to enable).'
    }

    if ($IsolateNicIrq) {
        $pnp = Get-PnpDevice -Class Net -Status OK | Where-Object { $_.InstanceId } | Select-Object -First 1
        if ($pnp) {
            $affinityPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($pnp.InstanceId)\Device Parameters\Interrupt Management\Affinity Policy"
            $bytes = [BitConverter]::GetBytes([uint64]1 -shl $IrqTargetCpu)
            try {
                if (-not (Test-Path $affinityPath)) { New-Item -Path $affinityPath -Force | Out-Null }
                New-ItemProperty -Path $affinityPath -Name 'DevicePolicy'          -Value 4     -PropertyType DWord  -Force | Out-Null
                New-ItemProperty -Path $affinityPath -Name 'AssignmentSetOverride' -Value $bytes -PropertyType Binary -Force | Out-Null
                Write-Status "  [7b] IRQ affinity -> CPU $IrqTargetCpu for $($pnp.InstanceId)."
            } catch {
                Write-Warning "IRQ affinity failed (TrustedInstaller ownership required). RSS pinning was still applied. Error: $_"
            }
        }
    }
    return 'NIC'
}

function Set-PschedTweak {
    $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name 'NonBestEffortLimit' -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Status '  [9]  Psched NonBestEffortLimit = 0.'
    return 'Psched'
}

function Set-PowerThrottlingTweak {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name 'PowerThrottlingOff' -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Status '  [10] Power throttling disabled (PowerThrottlingOff = 1).'
    return 'PowerThrottle'
}

function Set-FsoAndGameDvrTweaks {
    # FSO: force exclusive fullscreen. GameDVR: disable background capture.
    # Note: Win+G Game Bar and Xbox screenshot capture will be disabled.
    $gameStore = 'HKCU:\System\GameConfigStore'
    if (-not (Test-Path $gameStore)) { New-Item -Path $gameStore -Force | Out-Null }
    New-ItemProperty -Path $gameStore -Name 'GameDVR_DXGIHonorFSEWindowsCompatible' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $gameStore -Name 'GameDVR_FSEBehavior'                    -Value 2 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $gameStore -Name 'GameDVR_Enabled'                        -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $gameStore -Name 'GameDVR_HonorUserFSEBehaviorMode'       -Value 1 -PropertyType DWord -Force | Out-Null
    $gameBar = 'HKCU:\Software\Microsoft\GameBar'
    if (-not (Test-Path $gameBar)) { New-Item -Path $gameBar -Force | Out-Null }
    New-ItemProperty -Path $gameBar -Name 'AllowAutoGameMode'         -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $gameBar -Name 'UseNexusForGameBarEnabled' -Value 0 -PropertyType DWord -Force | Out-Null
    $gameDvr = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'
    if (-not (Test-Path $gameDvr)) { New-Item -Path $gameDvr -Force | Out-Null }
    New-ItemProperty -Path $gameDvr -Name 'AppCaptureEnabled' -Value 0 -PropertyType DWord -Force | Out-Null
    $dvPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'
    if (-not (Test-Path $dvPolicy)) { New-Item -Path $dvPolicy -Force | Out-Null }
    New-ItemProperty -Path $dvPolicy -Name 'AllowGameDVR' -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Status '  [11] FSO enforced, GameDVR / GameBar disabled.'
    return 'FSO_GameDVR'
}

function Set-VisualEffectsTweak {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name 'VisualFXSetting' -Value 2 -PropertyType DWord -Force | Out-Null
    Write-Status '  [12] VisualEffects = best performance (applies on next Explorer restart / logoff).'
    return 'VisualEffects'
}

function Set-GlobalTimerTweak {
    # Windows 11 (build 22000+): allows games' timeBeginPeriod() to affect global timer.
    $winBuild = [System.Environment]::OSVersion.Version.Build
    if ($winBuild -lt 22000) {
        Write-Status '  [13] GlobalTimerResolutionRequests: skipped (not Windows 11).'
        return $null
    }
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'
    New-ItemProperty -Path $key -Name 'GlobalTimerResolutionRequests' -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Status '  [13] GlobalTimerResolutionRequests = 1 (Windows 11).'
    return 'GlobalTimer'
}

function Set-NetshTcpTweaks {
    $cmds = @(
        @('int','tcp','set','global','ecncapability=disabled'),
        @('int','tcp','set','global','timestamps=disabled'),
        @('int','tcp','set','global','nonsackrttresiliency=disabled'),
        @('int','tcp','set','global','autotuninglevel=normal'),
        @('int','tcp','set','heuristics','disabled')
    )
    foreach ($cmd in $cmds) {
        try { Invoke-Native -File 'netsh.exe' -Arguments $cmd | Out-Null }
        catch { Write-Warning "netsh $($cmd -join ' ') failed: $_" }
    }
    Write-Status '  [14] netsh TCP stack tuned (ECN off, timestamps off, heuristics off).'
    return 'NetshTCP'
}

function Set-GpuSchedulerTweak {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name 'HwSchMode' -Value 2 -PropertyType DWord -Force | Out-Null
    Write-Status '  [15] Hardware GPU scheduling enabled (reboot required).'
    return 'HardwareGPUSched'
}

function Set-MsiModeTweak {
    $gpu = Get-PnpDevice -Class Display -Status OK |
           Where-Object { $_.FriendlyName -notmatch 'Microsoft' } |
           Select-Object -First 1
    $nic = Get-PnpDevice -Class Net -Status OK |
           Where-Object { $_.InstanceId } |
           Select-Object -First 1
    $applied = 0
    foreach ($dev in @($gpu, $nic) | Where-Object { $_ }) {
        $msiPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
        try {
            if (-not (Test-Path $msiPath)) { New-Item -Path $msiPath -Force | Out-Null }
            New-ItemProperty -Path $msiPath -Name 'MSISupported' -Value 1 -PropertyType DWord -Force | Out-Null
            Write-Status "  [16] MSI mode enabled for $($dev.FriendlyName)."
            $applied++
        } catch {
            Write-Warning "MSI mode failed for $($dev.FriendlyName). Enum keys require TrustedInstaller ownership. Error: $_"
        }
    }
    return if ($applied -gt 0) { 'MsiMode' } else { $null }
}

function Set-SysMainTweak {
    $svc = Get-Service -Name SysMain -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Warning 'SysMain service not found; skipping.'; return $null }
    Stop-Service -Name SysMain -Force -ErrorAction SilentlyContinue
    Set-Service  -Name SysMain -StartupType Disabled
    Write-Status '  [Opt] SysMain (Superfetch) stopped and disabled.'
    return 'SysMain'
}

# ====================================================================
# ENABLE
# ====================================================================
function Invoke-Enable {
    # Load saved config. If none found and not running quiet, offer first-time setup.
    $cfg = Get-RawStateConfig
    if (-not $cfg -and -not $script:Quiet) {
        $ans = Read-Host "`n  No RawState configuration found. Run first-time setup? [Y/n]"
        if ($ans -notmatch '^[Nn]') { $cfg = Invoke-Init }
    }
    Apply-Config $cfg

    Write-Status 'RawState: Activating...'
    Write-Status 'Step 1 of 2: Capturing baseline snapshot...'
    $backupDir = Invoke-Backup

    Write-Status 'Step 2 of 2: Applying performance vector...'
    $tweaks = [System.Collections.Generic.List[string]]::new()
    $reboot = $false

    foreach ($result in @(
        (Set-TcpTweaks),
        (Set-MmcssTweaks),
        (Set-Win32PriorityTweak),
        (Set-PowerTweaks       -DisableCStates:$script:DisableCStates),
        (Set-CoreParkingTweak),
        (Set-BcdTweaks),
        (Set-NicTweaks         -NicAdvancedTweaks:$script:NicAdvancedTweaks -IsolateNicIrq:$script:IsolateNicIrq -IrqTargetCpu $script:IrqTargetCpu),
        (Set-PschedTweak),
        (Set-PowerThrottlingTweak),
        (Set-FsoAndGameDvrTweaks),
        (Set-VisualEffectsTweak),
        (Set-GlobalTimerTweak),
        (Set-NetshTcpTweaks)
    )) {
        if ($result) { $tweaks.Add($result) }
    }

    if ($tweaks -contains 'BCDEdit') { $reboot = $true }

    if ($script:HardwareGpuScheduling) {
        $r = Set-GpuSchedulerTweak; if ($r) { $tweaks.Add($r); $reboot = $true }
    }
    if ($script:EnableMsiMode) {
        $r = Set-MsiModeTweak; if ($r) { $tweaks.Add($r); $reboot = $true }
    }
    if ($script:DisableSysMain) {
        $r = Set-SysMainTweak; if ($r) { $tweaks.Add($r) }
    }

    Set-GamingModeState @{
        State         = 'Enabled'
        EnabledAt     = (Get-Date -Format 'o')
        BackupDir     = $backupDir
        Tweaks        = $tweaks -as [string[]]
        RebootPending = $reboot
    }

    return @{ Tweaks = $tweaks -as [string[]]; Reboot = $reboot }
}

# ====================================================================
# DISABLE  (revert to baseline)
# ====================================================================
function Invoke-Disable {
    $state = Get-GamingModeState
    if (-not $state -or $state.State -ne 'Enabled') {
        throw 'RawState is not currently active. Nothing to revert.'
    }
    $dir = $state.BackupDir
    if (-not (Test-Path $dir)) { throw "Baseline snapshot not found: $dir" }

    if (Test-IsSystem) {
        Write-Warning 'Running as SYSTEM: HKCU registry files will restore to the SYSTEM hive. For correct HKCU revert, run as the gaming user.'
    }

    Write-Status 'RawState: Reverting to baseline...'

    foreach ($f in @('TCP_v4.reg','TCP_v6.reg','MMCSS.reg','PriorityControl.reg','Kernel.reg')) {
        $p = Join-Path $dir $f
        if (Test-Path $p) { Import-RegFile $p; Write-Status "  Restored $f." }
        else { Write-Warning "  $f missing; skipping." }
    }

    $conditionalRestores = @(
        @{ Reg = 'Psched.reg';          Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' }
        @{ Reg = 'PowerThrottling.reg'; Key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' }
        @{ Reg = 'GameDVR_Policy.reg';  Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' }
    )
    foreach ($entry in $conditionalRestores) {
        $regFile = Join-Path $dir $entry.Reg
        $absent  = [IO.Path]::ChangeExtension((Join-Path $dir $entry.Reg), '.absent')
        if (Test-Path $regFile) {
            Import-RegFile $regFile; Write-Status "  Restored $($entry.Reg)."
        } elseif (Test-Path $absent) {
            Remove-Item -Path $entry.Key -Recurse -Force -ErrorAction SilentlyContinue
            Write-Status "  Removed $($entry.Key) (was absent before enable)."
        }
    }

    foreach ($f in @('GameConfigStore.reg','GameBar.reg','GameDVR_User.reg','VisualEffects.reg')) {
        $p = Join-Path $dir $f
        if (Test-Path $p) { Import-RegFile $p; Write-Status "  Restored $f." }
    }

    $gpuReg = Join-Path $dir 'GraphicsDrivers.reg'
    if (Test-Path $gpuReg) { Import-RegFile $gpuReg; Write-Status '  Restored GPU scheduler.' }

    $guidFile = Join-Path $dir 'PowerPlan.guid'
    $powFile  = Join-Path $dir 'PowerPlan.pow'
    if ((Test-Path $guidFile) -and (Test-Path $powFile)) {
        $origGuid = (Get-Content $guidFile -Raw).Trim()
        Invoke-Native -File 'powercfg.exe' -Arguments @('/import', $powFile) | Out-Null
        try { Invoke-Native -File 'powercfg.exe' -Arguments @('/setactive', $origGuid) | Out-Null }
        catch { Write-Warning '  Power plan imported but GUID may have been remapped; set it manually in Control Panel.' }
        Write-Status '  Restored power plan.'
    }

    $bcdFile = Join-Path $dir 'BCDEdit.json'
    if (Test-Path $bcdFile) {
        $bcdState = Get-Content $bcdFile -Raw | ConvertFrom-Json
        foreach ($setting in @('disabledynamictick','useplatformtick')) {
            $val = $bcdState.$setting
            if ($val -eq 'default') {
                try { Invoke-Native -File 'bcdedit.exe' -Arguments @('/deletevalue', $setting) | Out-Null } catch { }
            } else {
                Invoke-Native -File 'bcdedit.exe' -Arguments @('/set', $setting, $val) | Out-Null
            }
        }
        Write-Status '  Restored BCDEdit settings (reboot required).'
    }

    $nicFile = Join-Path $dir 'NIC_AdvancedProps.json'
    if (Test-Path $nicFile) {
        foreach ($prop in (Get-Content $nicFile -Raw | ConvertFrom-Json)) {
            try {
                Set-NetAdapterAdvancedProperty -Name $prop.AdapterName `
                    -RegistryKeyword $prop.RegistryKeyword -RegistryValue $prop.RegistryValue `
                    -ErrorAction SilentlyContinue
            } catch { }
        }
        Write-Status '  Restored NIC advanced properties.'
    }

    $nicPmFile = Join-Path $dir 'NIC_PowerMgmt.json'
    if (Test-Path $nicPmFile) {
        foreach ($item in (Get-Content $nicPmFile -Raw | ConvertFrom-Json)) {
            try {
                $params = @{ Name = $item.AdapterName; ErrorAction = 'SilentlyContinue' }
                if ($item.WakeOnMagicPacket  -in @('Enabled','Disabled')) { $params['WakeOnMagicPacket']  = $item.WakeOnMagicPacket  }
                if ($item.WakeOnPattern      -in @('Enabled','Disabled')) { $params['WakeOnPattern']      = $item.WakeOnPattern      }
                if ($item.D0PacketCoalescing -in @('Enabled','Disabled')) { $params['D0PacketCoalescing'] = $item.D0PacketCoalescing }
                Set-NetAdapterPowerManagement @params
            } catch { }
        }
        Write-Status '  Restored NIC power management.'
    }

    $netshFile = Join-Path $dir 'netsh_tcp_settings.json'
    if (Test-Path $netshFile) {
        $settings = Get-Content $netshFile -Raw | ConvertFrom-Json
        foreach ($key in @('autotuninglevel','ecncapability','timestamps','nonsackrttresiliency')) {
            $val = $settings.$key
            if ($val) {
                try { Invoke-Native -File 'netsh.exe' -Arguments @('int','tcp','set','global',"$key=$val") | Out-Null }
                catch { Write-Warning "  netsh restore of $key failed." }
            }
        }
        if ($settings.heuristics) {
            try { Invoke-Native -File 'netsh.exe' -Arguments @('int','tcp','set','heuristics',$settings.heuristics) | Out-Null }
            catch { Write-Warning '  netsh heuristics restore failed.' }
        }
        Write-Status '  Restored netsh TCP settings.'
    }

    $sysMainFile = Join-Path $dir 'SysMain_State.txt'
    if (Test-Path $sysMainFile) {
        $origStartType = (Get-Content $sysMainFile -Raw).Trim()
        if ($origStartType -notin @('NotFound','')) {
            try {
                Set-Service -Name SysMain -StartupType $origStartType -ErrorAction SilentlyContinue
                if ($origStartType -ne 'Disabled') { Start-Service SysMain -ErrorAction SilentlyContinue }
                Write-Status "  Restored SysMain service ($origStartType)."
            } catch { Write-Warning "  Could not restore SysMain to $origStartType." }
        }
    }

    Get-ChildItem -Path $dir -Filter 'MSI_*.reg' -ErrorAction SilentlyContinue | ForEach-Object {
        try { Import-RegFile $_.FullName; Write-Status "  Restored $($_.Name)." }
        catch { Write-Warning "  Could not restore $($_.Name): $_" }
    }
    Get-ChildItem -Path $dir -Filter 'MSI_*.absent' -ErrorAction SilentlyContinue | ForEach-Object {
        $instanceId = (Get-Content $_.FullName -Raw).Trim()
        if ($instanceId) {
            $msiPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$instanceId\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
            try { Remove-Item -Path $msiPath -Recurse -Force -ErrorAction SilentlyContinue }
            catch { Write-Warning "  Could not remove MSI key for $instanceId (TrustedInstaller); MSI will remain enabled but this is harmless." }
        }
    }

    Set-GamingModeState @{
        State      = 'Disabled'
        DisabledAt = (Get-Date -Format 'o')
        BackupDir  = $dir
    }
}

# ====================================================================
# ENTRY POINT
# ====================================================================
try {
    Assert-Admin

    $currentState   = Get-GamingModeState
    $currentModeStr = if ($currentState -and $currentState.State) { $currentState.State } else { 'Disabled' }

    if ($Mode -eq 'Toggle') {
        $Mode = if ($currentModeStr -eq 'Enabled') { 'Disable' } else { 'Enable' }
        Write-Status "Toggle: $currentModeStr -> $Mode."
    }

    switch ($Mode) {
        'Init' {
            Invoke-Init | Out-Null
            Write-Host '  Setup complete.'
        }
        'Status' {
            $tweaks = if ($currentState -and $currentState.Tweaks) { $currentState.Tweaks } else { @() }
            $reboot = [bool]($currentState -and $currentState.RebootPending)
            Emit-Result -Success $true -GamingMode $currentModeStr `
                -Message "RawState is currently $currentModeStr." `
                -AppliedTweaks $tweaks -RequiresReboot $reboot
        }
        'Enable' {
            if ($currentModeStr -eq 'Enabled') {
                Write-Warning 'RawState is already active. Run -Mode Disable first to revert to baseline before re-enabling.'
            }
            $result = Invoke-Enable
            Emit-Result -Success $true -GamingMode 'Enabled' `
                -Message 'RawState active.' `
                -AppliedTweaks $result.Tweaks -RequiresReboot $result.Reboot
        }
        'Disable' {
            Invoke-Disable
            Emit-Result -Success $true -GamingMode 'Disabled' `
                -Message 'Baseline restored. Reboot recommended.' `
                -RequiresReboot $true
        }
    }
}
catch {
    if ($OutputFormat -eq 'Json') {
        [PSCustomObject]@{ Success = $false; GamingMode = 'Unknown'; Message = "$_" } |
            ConvertTo-Json -Compress | Write-Output
    } else {
        Write-Error $_
    }
    exit 1
}
