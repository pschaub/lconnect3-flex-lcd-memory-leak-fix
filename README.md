# L-Connect 3 memory leak with FLEX LCD fans (and a patch)

**Problem.** When Lian Li L-Connect 3 plays video on FLEX LCD fan displays, the background service
`LConnectService` stores the display's acknowledgement for every frame in an in-memory queue and never removes it.
Memory grows by about 1.3 MiB per hour per playing LCD fan, without limit, until the service is restarted.
On the test system (four LCD fans) the service had grown to 1.16 GB of private memory; a restart brought it back to
about 650 MB.

**Fix.** [`Patch-LConnectRxQueue.ps1`](Patch-LConnectRxQueue.ps1) caps that queue at 1,024 entries per device by
patching one spot in the installed `lianli.slv3.dll`. It only runs against the exact vendor file listed below,
backs up the original first, and restores it with one command.

Affected version: **L-Connect 3 2.1.29**, the latest version in the
[official changelog](https://lian-li.com/l-connect3/l3-changelog/) when this was tested (October 2026).

## Background

L-Connect 3 runs a Windows service, `LConnectService` (.NET Framework 4.8), that drives fans, pump, sensors, RGB and
the fan and cooler displays over USB. The changelog mentions a memory fix in 2.1.13, but the leak described here is
still present in 2.1.29.

Test system: 4× SL-INF FLEX LCD fans (USB `1CBE:A019`) playing video themes, a HydroShift II OLED Curve cooler
(`1CBE:A068`) and a wireless controller transmitter (`0416:8040`).

## Evidence

The numbers below come from heap snapshots of the running service, taken with
[`tools/Measure-LConnect.ps1`](tools/Measure-LConnect.ps1) (ClrMD), plus Windows process counters.

**Long-running service.** The four USB receive queues (`rxList`) of the four LCD fan device objects held
**19,099,304 entries in 596,857 segments, 227.7 MiB**, all reachable from GC roots. This is a real leak, not garbage
waiting for collection. Each queue referenced the same single 512-byte buffer millions of times.

**Controlled before/after comparison.** The same machine was measured with the same method twice, once with the
original DLL and once with the patched one. Each run started the service fresh, waited 60 s, then took 15 samples
60 s apart.

| uptime | original: entries | original: queue bytes | patched: entries | patched: queue bytes |
|---:|---:|---:|---:|---:|
| 102 s | 9,502 | 123,200 | 4,093 | 54,800 |
| 343 s | 39,062 | 491,600 | 4,093 | 54,400 |
| 585 s | 68,620 | 861,600 | 4,093 | 54,800 |
| 827 s | 98,189 | 1,230,800 | 4,093 | 54,800 |
| 948 s | 112,982 | 1,416,400 | 4,093 | 54,800 |

- **Original:** +7,340 entries/min, about 1,835 per fan, which is about 30.6 per second per fan. That adds
  **+5.25 MiB/h ≈ 126 MiB/day**, linear and with no plateau.
- **Patched:** flat at 4 × ~1,023 entries (≈54 KB in total) from the first sample on.
- Private memory over a 15-minute window (623–731 MiB in both runs) is dominated by normal GC and native noise. The leak
  only becomes visible over hours to days, as the long-running numbers show.

Raw samples: [`data/before.csv`](data/before.csv), [`data/after.csv`](data/after.csv).

## Root cause

The bug is in `lianli.slv3.dll`, class `slv3.WinUsb`, method `OnRxEndPointData`: the LibUsbDotNet `DataReceived`
handler for the device's interrupt endpoint. Every incoming packet whose first byte is not `0x0D`, `0x0F` or `0x28` is
appended to `private ConcurrentQueue<byte[]> rxList` (decompiled excerpt):

```csharp
if (e.Buffer != null && e.Buffer[0] != 13 && e.Buffer[0] != 15 && e.Buffer[0] != 40
    && (!needSyncL3 || (e.Buffer[0] != 103 && e.Buffer[0] != 101)))
    rxList.Enqueue(e.Buffer);
```

- The queue has no size limit. Only `Read()` and `Read(CmdType)` drain it, and they run only when the software sends a
  command and waits for the reply.
- `0x65` (101) is `CmdType.PushJpg`: the LCD's acknowledgement of a pushed image frame. During video playback every
  frame is sent with `isRead: false`, so nothing ever consumes these acknowledgements. Every queued packet on the test
  system started with `0x65`. The measured ~30.6 entries per second per fan matches the 30 fps of the LCD videos: one
  leaked entry per frame shown.
- `0x65` and `0x67` are filtered only while `needSyncL3` is true. The service sets that flag only for display themes
  that contain a GIF or PNG animation module. Turning the flag on is not a fix, because it also switches the display's
  send and sync path.
- LibUsbDotNet reuses `e.Buffer`, so all queued entries point to the same array. The memory goes into the queue's
  segment structure (about 12.5 bytes per entry), and the queue doesn't even keep distinct packets.

## Who is affected

The leak only happens while L-Connect streams image frames to an LCD fan through this USB path.

| Situation | Leak | Basis |
|---|---|---|
| FLEX LCD playing a **video** theme (built-in or custom) | **Yes**, ~1 entry per frame (≈30/s per fan at 30 fps) | Measured |
| Other LCD content pushed continuously as frames (e.g. live sensor layouts) | Likely, at the push rate | Code (same `PushJpg` path), not measured |
| FLEX LCD showing a **static image** | Only a few entries per theme change, no growth | Code (image pushed once or twice) |
| FLEX LCD theme with a **GIF or PNG animation** module | No, the acknowledgements are filtered | Code |
| Fan speed, pump, RGB lighting, sensors, wireless control | No | Measured (the wireless device queues stayed at 0 entries) |

| Device (USB ID) | Status |
|---|---|
| SL-INF FLEX LCD (`1CBE:A019`) | **Affected**, measured |
| TL FLEX LCD (`1CBE:A018`) | **Very likely affected**: it runs through the same code paths as `A019`. Not measured. |
| Older Lian Li LCD devices (`1CBE:0005`, `1CBE:0006`) | Same receive handler, packet behaviour unknown. Not tested. |
| Wireless transmitter/receiver (`0416:8040`, `0416:8041`, PID `8051`) | Not affected (queues stayed at 0 entries) |
| HydroShift II OLED/LCD cooler displays (`1CBE:A068`) | Not affected: they use a separate library (`lcd207.dll`). OLED video was running during the measurement. |

Growth scales with *number of LCD fans × frame rate × uptime*. One fan at 30 fps adds about 1.3 MiB/h
(≈32 MiB/day). Only a service restart clears it. The static-image and GIF rows come from the decompiled code; those
themes were not switched on live during testing.

**Quick check:** if you run L-Connect 3 2.1.29 with FLEX LCD fans playing video and `LConnectService` keeps climbing in
Task Manager over days, you are most likely affected. `tools/Measure-LConnect.ps1` shows it directly: `RxEntriesTotal`
grows steadily.

## Fix

The patch inserts one bound before the `Enqueue`:

```csharp
byte[] result;
while (rxList.Count >= 1024 && rxList.TryDequeue(out result)) { }
rxList.Enqueue(e.Buffer);
```

That is the only change: 10 IL instructions plus one local variable, written with Mono.Cecil. Because every entry
points to the same reused buffer, dropping old entries loses nothing a consumer could have read. `Read(CmdType)`
already discards entries that don't match, and the upload paths reset `rxList` themselves. A proper vendor fix would
copy the received bytes, match replies to requests and drop unsolicited acknowledgements.

**Checked on the test system after patching:** all USB controllers opened, the LCD profiles applied, the OLED video
started, and pump, fans and sensors reported normally through the service's local API. No new exceptions or crash
events appeared, and the patched service ran for more than 3 hours without a restart.

## Compatibility

| | |
|---|---|
| L-Connect 3 | 2.1.29 |
| File | `C:\Program Files\Lian-Li\L-Connect 3\lianli.slv3.dll` |
| Assembly | `lianli.slv3, Version=1.5.0.146` |
| SHA256 original | `1A1711717520DDFF9B789FCD2379C0636062CF199BB0AE38FBBBA2FE040C0317` |
| SHA256 patched | `0C57AE4C55C94F8966D1F0C6BE81E8ECC303CAC536551590A13EA28B60DFDACB` |

The script refuses any other file. The patched output is deterministic, so its hash is pinned too. No vendor binaries
are included here; the script patches your own installed copy.

## Usage

1. Download `Patch-LConnectRxQueue.ps1` from the [latest release](../../releases/latest).
2. Open PowerShell **as administrator** (right-click Start → *Terminal (Admin)*) and change to the download folder.
3. Run the actions you need:

```powershell
powershell -ExecutionPolicy Bypass -File .\Patch-LConnectRxQueue.ps1 -Action Check     # Original / Patched / Unknown, changes nothing
powershell -ExecutionPolicy Bypass -File .\Patch-LConnectRxQueue.ps1 -Action Patch     # backs up, patches, restarts the services
powershell -ExecutionPolicy Bypass -File .\Patch-LConnectRxQueue.ps1 -Action Restore   # puts the original DLL back
```

The script runs in Windows PowerShell 5.1 (`powershell.exe`), which ships with Windows. It downloads Mono.Cecil 0.11.6
from nuget.org and checks it against a pinned SHA256.

`-Action Patch` does the following:
1. Checks the installed DLL against the original SHA256.
2. Backs up the DLL to `%ProgramData%\LConnectRxQueueFix\lianli.slv3.dll.original` (never overwritten) and copies
   `settings`, `device`, `profile` and `slv3\config` from `%ProgramData%\Lian-Li\L-Connect 3`.
3. Builds the patched DLL from the backup and checks its SHA256 before installing anything.
4. Stops `LConnectServiceWatcher`, `LConnectService` and the L-Connect GUI, swaps the file and starts both services
   again. If any step fails, it puts the original back automatically.

Open the L-Connect 3 GUI again afterwards, or sign out and back in.

## Reproducing the measurement

You need an elevated **PowerShell 7** (`pwsh`). The script downloads ClrMD 3.1.512801 from nuget.org and checks its
SHA256. It snapshots the service process, so the service keeps running.

```powershell
Restart-Service LConnectServiceWatcher, LConnectService; Start-Sleep 60
.\tools\Measure-LConnect.ps1 -OutFile before.csv -Samples 15 -IntervalSeconds 60
# patch, wait 60 s, then:
.\tools\Measure-LConnect.ps1 -OutFile after.csv  -Samples 15 -IntervalSeconds 60
```

## Rollback

Run `-Action Restore`. To roll back by hand, stop both services, copy `lianli.slv3.dll.original` over
`lianli.slv3.dll`, then start the services. An L-Connect update replaces the DLL, so run `-Action Check` after every
update.

## Limitations

- Lian Li signs the original DLL with Authenticode, and patching removes that signature. The assembly has no strong
  name, so .NET still loads it, but security tools that require vendor signatures may flag the file.
- This was tested on one system. Other DLL versions are refused on purpose.
- The service's remaining ~650 MiB baseline is not explained by this bug. Native allocations were not examined, so
  this work neither shows nor rules out other leaks.
- This is an unofficial patch, not affiliated with or endorsed by Lian Li. Use it at your own risk.

## Credits and license

The investigation, patch, measurements and this write-up were created with Claude Opus 5.5 (Anthropic).

Scripts and documentation are released under the [MIT License](LICENSE). L-Connect, `lianli.slv3.dll` and all
related names belong to Lian Li Industrial Co., Ltd.
