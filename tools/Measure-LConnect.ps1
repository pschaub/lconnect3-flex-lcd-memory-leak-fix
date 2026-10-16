<#
.SYNOPSIS
    Samples LConnectService memory and the size of every slv3.WinUsb.rxList queue.

.DESCRIPTION
    Run from an elevated PowerShell 7 (pwsh). Each sample takes a process snapshot
    (PssCaptureSnapshot) and reads the managed heap with ClrMD, so the service keeps running.
    Microsoft.Diagnostics.Runtime 3.1.512801 is downloaded from nuget.org and verified
    against a pinned SHA256 unless -ClrMdPath is given.

    Writes one CSV row per sample to -OutFile and prints a summary line.

.EXAMPLE
    Restart-Service LConnectService; Start-Sleep 60
    .\tools\Measure-LConnect.ps1 -OutFile before.csv -Samples 15 -IntervalSeconds 60
#>
param(
    [Parameter(Mandatory)] [string]$OutFile,
    [int]$Samples = 15,
    [int]$IntervalSeconds = 60,
    [string]$ClrMdPath
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Run this with PowerShell 7 (pwsh).' }
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture

$ClrMdUrl  = 'https://www.nuget.org/api/v2/package/Microsoft.Diagnostics.Runtime/3.1.512801'
$ClrMdHash = '9C3134708F685463C4E1A2AC9AAF35A23462CD90BF3A2FB95B837DEDB8377380'

if (-not $ClrMdPath) {
    $dir = Join-Path $env:LOCALAPPDATA 'LConnectRxQueueFix\Microsoft.Diagnostics.Runtime.3.1.512801'
    $ClrMdPath = Join-Path $dir 'lib\net6.0\Microsoft.Diagnostics.Runtime.dll'
    if (-not (Test-Path -LiteralPath $ClrMdPath)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $zip = Join-Path $dir 'package.zip'
        Invoke-WebRequest -Uri $ClrMdUrl -OutFile $zip
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $ClrMdHash) {
            Remove-Item -LiteralPath $zip; throw 'ClrMD download hash mismatch.'
        }
        Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
    }
}

Add-Type -Path $ClrMdPath
$refs = @(Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object FullName) + $ClrMdPath
Add-Type -ReferencedAssemblies $refs -CompilerOptions '/nowarn:1701,1702' -TypeDefinition @'
using System.Collections.Generic;
using Microsoft.Diagnostics.Runtime;

public class RxQueue { public string Device; public int Pid; public long Entries; public ulong StructureBytes; }

public static class RxQueueProbe {
    static bool IsWinUsb(ClrType t) { for (; t != null; t = t.BaseType) if (t.Name == "slv3.WinUsb") return true; return false; }

    public static List<RxQueue> Read(ClrRuntime runtime) {
        var result = new List<RxQueue>();
        foreach (var dev in runtime.Heap.EnumerateObjects()) {
            if (dev.Type == null || !IsWinUsb(dev.Type)) continue;
            var queue = dev.ReadObjectField("rxList");
            if (queue.IsNull) continue;
            var q = new RxQueue { Device = dev.Type.Name };
            try { q.Pid = dev.ReadField<int>("Pid"); } catch { try { q.Pid = dev.ReadField<int>("<Pid>k__BackingField"); } catch { } }
            // .NET Framework 4.x ConcurrentQueue<T>: linked list of segments (m_head .. m_next).
            var seen = new HashSet<ulong>();
            for (var seg = queue.ReadObjectField("m_head"); !seg.IsNull && seen.Add(seg.Address); seg = seg.ReadObjectField("m_next")) {
                var array = seg.ReadObjectField("m_array");
                var state = seg.ReadObjectField("m_state");
                q.StructureBytes += seg.Size + array.Size + state.Size;
                foreach (var item in array.EnumerateReferences(false, false)) q.Entries++;
            }
            result.Add(q);
        }
        return result;
    }
}
'@

$dac = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\mscordacwks.dll'
$rows = [Collections.Generic.List[object]]::new()

for ($i = 1; $i -le $Samples; $i++) {
    if ($i -gt 1) { Start-Sleep -Seconds $IntervalSeconds }
    $svc = Get-CimInstance Win32_Service -Filter "Name='LConnectService'"
    $proc = Get-Process -Id $svc.ProcessId
    $target = [Microsoft.Diagnostics.Runtime.DataTarget]::CreateSnapshotAndAttach($proc.Id)
    try { $queues = [RxQueueProbe]::Read($target.ClrVersions[0].CreateRuntime($dac)) } finally { $target.Dispose() }

    $row = [pscustomobject]@{
        Sample         = $i
        UptimeSeconds  = [int]((Get-Date) - $proc.StartTime).TotalSeconds
        PrivateMiB     = [math]::Round($proc.PrivateMemorySize64 / 1MB, 1)
        WorkingSetMiB  = [math]::Round($proc.WorkingSet64 / 1MB, 1)
        RxQueues       = $queues.Count
        RxActiveQueues = @($queues | Where-Object Entries -gt 0).Count
        RxEntriesTotal = [long]($queues | Measure-Object Entries -Sum).Sum
        RxEntriesMax   = [long]($queues | Measure-Object Entries -Maximum).Maximum
        RxQueueBytes   = [long]($queues | Measure-Object StructureBytes -Sum).Sum
    }
    $rows.Add($row)
    $rows | Export-Csv -LiteralPath $OutFile -NoTypeInformation
    Write-Host ("{0}/{1} uptime={2}s private={3}MiB rxEntries={4} rxBytes={5}" -f $i, $Samples, $row.UptimeSeconds, $row.PrivateMiB, $row.RxEntriesTotal, $row.RxQueueBytes)
}
