<#
.SYNOPSIS
    Bounds the unbounded USB receive queue (slv3.WinUsb.rxList) in Lian Li L-Connect 3's
    lianli.slv3.dll to stop the LConnectService memory growth.

.DESCRIPTION
    -Action Check    Report whether the installed DLL is original, patched or unknown. No changes.
    -Action Patch    Back up the original DLL and L-Connect settings, patch the DLL, restart the L-Connect services.
    -Action Restore  Put the backed-up original DLL back and restart the L-Connect services.

    The patch only runs against the exact DLL it was written for (SHA256 below).
    Anything else is refused. Patch and Restore need an elevated Windows PowerShell 5.1.

    The patch inserts, before rxList.Enqueue(e.Buffer) in OnRxEndPointData:

        while (rxList.Count >= MaxQueue && rxList.TryDequeue(out _)) { }

    Mono.Cecil 0.11.6 is downloaded from nuget.org and verified against a pinned SHA256.
#>
[CmdletBinding()]
param(
    [ValidateSet('Check', 'Patch', 'Restore')]
    [string]$Action = 'Check',
    [string]$InstallDir = 'C:\Program Files\Lian-Li\L-Connect 3',
    [string]$BackupDir = (Join-Path $env:ProgramData 'LConnectRxQueueFix'),
    [string]$CecilPath
)

$ErrorActionPreference = 'Stop'

$DllName       = 'lianli.slv3.dll'
$OriginalHash  = '1A1711717520DDFF9B789FCD2379C0636062CF199BB0AE38FBBBA2FE040C0317'  # 1.5.0.146, L-Connect 2.1.29
$PatchedHash   = '0C57AE4C55C94F8966D1F0C6BE81E8ECC303CAC536551590A13EA28B60DFDACB'
$MaxQueue      = 1024
$ServiceName   = 'LConnectService'
$WatcherName   = 'LConnectServiceWatcher'
$WasRunning    = @($WatcherName)
$SettingsRoot  = Join-Path $env:ProgramData 'Lian-Li\L-Connect 3'
$SettingsItems = @('settings', 'device', 'profile', 'slv3\config')
$CecilUrl      = 'https://www.nuget.org/api/v2/package/Mono.Cecil/0.11.6'
$CecilHash     = 'D2A23832AAA948BA9A01ACC42B5726E34C5F995958F1B30D45C0E7C70B3A72D5'

$Dll         = Join-Path $InstallDir $DllName
$OriginalBak = Join-Path $BackupDir "$DllName.original"

function Get-Sha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

function Get-DllState {
    if (-not (Test-Path -LiteralPath $Dll)) { return 'Missing' }
    switch (Get-Sha256 $Dll) {
        $OriginalHash { 'Original' }
        $PatchedHash  { 'Patched' }
        default       { 'Unknown' }
    }
}

function Assert-Admin {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this from an elevated Windows PowerShell.'
    }
}

function Get-Cecil {
    if ($CecilPath) { return (Resolve-Path -LiteralPath $CecilPath).Path }
    $dir = Join-Path $BackupDir 'tools\Mono.Cecil.0.11.6'
    $dll = Join-Path $dir 'lib\net40\Mono.Cecil.dll'
    if (Test-Path -LiteralPath $dll) { return $dll }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $zip = Join-Path $dir 'Mono.Cecil.0.11.6.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $CecilUrl -OutFile $zip
    if ((Get-Sha256 $zip) -ne $CecilHash) { Remove-Item -LiteralPath $zip; throw 'Mono.Cecil download hash mismatch.' }
    Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
    return $dll
}

# Returns the patched assembly as a byte array. Never touches the installed file.
function New-PatchedImage([string]$Source) {
    $cecil = Get-Cecil
    Add-Type -LiteralPath $cecil
    Add-Type -LiteralPath (Join-Path (Split-Path $cecil -Parent) 'Mono.Cecil.Rocks.dll')
    $resolver = New-Object Mono.Cecil.DefaultAssemblyResolver
    $resolver.AddSearchDirectory($InstallDir)
    $rp = New-Object Mono.Cecil.ReaderParameters
    $rp.AssemblyResolver = $resolver
    $rp.ReadingMode = [Mono.Cecil.ReadingMode]::Immediate
    $rp.InMemory = $true
    $asm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($Source, $rp)
    try {
        $module = $asm.MainModule
        $type = $module.GetType('slv3.WinUsb')
        if (-not $type) { throw 'Type slv3.WinUsb not found.' }
        $method = $type.Methods | Where-Object Name -eq 'OnRxEndPointData'
        $read = $type.Methods | Where-Object { $_.Name -eq 'Read' -and $_.Parameters.Count -eq 0 }
        if (@($method).Count -ne 1 -or @($read).Count -ne 1) { throw 'OnRxEndPointData/Read() not found.' }

        $body = $method.Body
        [Mono.Cecil.Rocks.MethodBodyRocks]::SimplifyMacros($body)
        $ins = $body.Instructions
        $OC = [Mono.Cecil.Cil.OpCodes]

        # Locate: ldarg.0; ldfld rxList; ldarg e; callvirt get_Buffer; callvirt Enqueue
        $hits = @()
        for ($i = 0; $i -le $ins.Count - 5; $i++) {
            if ($ins[$i].OpCode -eq $OC::Ldarg -and $ins[$i].Operand.Index -eq -1 -and
                $ins[$i + 1].OpCode -eq $OC::Ldfld -and $ins[$i + 1].Operand.Name -eq 'rxList' -and
                $ins[$i + 3].OpCode -eq $OC::Callvirt -and $ins[$i + 3].Operand.Name -eq 'get_Buffer' -and
                $ins[$i + 4].OpCode -eq $OC::Callvirt -and $ins[$i + 4].Operand.Name -eq 'Enqueue') { $hits += $i }
        }
        if ($hits.Count -ne 1) { throw "Expected exactly one rxList.Enqueue site, found $($hits.Count)." }
        $enqStart = $ins[$hits[0]]
        $rxField = $ins[$hits[0] + 1].Operand
        $queueType = $ins[$hits[0] + 4].Operand.DeclaringType   # ConcurrentQueue<byte[]>

        $tryDequeue = $read.Body.Instructions | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'TryDequeue' } | Select-Object -First 1 -ExpandProperty Operand
        if (-not $tryDequeue) { throw 'TryDequeue reference not found.' }
        $getCount = New-Object Mono.Cecil.MethodReference('get_Count', $module.TypeSystem.Int32, $queueType)
        $getCount.HasThis = $true

        $tmp = New-Object Mono.Cecil.Cil.VariableDefinition((New-Object Mono.Cecil.ArrayType($module.TypeSystem.Byte)))
        $body.Variables.Add($tmp)

        $il = $body.GetILProcessor()
        $check = $il.Create($OC::Ldarg_0)
        $new = @(
            $check
            $il.Create($OC::Ldfld, $rxField)
            $il.Create($OC::Callvirt, $getCount)
            $il.Create($OC::Ldc_I4, $MaxQueue)
            $il.Create($OC::Blt, $enqStart)
            $il.Create($OC::Ldarg_0)
            $il.Create($OC::Ldfld, $rxField)
            $il.Create($OC::Ldloca, $tmp)
            $il.Create($OC::Callvirt, $tryDequeue)
            $il.Create($OC::Brtrue, $check)
        )
        # Branches that entered the Enqueue block now enter the bound check first.
        foreach ($x in $ins) {
            if ([object]::ReferenceEquals($x.Operand, $enqStart)) { $x.Operand = $check }
            elseif ($x.Operand -is [Mono.Cecil.Cil.Instruction[]]) {
                $arr = $x.Operand; for ($k = 0; $k -lt $arr.Length; $k++) { if ([object]::ReferenceEquals($arr[$k], $enqStart)) { $arr[$k] = $check } }
            }
        }
        foreach ($h in $body.ExceptionHandlers) {
            foreach ($p in 'TryStart', 'HandlerStart', 'FilterStart') { if ([object]::ReferenceEquals($h.$p, $enqStart)) { $h.$p = $check } }
        }
        foreach ($n in $new) { $il.InsertBefore($enqStart, $n) }
        # The two branches inside the inserted block must keep their own targets.
        $new[4].Operand = $enqStart
        $new[9].Operand = $check
        [Mono.Cecil.Rocks.MethodBodyRocks]::OptimizeMacros($body)

        $ms = New-Object IO.MemoryStream
        $asm.Write($ms)
        return , $ms.ToArray()
    } finally { $asm.Dispose() }
}

function Get-LConnectServices {
    # Watcher first: it would otherwise restart the main service while the DLL is swapped.
    @(Get-Service -Name $WatcherName -ErrorAction SilentlyContinue) + @(Get-Service -Name $ServiceName)
}

function Stop-LConnect {
    $script:WasRunning = @(Get-LConnectServices | Where-Object Status -eq 'Running' | ForEach-Object Name)
    foreach ($svc in Get-LConnectServices) {
        Stop-Service -Name $svc.Name -Force
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
    }
    # The L-Connect 3 GUI may hold the DLL open as well; it is not restarted (reopen it or log on again).
    Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { Write-Host "Stopping $($_.Name) ($($_.Id))"; Stop-Process -Id $_.Id -Force }
    Start-Sleep -Seconds 2
}

function Start-LConnect {
    $services = @(Get-LConnectServices)
    [array]::Reverse($services)
    foreach ($svc in $services) {
        if ($svc.Name -eq $ServiceName -or $script:WasRunning -contains $svc.Name) {
            Start-Service -Name $svc.Name
            $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
        }
    }
}

$state = Get-DllState
Write-Host "Installed $DllName : $state"

switch ($Action) {
    'Check' {
        if (Test-Path -LiteralPath $OriginalBak) { Write-Host "Original backup  : $OriginalBak ($(Get-Sha256 $OriginalBak))" }
        if ($state -eq 'Unknown') { Write-Host "SHA256: $(Get-Sha256 $Dll)" }
    }

    'Patch' {
        Assert-Admin
        if ($state -eq 'Patched') { Write-Host 'Already patched.'; break }
        if ($state -ne 'Original') { throw "Refusing to patch: $Dll does not match the supported original SHA256 $OriginalHash." }

        # 1. Backups (the original DLL backup is never overwritten).
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        if (-not (Test-Path -LiteralPath $OriginalBak)) { Copy-Item -LiteralPath $Dll -Destination $OriginalBak }
        if ((Get-Sha256 $OriginalBak) -ne $OriginalHash) { throw "Existing backup $OriginalBak is not the original DLL." }
        $settingsBak = Join-Path $BackupDir ('settings-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        foreach ($item in $SettingsItems) {
            $src = Join-Path $SettingsRoot $item
            if (Test-Path -LiteralPath $src) {
                $dst = Join-Path $settingsBak $item
                New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
                Copy-Item -LiteralPath $src -Destination $dst -Recurse
            }
        }
        Write-Host "Backups          : $OriginalBak, $settingsBak"

        # 2. Build and verify the patched image before touching the install.
        $image = New-PatchedImage $OriginalBak
        $staged = Join-Path $BackupDir "$DllName.patched"
        [IO.File]::WriteAllBytes($staged, $image)
        $stagedHash = Get-Sha256 $staged
        if ($stagedHash -ne $PatchedHash) { throw "Patched image hash $stagedHash differs from expected $PatchedHash. Nothing was installed." }

        # 3. Swap and restart. Any failure rolls back to the original.
        Stop-LConnect
        try {
            Copy-Item -LiteralPath $staged -Destination $Dll -Force
            if ((Get-Sha256 $Dll) -ne $PatchedHash) { throw 'Installed file hash mismatch after copy.' }
            Start-LConnect
        } catch {
            Write-Warning "Patch failed, restoring original: $_"
            try { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue } catch {}
            Copy-Item -LiteralPath $OriginalBak -Destination $Dll -Force
            Start-LConnect
            throw
        }
        Write-Host 'Patched. Undo with: .\Patch-LConnectRxQueue.ps1 -Action Restore'
    }

    'Restore' {
        Assert-Admin
        if ($state -eq 'Original') { Write-Host 'Original DLL already installed.'; break }
        if (-not (Test-Path -LiteralPath $OriginalBak)) { throw "No backup at $OriginalBak." }
        if ((Get-Sha256 $OriginalBak) -ne $OriginalHash) { throw "Backup $OriginalBak does not match the original SHA256." }
        Stop-LConnect
        Copy-Item -LiteralPath $OriginalBak -Destination $Dll -Force
        Start-LConnect
        Write-Host "Restored original DLL ($(Get-DllState))."
    }
}

