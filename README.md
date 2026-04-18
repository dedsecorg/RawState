# FTS: RawState
**For the Sweats. Build v5.0 (Performance)**

> *Competitive latency reduction and OS de-bloating for Windows.*
> *No subscriptions. No telemetry. No black box. Just the raw state.*

---

## What it does

RawState is a single PowerShell script that applies and reverts a
comprehensive set of Windows OS parameter changes targeting competitive
gaming performance — the same class of modifications sold behind
subscription paywalls by closed-source tooling, exposed here transparently
and fully reversible.

Every change is backed up before it is applied. A single command returns
your system to the exact pre-run state.

---

## Requirements

- Windows 10 / 11
- PowerShell 7.x
- **Elevated session (Run as Administrator)**

---

## Usage

```powershell
# First-time setup wizard (configure opt-in tweaks and save preferences)
pwsh -File .\RawState_v5.ps1 -Mode Init

# Toggle (reads current state, flips it)
pwsh -File .\RawState_v5.ps1 -Mode Toggle

# Explicit enable
pwsh -File .\RawState_v5.ps1 -Mode Enable

# Enable with all opt-in flags via CLI
pwsh -File .\RawState_v5.ps1 -Mode Enable -EnableMsiMode -DisableSysMain -HardwareGpuScheduling

# Revert everything to original state
pwsh -File .\RawState_v5.ps1 -Mode Disable

# Check current state (JSON output for bots)
pwsh -File .\RawState_v5.ps1 -Mode Status -OutputFormat Json
```

---

## First-Run Setup

The first time you run `-Mode Enable` or `-Mode Toggle`, RawState checks for
a saved configuration. If none is found it prompts:

```
  No RawState configuration found. Run first-time setup? [Y/n]
```

The setup wizard walks through each opt-in tweak with a plain-language
description and trade-off warning, then asks whether to save your choices.

You can also trigger setup explicitly at any time:

```powershell
pwsh -File .\RawState_v5.ps1 -Mode Init
```

Choices are saved to `C:\RawState\config.json` and automatically loaded on
every subsequent Enable/Toggle run. CLI flags passed at runtime always
override saved config. To reconfigure, just run `-Mode Init` again.

> `-Quiet` mode (used by bots) skips the first-run prompt. Run setup
> manually first when deploying via OpenClaw.

---

## What gets changed

**Core (always applied on Enable)**

| # | Tweak | Mechanism |
|---|-------|-----------|
| 1 | TCP Nagle bypass + delayed ACK off | Registry (per physical adapter, v4+v6) |
| 2 | MMCSS scheduler lock | Registry (SystemProfile + Tasks\Games) |
| 3 | Win32PrioritySeparation = 0x26 | Registry (PriorityControl) |
| 4 | Power: aggressive boost, min 100%, ASPM off, USB suspend off | powercfg |
| 5 | Core parking disabled | powercfg (CPMINCORES 100) |
| 6 | BCDEdit timer: disabledynamictick + useplatformtick | bcdedit (reboot required) |
| 7 | NIC: interrupt moderation off, LSO off, flow control off, RSS pinned | Set-NetAdapterAdvancedProperty |
| 8 | NIC power management off | Set-NetAdapterPowerManagement |
| 9 | Psched QoS reservation removed | Registry |
| 10 | Power throttling off | Registry (PowerThrottlingOff) |
| 11 | FSO enforced, GameDVR / GameBar disabled | Registry (HKCU + HKLM policy) |
| 12 | Visual effects → best performance | Registry (HKCU) |
| 13 | GlobalTimerResolutionRequests = 1 | Registry (Windows 11 only) |
| 14 | netsh TCP stack: ECN off, timestamps off, heuristics off | netsh |

**Opt-in flags**

| Flag | Effect |
|------|--------|
| `-HardwareGpuScheduling` | HwSchMode = 2. Requires Turing/RDNA2+ GPU. Reboot required. |
| `-EnableMsiMode` | MSI interrupt mode for GPU + NIC. Requires TrustedInstaller access on Enum keys. Reboot required. |
| `-NicAdvancedTweaks` | Interrupt moderation off, LSO off, flow control off, RSS pin. **Causes a brief internet dropout** while the adapter restarts. On Wi-Fi this may take 30+ seconds. |
| `-DisableSysMain` | Stops and disables Superfetch. No benefit on NVMe; may help on SATA SSD/HDD. |
| `-DisableCStates` | Forces static CPU V-F curve. Can reduce boost headroom on Zen 2+ / 10th-gen Intel+. Use with knowledge. |
| `-IsolateNicIrq` | Full MSI-X IRQ affinity pin on NIC. Requires TrustedInstaller. RSS pinning applies regardless. |

---

## Backup & Revert

On every `Enable`, a full snapshot of the system state is written to
`C:\RawState\<timestamp>\` before any change is made. Running `-Mode Disable`
restores every modified key, netsh setting, NIC property, and power plan
exactly as they were.

The toggle state is tracked in `C:\RawState\gaming_mode_state.json`.

---

## OpenClaw / Discord Bot Integration

RawState is designed to be invoked remotely via a Windows Task Scheduler
task triggered by a Discord bot (OpenClaw).

**Task Scheduler action:**
```
Program : pwsh.exe
Arguments: -NonInteractive -File C:\OpenClaw\RawState_v5.ps1 -Mode Toggle -OutputFormat Json -Quiet
```

The `-OutputFormat Json -Quiet` flags emit a single compressed JSON object
to stdout for the bot to parse:

```json
{"Success":true,"GamingMode":"Enabled","Message":"RawState active.","AppliedTweaks":["TCP","MMCSS","Win32Priority","Power","CoreParking","BCDEdit","NIC","NIC_PowerMgmt","Psched","PowerThrottle","FSO_GameDVR","VisualEffects","NetshTCP"],"RequiresReboot":true}
```

> **Important:** HKCU tweaks (GameDVR, FSO, VisualEffects, GameBar) only
> apply to the registry hive of the user the process runs as. Configure
> the Task Scheduler task to run as the **gaming user's account** with
> highest privileges — not as SYSTEM.

---

## License

FTS: RawState | Asymmetric Honor License — see [LICENSE](LICENSE).

State 0: free, permanently, irrevocably.
State 1: honor system. You know who you are.

---

*Built by Glenn Mesel / [dedsec.app](https://dedsec.app)*
