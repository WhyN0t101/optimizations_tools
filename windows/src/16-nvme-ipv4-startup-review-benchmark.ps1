#region NVMe, IPv4, startup review, benchmark ------------------------------------------------
function Set-NvmeNativeDriver {
    # The native NVMe stack ships with Windows 11 24H2 (build 26100). On older builds the overrides do nothing useful.
    if ([Environment]::OSVersion.Version.Build -lt 26100) { Write-Log 'Native NVMe driver needs Windows 11 24H2 (build 26100) or later, skipped.' 'WARN'; return }
    Set-TweakList $NvmeRegs
    if (-not $script:DryRun) { Write-Log 'Native NVMe driver switched on. It takes effect after a restart; -Revert switches it off again.' 'WARN' }
}

function Set-IPv4Only {
    # Only IPv6 is unbound. Ultimate also unbinds file sharing, the SMB client and QoS, which breaks network shares.
    $bindings = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object {
            Get-NetAdapterBinding -Name $_.Name -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue
        } | Where-Object { $_.Enabled })
    if ($bindings.Count -eq 0) { Write-Log 'IPv4 only: IPv6 is already off on every physical adapter.'; return }
    foreach ($b in $bindings) {
        if (Test-DryRun "turn off IPv6 on adapter '$($b.Name)' (the connection drops for a moment)") { continue }
        if (-not (Test-RecordedFirst $script:State.NetBindings { param($e) $e.Name -eq $b.Name })) {
            Add-StateRecord -Section 'NetBindings' -Item ([pscustomobject]@{ Name = $b.Name; ComponentId = 'ms_tcpip6' })
        }
        Disable-NetAdapterBinding -Name $b.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop
        Write-Log "IPv6 turned off on '$($b.Name)'." 'OK'
    }
}

function Restore-NetBindings {
    foreach ($b in $script:State.NetBindings) {
        if ($b.ComponentId -ne 'ms_tcpip6') { Write-Log "Unexpected saved binding '$($b.ComponentId)', not restoring it." 'WARN'; continue }
        try { Enable-NetAdapterBinding -Name $b.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop; Write-Log "IPv6 turned back on for '$($b.Name)'." 'OK' }
        catch { Write-Log "Could not turn IPv6 back on for '$($b.Name)' (adapter renamed or removed?). $($_.Exception.Message)" 'WARN' }
    }
}

function Show-StartupReview {
    # Lists what starts with Windows, for a person to review. Changes nothing (RunKeys is the option that clears).
    $rows = [System.Collections.Generic.List[object]]::new()
    $runKeys = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    foreach ($k in $runKeys) {
        $key = Open-RegKey -Full $k
        if (-not $key) { continue }
        try { foreach ($n in $key.GetValueNames()) { $rows.Add([pscustomobject]@{ Kind = 'Run key'; Name = $n; Command = [string]$key.GetValue($n); Where = $k }) } }
        finally { $key.Close() }
    }
    foreach ($dir in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            $rows.Add([pscustomobject]@{ Kind = 'Startup folder'; Name = $f.Name; Command = $f.FullName; Where = $dir })
        }
    }
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' })) {
        $triggers = @($t.Triggers | ForEach-Object { $_.CimClass.CimClassName })
        if (-not ($triggers -match 'Logon|Boot')) { continue }
        $rows.Add([pscustomobject]@{ Kind = 'Task'; Name = "$($t.TaskPath)$($t.TaskName)"; Command = (@($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join '; '); Where = ($triggers -join ', ') })
    }
    foreach ($s in @(Get-CimInstance -ClassName Win32_Service -Filter "StartMode = 'Auto'" -ErrorAction SilentlyContinue)) {
        $exe = ([string]$s.PathName) -replace '^"([^"]+)".*$', '$1' -replace '^(\S+\.exe).*$', '$1'
        $company = ''
        try { $company = [string](Get-Item -LiteralPath $exe -ErrorAction Stop).VersionInfo.CompanyName } catch { $company = '' }   # driver paths and svchost groups have no readable file here
        if ($company -match 'Microsoft') { continue }
        $rows.Add([pscustomobject]@{ Kind = 'Service'; Name = "$($s.Name) ($($s.DisplayName))"; Command = $s.PathName; Where = $(if ($company) { $company } else { 'unknown publisher' }) })
    }
    $file = Join-Path $StateDir ('startup-review-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date))
    $text = ($rows | Sort-Object Kind, Name | Format-Table Kind, Name, Command, Where -AutoSize -Wrap | Out-String -Width 220)
    Set-Content -LiteralPath $file -Value $text -Encoding UTF8
    if (-not $Json) { Write-Host $text }
    Write-Log "Startup review: $($rows.Count) entr(ies), nothing was changed. Saved to $file. Autoruns (installed by Packages) shows more detail."
}

function Get-TimerResolution {
    if (-not ('Native.NtTimer' -as [type])) {
        Add-Type -Namespace Native -Name NtTimer -MemberDefinition @'
[DllImport("ntdll.dll")]
public static extern int NtQueryTimerResolution(out uint minimum, out uint maximum, out uint actual);
'@
    }
    $min = [uint32]0; $max = [uint32]0; $now = [uint32]0
    [void][Native.NtTimer]::NtQueryTimerResolution([ref]$min, [ref]$max, [ref]$now)
    # Units of 100 ns; reported in milliseconds.
    return [pscustomobject]@{ CurrentMs = [Math]::Round($now / 10000, 3); FinestMs = [Math]::Round($max / 10000, 3); CoarsestMs = [Math]::Round($min / 10000, 3) }
}

function Get-Stats {
    # Median, minimum, maximum and mean of a set of samples, so one noisy sample cannot pass for a result.
    param([double[]]$Values)
    $v = @($Values | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    $mid = [int][Math]::Floor($v.Count / 2)
    $median = if ($v.Count % 2) { $v[$mid] } else { ($v[$mid - 1] + $v[$mid]) / 2 }
    $sum = 0.0; foreach ($x in $v) { $sum += $x }
    return [ordered]@{ Median = [Math]::Round($median, 3); Min = [Math]::Round($v[0], 3); Max = [Math]::Round($v[-1], 3); Mean = [Math]::Round($sum / $v.Count, 3); Samples = $v.Count }
}

function Test-VirtualMachine {
    param([string]$Manufacturer, [string]$Model)
    return ("$Manufacturer $Model" -match 'VMware|VirtualBox|innotek|Virtual Machine|QEMU|KVM|Xen|Parallels|Bochs|BHYVE')
}

function Get-BenchmarkMachine {
    # What must be the same for two benchmarks to be comparable.
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $cpu = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)[0]
    return [ordered]@{
        CPU               = $(if ($cpu) { ([string]$cpu.Name).Trim() } else { 'unknown' })
        LogicalProcessors = $(if ($cs) { [int]$cs.NumberOfLogicalProcessors } else { 0 })
        RamGB             = $(if ($cs) { [Math]::Round([double]$cs.TotalPhysicalMemory / 1GB) } else { 0 })
        VirtualMachine    = $(if ($cs) { [bool](Test-VirtualMachine -Manufacturer $cs.Manufacturer -Model $cs.Model) } else { $false })
        PowerSource       = (Get-PowerSource)
    }
}

function Get-ActivePlanName {
    # powercfg prints '<label>: <GUID>  (<name>)' in the Windows language. The name can hold brackets itself
    # ('Tweaked Performance (High)'), so take everything between the first bracket after the GUID and the last one.
    param([string]$Text = ((powercfg /getactivescheme) | Out-String))
    $m = [regex]::Match($Text.Trim(), '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\s+\((.*)\)\s*$')
    if ($m.Success) { return $m.Groups[2].Value }
    return $Text.Trim()
}

# A benchmark whose CPU use during the idle window has a median above this was taken while Windows was busy
# (updates, Store, indexing, startup work); its numbers include that work.
$BenchmarkBusyPercent = 20

function Test-BenchmarkBusy {
    # The busy median of a saved or new benchmark, or $null when it was not busy (or the metric is missing).
    param($Result)
    $p = @($Result.Metrics.PSObject.Properties | Where-Object { $_.Name -like 'Idle CPU over*' })[0]
    if (-not $p -or -not $p.Value) { return $null }
    if ([double]$p.Value.Median -gt $BenchmarkBusyPercent) { return [double]$p.Value.Median }
    return $null
}

function Get-BootTimesSinceBoot {
    # Boot time events (Diagnostics-Performance event 100), newest first, but only when the newest one belongs to the
    # current boot. Windows writes it a few minutes after sign in, and not at all while the Diagnostic Policy Service
    # is disabled (SvcDiagnostics); older events would repeat the previous result as if it were new.
    # Returns Current ($false when the newest event is older than the last boot) and Times in seconds.
    param([int]$Max, [datetime]$LastBoot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime,
        [object[]]$Events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents $Max -ErrorAction SilentlyContinue))
    $result = [pscustomobject]@{ Current = $true; Times = @() }
    if ($Events.Count -eq 0) { return $result }
    if ($Events[0].TimeCreated -lt $LastBoot) { $result.Current = $false; return $result }
    $result.Times = @($Events | ForEach-Object { [double](@(([xml]$_.ToXml()).Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' })[0].'#text') / 1000 })
    return $result
}

function Get-BenchmarkSettings {
    # What the options change. Recorded with every benchmark and shown when it differs, but it does not block a
    # comparison: comparing before and after a run is the point.
    $mm = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'FeatureSettingsOverride'
    $mpo = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\Dwm' -Name 'OverlayTestMode'
    $overlay = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name "ActiveOverlay$(Get-PowerSource)PowerScheme"
    $overlayGuid = '00000000-0000-0000-0000-000000000000'
    if ($overlay.Existed -and $overlay.Value) { $overlayGuid = ([string]$overlay.Value).ToLowerInvariant() }
    $vbs = @(Get-CimInstance -Namespace 'root/Microsoft/Windows/DeviceGuard' -ClassName 'Win32_DeviceGuard' -ErrorAction SilentlyContinue)[0]
    $vbsText = 'unknown'
    if ($vbs) { $vbsText = switch ([int]$vbs.VirtualizationBasedSecurityStatus) { 0 { 'off' } 1 { 'enabled, not running' } 2 { 'running' } default { 'unknown' } } }
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $mode = $PowerOverlayNames[$overlayGuid]
    if (-not $mode) { $mode = $overlayGuid }
    return [ordered]@{
        'Power plan'                   = Get-ActivePlanName
        'Power mode'                   = $mode
        'VBS (core isolation)'         = $vbsText
        'Hypervisor present'           = $(if ($cs) { [bool]$cs.HypervisorPresent } else { $false })
        'Spectre/Meltdown mitigations' = $(if ($mm.Existed -and [int]$mm.Value -eq 3) { 'off' } else { 'on' })
        'Multiplane overlay'           = $(if ($mpo.Existed -and [int]$mpo.Value -eq 5) { 'off' } else { 'on' })
        'Timer service'                = $(if (Get-Service -Name $TimerServiceName -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }) { 'running' } else { 'not running' })
    }
}

function Measure-MicroOnce {
    # One repetition of the short measurements. They time a PowerShell loop, so they show changes in timer,
    # scheduling and kernel call overhead, not application speed.
    $watch = [Diagnostics.Stopwatch]::new(); $sleeps = 100
    $watch.Start(); for ($i = 0; $i -lt $sleeps; $i++) { [Threading.Thread]::Sleep(1) }; $watch.Stop()
    $sleep = $watch.Elapsed.TotalMilliseconds / $sleeps
    $probe = Join-Path $env:SystemRoot 'System32\kernel32.dll'; $calls = 20000
    $watch.Restart(); for ($i = 0; $i -lt $calls; $i++) { [void][IO.File]::Exists($probe) }; $watch.Stop()
    $kernel = $watch.Elapsed.TotalMilliseconds * 1000 / $calls
    $watch.Restart(); $x = 0; for ($i = 0; $i -lt 3000000; $i++) { $x = ($x + $i) % 1000003 }; $watch.Stop()
    return @($sleep, $kernel, $watch.Elapsed.TotalMilliseconds)
}

function Get-BenchmarkComparison {
    # Compares two benchmark results. Refuses when the machine context differs (another CPU, RAM size, power source,
    # VM or not), because then the numbers say nothing about the options. Settings that differ are listed.
    param([Parameter(Mandatory)]$Now, [Parameter(Mandatory)]$Before)
    $result = [pscustomobject]@{ Refused = $false; Reason = ''; Rows = @(); SettingChanges = @() }
    if (-not $Before.PSObject.Properties['Format'] -or [int]$Before.Format -lt 2) {
        $result.Refused = $true; $result.Reason = 'it uses the old format (one sample per measurement, no machine context)'; return $result
    }
    $diff = @(foreach ($p in $Now.Machine.PSObject.Properties) {
            $old = $Before.Machine.PSObject.Properties[$p.Name]
            if (-not $old -or [string]$old.Value -ne [string]$p.Value) { '{0}: {1} -> {2}' -f $p.Name, $(if ($old) { $old.Value } else { '?' }), $p.Value }
        })
    if ($diff.Count -gt 0) { $result.Refused = $true; $result.Reason = "the machine context differs ($($diff -join '; '))"; return $result }
    $result.SettingChanges = @(foreach ($p in $Now.Settings.PSObject.Properties) {
            $old = $Before.Settings.PSObject.Properties[$p.Name]
            if ($old -and [string]$old.Value -ne [string]$p.Value) { '{0}: {1} -> {2}' -f $p.Name, $old.Value, $p.Value }
        })
    $result.Rows = @(foreach ($p in $Now.Metrics.PSObject.Properties) {
            $n = $p.Value; $o = $null
            if ($Before.Metrics.PSObject.Properties[$p.Name]) { $o = $Before.Metrics.($p.Name) }
            if ($null -eq $n -or $null -eq $o) { continue }
            # Invariant culture: the log reads the same on every system, whatever its decimal separator.
            $inv = [Globalization.CultureInfo]::InvariantCulture
            $change = ''
            if ([double]$o.Median -ne 0) { $change = [string]::Format($inv, '{0:+0.0;-0.0;0}%', (([double]$n.Median - [double]$o.Median) / [double]$o.Median) * 100) }
            $overlap = ([double]$n.Min -le [double]$o.Max) -and ([double]$o.Min -le [double]$n.Max)
            [pscustomobject]@{ Measurement = $p.Name; Now = [string]::Format($inv, '{0} [{1}..{2}]', [double]$n.Median, [double]$n.Min, [double]$n.Max); Before = [string]::Format($inv, '{0} [{1}..{2}]', [double]$o.Median, [double]$o.Min, [double]$o.Max); Change = $change; Note = $(if ($overlap) { 'within noise (ranges overlap)' } else { '' }) }
        })
    return $result
}

function Invoke-Benchmark {
    # docs/AUDIT.md B-01: repeated measurements with median and range, the idle footprint over a fixed window, and the
    # context that decides whether two benchmarks can be compared. Changes nothing.
    $machine = Get-BenchmarkMachine
    Write-Log "Benchmark: $BenchmarkRuns repetition(s), then $BenchmarkIdleSeconds s of idle sampling. Close other programs and leave the PC alone."
    if ($machine.VirtualMachine) { Write-Log 'This is a virtual machine: the hypervisor decides timers and interrupts here, so these numbers check that options took effect and are not performance evidence.' 'WARN' }
    if ($machine.PowerSource -eq 'Dc') { Write-Log 'Running on battery: compare only with benchmarks also taken on battery.' 'WARN' }
    $settings = Get-BenchmarkSettings
    $timer = Get-TimerResolution
    $micro = @(for ($r = 1; $r -le $BenchmarkRuns; $r++) { , (Measure-MicroOnce) })
    $process = @(Get-Process -ErrorAction SilentlyContinue).Count
    $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }).Count
    $memory = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue
    # Processor counters through WMI: the class and property names are the same in every Windows language.
    $idle = @(for ($i = 0; $i -lt $BenchmarkIdleSeconds; $i++) { Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name = '_Total'"; Start-Sleep -Seconds 1 })
    $bootInfo = Get-BootTimesSinceBoot -Max $BenchmarkRuns
    $boots = @($bootInfo.Times)
    if (-not $bootInfo.Current) {
        Write-Log 'Boot time not measured: Windows has not recorded this boot yet (it does so a few minutes after sign in, and never while the Diagnostic Policy Service is disabled by SvcDiagnostics).' 'WARN'
    }
    $m = [ordered]@{}
    $m['Timer resolution now (ms)'] = Get-Stats @($timer.CurrentMs)
    $m['Sleep(1) actual (ms)'] = Get-Stats @($micro | ForEach-Object { $_[0] })
    $m['Kernel call cost, file check (us)'] = Get-Stats @($micro | ForEach-Object { $_[1] })
    $m['CPU loop, 3M steps (ms)'] = Get-Stats @($micro | ForEach-Object { $_[2] })
    $m["Idle CPU over $BenchmarkIdleSeconds s (%)"] = Get-Stats @($idle | ForEach-Object { [double]$_.PercentProcessorTime })
    # Time share of the CPU spent in DPCs and interrupts, one sample per second. This is not their latency.
    $m['DPC time share (%)'] = Get-Stats @($idle | ForEach-Object { [double]$_.PercentDPCTime })
    $m['Interrupt (ISR) time share (%)'] = Get-Stats @($idle | ForEach-Object { [double]$_.PercentInterruptTime })
    $m['DPCs queued per s'] = Get-Stats @($idle | ForEach-Object { [double]$_.DPCsQueuedPersec })
    $m['Interrupts per s'] = Get-Stats @($idle | ForEach-Object { [double]$_.InterruptsPersec })
    $m['Processes at idle'] = Get-Stats @($process)
    $m['Running services'] = Get-Stats @($services)
    $m['Committed memory (MB)'] = $(if ($memory) { Get-Stats @([double]$memory.CommittedBytes / 1MB) } else { $null })
    $m["Boot time, last $($boots.Count) restart(s) (s)"] = $(if ($boots.Count -gt 0) { Get-Stats $boots } else { $null })
    if ($boots.Count -eq 1) { Write-Log 'Only one boot time is recorded, so the boot time is a single sample.' 'WARN' }
    $now = [pscustomobject]@{
        Format = 2; When = (Get-Date).ToString('o'); Runs = $BenchmarkRuns; IdleSeconds = $BenchmarkIdleSeconds
        ValidForPerformance = (-not $machine.VirtualMachine); Machine = [pscustomobject]$machine; Settings = [pscustomobject]$settings
        Metrics = [pscustomobject]$m
    }
    # Through JSON once, so the run is compared in the same shape as a saved one.
    $now = ConvertTo-Json -InputObject $now -Depth 5 | ConvertFrom-Json
    $busy = Test-BenchmarkBusy $now
    if ($null -ne $busy) { Write-Log "Windows was busy during the idle window (median CPU use $busy %, above $BenchmarkBusyPercent %), so these numbers include background work. Wait until updates and startup work are done, then run the benchmark again." 'WARN' }
    $baselineFile = $null
    if ($BenchmarkBaseline) { $baselineFile = Join-Path $StateDir "benchmark-baseline-$BenchmarkBaseline.json" }
    $before = $null; $beforeName = ''
    if ($baselineFile -and (Test-Path -LiteralPath $baselineFile)) { $before = Get-Content -LiteralPath $baselineFile -Raw | ConvertFrom-Json; $beforeName = "baseline '$BenchmarkBaseline'" }
    elseif (-not $baselineFile) {
        $previous = Get-ChildItem -Path (Join-Path $StateDir 'benchmark-2*.json') -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
        if ($previous) { $before = Get-Content -LiteralPath $previous.FullName -Raw | ConvertFrom-Json; $beforeName = "the benchmark of $($previous.Name -replace '^benchmark-|\.json$', '')" }
    }
    $table = @(foreach ($p in $now.Metrics.PSObject.Properties) { if ($p.Value) { [pscustomobject]@{ Measurement = $p.Name; Median = $p.Value.Median; Min = $p.Value.Min; Max = $p.Value.Max; Samples = $p.Value.Samples } } })
    if (-not $Json) {
        Write-Host ($table | Format-Table -AutoSize | Out-String)
        Write-Host ($settings.GetEnumerator() | ForEach-Object { '{0,-30} {1}' -f $_.Key, $_.Value } | Out-String)
    }
    if ($before) {
        $cmp = Get-BenchmarkComparison -Now $now -Before $before
        if ($cmp.Refused) { Write-Log "Not compared with $beforeName`: $($cmp.Reason). Compare only runs on the same machine and power source." 'WARN' }
        else {
            if (-not $Json) { Write-Host ($cmp.Rows | Format-Table -AutoSize | Out-String) }
            Write-Log "Compared with $beforeName (median [min..max]; lower is better for every measurement; 'within noise' means the ranges overlap)."
            foreach ($c in $cmp.SettingChanges) { Write-Log "  Setting changed since then: $c" }
            $busyBefore = Test-BenchmarkBusy $before
            if ($null -ne $busyBefore) { Write-Log "This comparison is not reliable: Windows was busy during $beforeName (median CPU use $busyBefore %), so the differences include that background work, not only the options." 'WARN' }
            elseif ($null -ne $busy) { Write-Log 'This comparison is not reliable: Windows was busy during this benchmark (see above).' 'WARN' }
        }
    }
    elseif ($baselineFile) {
        ConvertTo-Json -InputObject $now -Depth 5 | Set-Content -LiteralPath $baselineFile -Encoding UTF8
        Write-Log "Saved as baseline '$BenchmarkBaseline'. Run -Benchmark -BenchmarkBaseline $BenchmarkBaseline again after a run and a restart to compare with it." 'OK'
    }
    else { Write-Log 'First benchmark on this machine. Run it again after a run and a restart to compare.' }
    $file = Join-Path $StateDir ('benchmark-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))
    ConvertTo-Json -InputObject $now -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
    Write-Log "Benchmark saved to $file" 'OK'
}

# -FrameBenchmark: frame times of a game, recorded with Intel PresentMon (MIT licence, github.com/GameTechDev/
# PresentMon). It reads the Windows graphics event trace and injects nothing into the game. One pinned release is
# downloaded into the state folder (administrators only) and checked against its SHA256 before every use; nothing is
# installed. To work offline, put that exact file into <state folder>\tools yourself: the hash still has to match.
$PresentMonVersion = '2.6.0'
$PresentMonSha256 = 'B2A706BC6AD475749E3B7E3409263AA1E6906D45BDCF993F6DBC0F660188F1AF'
$PresentMonUrl = "https://github.com/GameTechDev/PresentMon/releases/download/v$PresentMonVersion/PresentMon-$PresentMonVersion-x64.exe"
$PresentMonSession = 'FocusedTweaksFrames'
# Frames slower than this are a pause (loading screen, menu, alt-tab), not stutter, and are left out of the statistics.
$FramePauseMs = 1000
# Seconds cut from the start and the end of each recording, where the scene starts or stops.
$FrameTrimSeconds = 2

function Get-PresentMon {
    $dir = Join-Path $StateDir 'tools'
    $exe = Join-Path $dir "PresentMon-$PresentMonVersion-x64.exe"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Log "Downloading PresentMon $PresentMonVersion from $PresentMonUrl"
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $tmp = "$exe.download"
        try { Invoke-WebRequest -Uri $PresentMonUrl -OutFile $tmp -UseBasicParsing -ErrorAction Stop }
        catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; throw "Could not download PresentMon ($($_.Exception.Message)). Download $PresentMonUrl yourself and put it in $dir." }
        Move-Item -LiteralPath $tmp -Destination $exe -Force
    }
    # Checked every time, not only after the download: the file is run elevated.
    $hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    if ($hash -ne $PresentMonSha256) {
        Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
        throw "PresentMon at $exe does not match the pinned SHA256 for version $PresentMonVersion (got $hash). It was deleted; run again to download it."
    }
    $sig = Get-AuthenticodeSignature -FilePath $exe
    if ($sig.Status -ne 'Valid') { Write-Log "PresentMon matches its pinned SHA256, but Windows reports its signature as $($sig.Status)." 'WARN' }
    return $exe
}

function Get-Percentile {
    # Nearest rank on a sorted array: the value below which P percent of the samples fall.
    param([double[]]$Sorted, [double]$P)
    if ($Sorted.Count -eq 0) { return $null }
    $rank = [int][Math]::Ceiling($P / 100 * $Sorted.Count) - 1
    return $Sorted[[Math]::Max(0, [Math]::Min($rank, $Sorted.Count - 1))]
}

function Read-PresentMonCsv {
    # The frames of the busiest swap chain of one PresentMon CSV. PresentMon writes invariant numbers ('.' decimals)
    # and NA for values it does not have. Lines are read one by one: a long capture has hundreds of thousands.
    param([Parameter(Mandatory)][string[]]$Lines)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $head = @($Lines[0].Split(','))
    $col = @{}
    for ($i = 0; $i -lt $head.Count; $i++) { $col[$head[$i].Trim()] = $i }
    foreach ($need in 'SwapChainAddress', 'MsBetweenPresents') { if (-not $col.ContainsKey($need)) { throw "The PresentMon CSV has no '$need' column. Was it written by PresentMon $PresentMonVersion?" } }
    $get = { param($f, $name) if ($col.ContainsKey($name) -and $col[$name] -lt $f.Count) { $f[$col[$name]] } else { $null } }
    $chains = @{}
    for ($n = 1; $n -lt $Lines.Count; $n++) {
        if (-not $Lines[$n]) { continue }
        $f = $Lines[$n].Split(',')
        $ms = 0.0
        if (-not [double]::TryParse([string](& $get $f 'MsBetweenPresents'), [Globalization.NumberStyles]::Float, $inv, [ref]$ms) -or $ms -le 0) { continue }
        $chain = [string](& $get $f 'SwapChainAddress')
        if (-not $chains.ContainsKey($chain)) { $chains[$chain] = [System.Collections.Generic.List[object]]::new() }
        $shown = [string](& $get $f 'DisplayedTime')
        $chains[$chain].Add([pscustomobject]@{
                Ms = $ms
                Dropped = ($null -ne $shown -and ($shown -eq 'NA' -or $shown -eq '' -or $shown -eq '0' -or $shown -eq '0.000000'))
                Mode = [string](& $get $f 'PresentMode')
                Type = [string](& $get $f 'FrameType')
            })
    }
    if ($chains.Count -eq 0) { return @() }
    $busiest = @($chains.Keys | Sort-Object { $chains[$_].Count } -Descending)[0]
    return $chains[$busiest].ToArray()
}

function Get-FrameStats {
    # Frame time statistics of one recording, all in milliseconds so that lower is better everywhere: average, the
    # 99th and 99.9th percentile (the "1 % and 0.1 % lows" in FPS), spread, stutters per minute (frames taking more
    # than twice the median) and the share of frames never shown. Pauses and the trimmed edges are left out.
    param([object[]]$Frames, [double]$TrimSeconds = $FrameTrimSeconds, [double]$PauseMs = $FramePauseMs)
    $total = 0.0; foreach ($f in $Frames) { $total += $f.Ms }
    $t = 0.0; $kept = [System.Collections.Generic.List[object]]::new(); $pauses = 0
    foreach ($f in $Frames) {
        $t += $f.Ms
        if ($t -lt $TrimSeconds * 1000 -or $t -gt $total - $TrimSeconds * 1000) { continue }
        if ($f.Ms -gt $PauseMs) { $pauses++; continue }
        $kept.Add($f)
    }
    if ($kept.Count -lt 30) { return $null }
    $ms = [double[]]@($kept | ForEach-Object { $_.Ms })
    $sorted = [double[]]@($ms | Sort-Object)
    $sum = 0.0; foreach ($x in $ms) { $sum += $x }
    $avg = $sum / $ms.Count
    $sq = 0.0; foreach ($x in $ms) { $sq += ($x - $avg) * ($x - $avg) }
    $median = Get-Percentile -Sorted $sorted -P 50
    $stutters = @($ms | Where-Object { $_ -gt 2 * $median }).Count
    $modes = @($kept | Group-Object Mode | Sort-Object Count -Descending | ForEach-Object { if ($_.Name) { $_.Name } })
    $generated = @($kept | Where-Object { $_.Type -and $_.Type -ne 'NA' -and $_.Type -ne 'Application' }).Count
    return [pscustomobject]@{
        Frames = $ms.Count; Seconds = [Math]::Round($sum / 1000, 1); Pauses = $pauses
        AvgMs = $avg; P99Ms = (Get-Percentile -Sorted $sorted -P 99); P999Ms = (Get-Percentile -Sorted $sorted -P 99.9)
        StdevMs = [Math]::Sqrt($sq / $ms.Count); StuttersPerMin = $stutters / ($sum / 60000)
        DroppedPct = 100.0 * @($kept | Where-Object { $_.Dropped }).Count / $kept.Count
        PresentMode = $(if ($modes.Count -gt 0) { $modes[0] } else { '' }); GeneratedFrames = $generated
    }
}

function Get-DisplayContext {
    # What must match for two frame benchmarks to be comparable, besides the machine: GPU, resolution, refresh rate.
    $gpu = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1)
    if ($gpu.Count -eq 0) { return [ordered]@{ GPU = 'unknown'; Resolution = 'unknown'; RefreshHz = 0; Driver = 'unknown' } }
    $g = $gpu[0]
    return [ordered]@{ GPU = ([string]$g.Name).Trim(); Resolution = "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)"; RefreshHz = [int]$g.CurrentRefreshRate; Driver = [string]$g.DriverVersion }
}

function Invoke-PresentMonCapture {
    param([string]$Exe, [string]$Process, [int]$Seconds, [string]$Csv)
    $pmArgs = @('--process_name', "`"$Process`"", '--output_file', "`"$Csv`"", '--timed', $Seconds, '--terminate_after_timed',
        '--session_name', $PresentMonSession, '--stop_existing_session', '--no_console_stats', '--v2_metrics')
    $proc = Start-Process -FilePath $Exe -ArgumentList $pmArgs -PassThru -WindowStyle Hidden
    $null = $proc.Handle   # keeps the exit code readable after the process ends
    if (-not $proc.WaitForExit(($Seconds + 60) * 1000)) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        throw "PresentMon did not finish within $($Seconds + 60) s."
    }
    if ($proc.ExitCode -ne 0) { throw "PresentMon exited with code $($proc.ExitCode). Another capture tool (CapFrameX, FrameView, an overlay) may hold the trace; close it and retry." }
    if (-not (Test-Path -LiteralPath $Csv)) { throw "PresentMon wrote no file. Did $Process draw frames during the capture (not minimised, not paused)?" }
}

function Invoke-FrameBenchmark {
    if (-not $FrameProcess) { throw 'Name the game process: -FrameProcess game.exe (Task Manager, Details tab).' }
    $process = [IO.Path]::GetFileName($FrameProcess)
    if ($process -notlike '*.exe') { $process += '.exe' }
    $machine = Get-BenchmarkMachine
    if ($machine.VirtualMachine) { Write-Log 'Frame benchmarks in a virtual machine measure the virtual graphics adapter, not this hardware. Run it on the PC itself.' 'ERROR'; $script:Failures++; return }
    if ($machine.PowerSource -eq 'Dc') { Write-Log 'Running on battery: compare only with frame benchmarks also taken on battery.' 'WARN' }
    $exe = Get-PresentMon
    $base = [IO.Path]::GetFileNameWithoutExtension($process)
    if (-not (Get-Process -Name $base -ErrorAction SilentlyContinue)) {
        Write-Log "Waiting up to 5 minutes for $process. Start the game and go to the scene you test (a built-in benchmark repeats best)."
        $deadline = (Get-Date).AddMinutes(5)
        while (-not (Get-Process -Name $base -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
        if (-not (Get-Process -Name $base -ErrorAction SilentlyContinue)) { throw "$process did not start within 5 minutes. Check the name in Task Manager, Details tab." }
        Write-Log 'Found it. Recording starts in 15 seconds: get into the scene.'
        Start-Sleep -Seconds 15
    }
    $dir = Join-Path $StateDir 'frames'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    # A short first recording is thrown away: shader compilation and asset streaming stutter once.
    Write-Log "Warm-up recording (15 s, not counted), then $FrameRuns recording(s) of $FrameSeconds s. Keep the scene the same and do not alt-tab."
    $runs = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -le $FrameRuns; $i++) {
        $csv = Join-Path $dir "$stamp-$base-run$i.csv"
        $secs = if ($i -eq 0) { 15 } else { $FrameSeconds }
        Invoke-PresentMonCapture -Exe $exe -Process $process -Seconds $secs -Csv $csv
        if ($i -eq 0) { Remove-Item -LiteralPath $csv -Force -ErrorAction SilentlyContinue; continue }
        $stats = Get-FrameStats -Frames @(Read-PresentMonCsv -Lines ([IO.File]::ReadAllLines($csv)))
        if (-not $stats) { Write-Log "Recording $i holds too few frames to count (was the game paused or minimised?)." 'WARN'; continue }
        $runs.Add($stats)
        Write-Log ("Recording {0}: {1:N0} FPS average, {2:N0} FPS 1 % low, {3:N1} stutters per minute, {4} pause(s) left out." -f $i, (1000 / $stats.AvgMs), (1000 / $stats.P99Ms), $stats.StuttersPerMin, $stats.Pauses)
    }
    if ($runs.Count -eq 0) { throw 'No recording held enough frames.' }
    $display = Get-DisplayContext
    $label = if ($FrameLabel) { $FrameLabel } else { 'default' }
    $machineCtx = [ordered]@{}
    foreach ($k in $machine.Keys) { $machineCtx[$k] = $machine[$k] }
    $machineCtx['Process'] = $process; $machineCtx['Label'] = $label
    $machineCtx['GPU'] = $display.GPU; $machineCtx['Resolution'] = $display.Resolution; $machineCtx['RefreshHz'] = $display.RefreshHz
    $settings = Get-BenchmarkSettings
    $settings['GPU driver'] = $display.Driver
    $settings['Present mode'] = (@($runs | ForEach-Object { $_.PresentMode } | Group-Object | Sort-Object Count -Descending)[0].Name)
    $m = [ordered]@{}
    $m['Frame time, average (ms)'] = Get-Stats @($runs | ForEach-Object { $_.AvgMs })
    $m['Frame time, 99th percentile (ms)'] = Get-Stats @($runs | ForEach-Object { $_.P99Ms })
    $m['Frame time, 99.9th percentile (ms)'] = Get-Stats @($runs | ForEach-Object { $_.P999Ms })
    $m['Frame time spread, stdev (ms)'] = Get-Stats @($runs | ForEach-Object { $_.StdevMs })
    $m['Stutters per minute'] = Get-Stats @($runs | ForEach-Object { $_.StuttersPerMin })
    $m['Frames not shown (%)'] = Get-Stats @($runs | ForEach-Object { $_.DroppedPct })
    $now = [pscustomobject]@{
        Format = 2; Kind = 'frames'; When = (Get-Date).ToString('o'); Runs = $runs.Count; Seconds = $FrameSeconds; PresentMon = $PresentMonVersion
        ValidForPerformance = $true; Machine = [pscustomobject]$machineCtx; Settings = [pscustomobject]$settings; Metrics = [pscustomobject]$m
    }
    $now = ConvertTo-Json -InputObject $now -Depth 5 | ConvertFrom-Json
    $avgFps = 1000 / $now.Metrics.'Frame time, average (ms)'.Median
    $lowFps = 1000 / $now.Metrics.'Frame time, 99th percentile (ms)'.Median
    $low01 = 1000 / $now.Metrics.'Frame time, 99.9th percentile (ms)'.Median
    if (-not $Json) {
        Write-Host ("`n{0} ({1}, {2} at {3} Hz): {4:N0} FPS average, {5:N0} FPS 1 % low, {6:N0} FPS 0.1 % low (median of {7} recording(s))`n" -f $process, $label, $display.Resolution, $display.RefreshHz, $avgFps, $lowFps, $low01, $runs.Count)
        Write-Host (@(foreach ($p in $now.Metrics.PSObject.Properties) { [pscustomobject]@{ Measurement = $p.Name; Median = [Math]::Round($p.Value.Median, 2); Min = [Math]::Round($p.Value.Min, 2); Max = [Math]::Round($p.Value.Max, 2) } }) | Format-Table -AutoSize | Out-String)
    }
    if ($display.RefreshHz -gt 0 -and [Math]::Abs($avgFps - $display.RefreshHz) / $display.RefreshHz -lt 0.02) {
        Write-Log "The average sits at the refresh rate ($($display.RefreshHz) Hz): V-Sync, G-Sync/FreeSync or a frame limiter caps it. Average FPS cannot show a difference then; compare the percentiles, spread and stutters, or uncap for the test." 'WARN'
    }
    if (@($runs | Where-Object { $_.GeneratedFrames -gt 0 }).Count -gt 0) { Write-Log 'Frame generation is active. These numbers count only the frames the game rendered.' 'WARN' }
    $before = $null; $beforeName = ''
    $baselineFile = $null
    if ($BenchmarkBaseline) { $baselineFile = Join-Path $StateDir "frames-baseline-$BenchmarkBaseline.json" }
    if ($baselineFile -and (Test-Path -LiteralPath $baselineFile)) { $before = Get-Content -LiteralPath $baselineFile -Raw | ConvertFrom-Json; $beforeName = "baseline '$BenchmarkBaseline'" }
    elseif (-not $baselineFile) {
        $previous = @(Get-ChildItem -Path (Join-Path $StateDir 'frames-2*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object {
                $o = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                if ($o.Machine.Process -eq $process -and $o.Machine.Label -eq $label) { [pscustomobject]@{ File = $_; Data = $o } }
            } | Select-Object -First 1)
        if ($previous.Count -gt 0) { $before = $previous[0].Data; $beforeName = "the frame benchmark of $($previous[0].File.Name -replace '^frames-|\.json$', '')" }
    }
    if ($before) {
        $cmp = Get-BenchmarkComparison -Now $now -Before $before
        if ($cmp.Refused) { Write-Log "Not compared with $beforeName`: $($cmp.Reason)." 'WARN' }
        else {
            if (-not $Json) { Write-Host ($cmp.Rows | Format-Table -AutoSize | Out-String) }
            Write-Log "Compared with $beforeName (median [min..max]; lower is better for every row; 'within noise' means the ranges overlap)."
            foreach ($c in $cmp.SettingChanges) { Write-Log "  Setting changed since then: $c" }
        }
    }
    elseif ($baselineFile) {
        ConvertTo-Json -InputObject $now -Depth 5 | Set-Content -LiteralPath $baselineFile -Encoding UTF8
        Write-Log "Saved as frame baseline '$BenchmarkBaseline'." 'OK'
    }
    else { Write-Log "First frame benchmark of $process with label '$label'. Run it again after a run and a restart, same scene and settings, to compare." }
    $file = Join-Path $StateDir "frames-$stamp.json"
    ConvertTo-Json -InputObject $now -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
    Write-Log "Frame benchmark saved to $file. The raw PresentMon files are in $dir." 'OK'
}
#endregion

