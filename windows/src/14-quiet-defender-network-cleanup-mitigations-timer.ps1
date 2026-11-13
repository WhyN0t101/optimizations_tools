#region Quiet Defender, network, cleanup, mitigations, timer ------------------------------
function Wait-TamperProtectionOff {
    # Tamper Protection exists to stop software from changing Defender, so a script cannot and must not switch it off.
    # Ask for it up front instead, with the right Windows Security page open. -Force skips the question.
    if ($Ctx.DryRun -or $Force) { return }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { $tamper = [bool](Get-MpComputerStatus -ErrorAction Stop).IsTamperProtected }
        catch { Write-Log "Defender status is not available, so Tamper Protection was not checked. $($_.Exception.Message)"; return }
        if (-not $tamper) { return }
        Write-Log 'Tamper Protection is on. Defender settings changed by this run (policy values, real time protection) may be ignored or reverted.' 'WARN'
        try { Start-Process 'windowsdefender://threatsettings/' }
        catch { Write-Log "Could not open Windows Security. Open it yourself: Virus and threat protection, Manage settings. $($_.Exception.Message)" 'WARN' }
        $answer = Read-Host 'Turn Tamper Protection off in Windows Security, then press Enter to check again (type SKIP to continue anyway)'
        if ($answer -ceq 'SKIP') { return }
    }
    Write-Log 'Tamper Protection is still on, continuing. Defender changes may not stick; the health check will say so.' 'WARN'
}

function Set-DefenderQuiet {
    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
        if ($status.PSObject.Properties['IsTamperProtected'] -and $status.IsTamperProtected) {
            Write-Log 'Tamper Protection is on, so Defender may ignore or revert these policy values. Turn it off in Windows Security first for a reliable result.' 'WARN'
        }
    }
    catch { Write-Log "Defender status is not available, so Tamper Protection was not checked. $($_.Exception.Message)" }
    Set-TweakList $DefenderQuietRegs
    if (-not $Ctx.DryRun) { Write-Log 'Defender cloud reporting, sample submission, infection reports and notifications are off by policy. Protection stays on.' 'OK' }
}

function Get-NetAdapterTweaks {
    # One tweak per value to write, for the physical adapters only (matched through the adapter GUID).
    param([string[]]$Keywords, [switch]$AllowOff)
    $tweaks = [System.Collections.Generic.List[object]]::new()
    $guids = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { $_.InterfaceGuid })
    $class = Open-RegKey -Full $NetAdapterClassKey
    if (-not $class) { return $tweaks }
    try {
        foreach ($sub in $class.GetSubKeyNames()) {
            if ($sub -notmatch '^\d{4}$') { continue }
            $child = $class.OpenSubKey($sub)
            if (-not $child) { continue }
            try {
                if ($guids -notcontains [string]$child.GetValue('NetCfgInstanceId', '')) { continue }
                $full = "$NetAdapterClassKey\$sub"
                if ($AllowOff) { $tweaks.Add((New-Tweak $full 'PnPCapabilities' 24 'DWord')) }
                $names = @($child.GetValueNames())
                foreach ($kw in $Keywords) {
                    if ($names -notcontains $kw) { continue }
                    if ($child.GetValueKind($kw) -eq [Microsoft.Win32.RegistryValueKind]::DWord) { $tweaks.Add((New-Tweak $full $kw 0 'DWord')) }
                    else { $tweaks.Add((New-Tweak $full $kw '0' 'String')) }
                }
            }
            finally { $child.Close() }
        }
    }
    finally { $class.Close() }
    return $tweaks
}

function Set-NetAdapterOff {
    # The adapter is not restarted here: a restart would drop a remote desktop session. A reboot applies the values.
    param([string]$Label, [string[]]$Keywords, [switch]$AllowOff)
    $tweaks = @(Get-NetAdapterTweaks -Keywords $Keywords -AllowOff:$AllowOff)
    if ($tweaks.Count -eq 0) { Write-Log "$Label`: no matching values on the physical network adapters." 'WARN'; return }
    Set-TweakList $tweaks
    if ($Ctx.DryRun) { return }
    $adapters = @($tweaks | ForEach-Object { $_.Path } | Select-Object -Unique).Count
    Write-Log "$Label`: $($tweaks.Count) value(s) set on $adapters adapter(s). They apply after a restart." 'OK'
}

function Test-ProtectedPath {
    # Never delete the running script, the state folder, or a folder that holds either.
    param([string]$Path, [string[]]$Keep = @($PSCommandPath, $StateDir))
    foreach ($keep in $Keep) {
        if (-not $keep) { continue }
        if ($keep -ieq $Path) { return $true }
        if ($keep.StartsWith($Path.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($Path.StartsWith($keep.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-ReparsePoint {
    param([Parameter(Mandatory)]$Item)
    return [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Get-CleanupTree {
    # Lists everything below a folder without entering junctions or symbolic links. Windows PowerShell 5.1 follows them
    # with -Recurse, and Windows\Temp is writable by standard users, who could plant a link to files elsewhere.
    param([Parameter(Mandatory)][string]$Path)
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        foreach ($child in @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction SilentlyContinue)) {
            $child
            if ($child.PSIsContainer -and -not (Test-ReparsePoint $child)) { $pending.Push($child.FullName) }
        }
    }
}

function Remove-CleanupEntry {
    # Files and links go first. A link is removed as a link only, so its target is never touched.
    param([Parameter(Mandatory)]$Item)
    if (-not (Test-ReparsePoint $Item) -and ($Item.Attributes -band [IO.FileAttributes]::ReadOnly)) {
        [IO.File]::SetAttributes($Item.FullName, [IO.FileAttributes]::Normal)
    }
    if ($Item.PSIsContainer) { [IO.Directory]::Delete($Item.FullName, $false) }
    else { [IO.File]::Delete($Item.FullName) }
}

function Clear-FolderContents {
    param([string]$Label, [string]$Path, [string[]]$Skip = @())
    if (-not (Test-Path -LiteralPath $Path)) { Write-Log "$Label`: $Path does not exist, nothing to do."; return }
    $top = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Where-Object { -not (Test-NameMatch $_.Name $Skip) -and -not (Test-ProtectedPath $_.FullName) })
    $all = @(foreach ($item in $top) {
            $item
            if ($item.PSIsContainer -and -not (Test-ReparsePoint $item)) { Get-CleanupTree -Path $item.FullName }
        })
    $leaves = @($all | Where-Object { -not $_.PSIsContainer -or (Test-ReparsePoint $_) })
    $folders = @($all | Where-Object { $_.PSIsContainer -and -not (Test-ReparsePoint $_) } | Sort-Object { $_.FullName.Length } -Descending)
    # Summed by hand: Measure-Object returns no Sum property for empty input, which fails under StrictMode
    # whenever the folder holds only empty subfolders (a fresh SoftwareDistribution\Download, for example).
    [long]$bytes = 0
    foreach ($leaf in $leaves) { if (-not $leaf.PSIsContainer) { $bytes += $leaf.Length } }
    $mb = [Math]::Round($bytes / 1MB, 1)
    if (Test-DryRun "$Label`: delete $($top.Count) item(s), $mb MB, from $Path (links are removed as links, never followed)") { return }
    $kept = 0
    foreach ($entry in @($leaves) + @($folders)) {
        try { Remove-CleanupEntry -Item $entry }
        catch { $kept++ }   # in use, or changed meanwhile: left in place and counted
    }
    Write-Log "$Label`: cleaned $Path ($($top.Count) top level item(s), $mb MB before). $kept entr(ies) in use and kept." 'OK'
}

function Clear-TempFiles {
    # C:\XboxGames is deliberately not touched: installed Xbox games live there.
    foreach ($path in @($env:TEMP, (Join-Path $env:SystemRoot 'Temp') | Select-Object -Unique)) {
        Clear-FolderContents -Label 'Temp cleanup' -Path $path -Skip 'ft-ti-*'
    }
}

function Stop-ServiceBounded {
    # Stop-Service waits forever for a service that will not stop. Returns $true once it is stopped.
    param([Parameter(Mandatory)][string]$Name, [int]$Seconds = 30)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -eq 'Stopped') { return $true }
    try {
        if ($svc.Status -ne 'StopPending') { $svc.Stop() }
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($Seconds))
        return $true
    }
    catch { return $false }   # timed out, or the service refused the stop request
}

function Clear-UpdateDownloadCache {
    $path = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
    $stopped = @()
    if (Test-DryRun "stop UsoSvc, wuauserv and bits for up to 30 s each while the cache is cleared, then start them again") { $notStopped = @() }
    else {
        # UsoSvc first: while it runs it starts wuauserv again, which made this step wait forever.
        $notStopped = @(foreach ($name in 'UsoSvc', 'wuauserv', 'bits') {
                $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
                if (-not $svc -or $svc.Status -eq 'Stopped') { continue }
                $stopped += $name
                if (-not (Stop-ServiceBounded -Name $name)) { $name }
            })
    }
    if ($notStopped.Count -gt 0) {
        Write-Log "Update cache cleanup skipped: $($notStopped -join ', ') did not stop within 30 s. Windows Update may be installing something; run it again later." 'WARN'
    }
    try { if ($notStopped.Count -eq 0) { Clear-FolderContents -Label 'Update cache cleanup' -Path $path } }
    finally {
        foreach ($name in $stopped) {
            try { Start-Service -Name $name -ErrorAction Stop }
            catch { Write-Log "Could not start service $name again. $($_.Exception.Message)" 'WARN' }
        }
    }
}

function Disable-SpectreMeltdownMitigations {
    Set-TweakList $MitigationRegs
    if (-not $Ctx.DryRun) { Write-Log 'Spectre and Meltdown mitigations are switched off. Restart Windows to apply.' 'WARN' }
}

function Get-BcdValue {
    # Value of one element of the current boot entry, or $null when the entry does not set it.
    param([Parameter(Mandatory)][string]$Name)
    $out = Invoke-Native bcdedit.exe @('/enum', '{current}')
    if ($LASTEXITCODE -ne 0) { throw "bcdedit /enum failed: $($out.Trim())" }
    $m = [regex]::Match($out, "(?m)^$([regex]::Escape($Name))\s+(\S+)\s*$")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Restore-Dep {
    # Kept for state files from v7.4 and older, whose runs could turn DEP off with the removed DepOff option.
    # The saved value comes from a file, so only values bcdedit accepts for nx are passed on.
    $previous = $script:State.Dep.Previous
    if ($previous -and @('OptIn', 'OptOut', 'AlwaysOn', 'AlwaysOff') -notcontains [string]$previous) { throw "Unexpected saved nx value '$previous', not restoring it." }
    if ($previous) { $out = Invoke-Native bcdedit.exe @('/set', 'nx', $previous) }
    else { $out = Invoke-Native bcdedit.exe @('/deletevalue', 'nx') }
    if ($LASTEXITCODE -ne 0 -and ($previous -or (Get-BcdValue 'nx'))) { throw "bcdedit could not restore nx: $($out.Trim())" }
    Write-Log "Data Execution Prevention restored ($(if ($previous) { $previous } else { 'value removed' })). Restart Windows to apply." 'OK'
}

function Get-TimerSkipReason {
    # docs/AUDIT.md B-03: the timer service stays on by default, but only where it pays. Windows 10 ignores the global
    # flag, so the service would raise the resolution for itself only; on a battery machine the 0.5 ms tick keeps the
    # CPU out of deep idle states all the time. -ForcePowerPlanOnLaptop overrides the battery rule, as for the power plan.
    param([int]$Build, [bool]$HasBattery, [bool]$Force)
    if ($Build -lt 22000) { return "Windows 10 (build $Build) honours timer requests per process only, so a service cannot set the timer for other programs" }
    if ($HasBattery -and -not $Force) { return 'a battery was found, and a 0.5 ms timer held all the time drains it (use -ForcePowerPlanOnLaptop to install it anyway)' }
    return $null
}

function Get-TimerSkipReasonHere {
    return Get-TimerSkipReason -Build ([Environment]::OSVersion.Version.Build) -HasBattery ([bool](Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)) -Force ([bool]$ForcePowerPlanOnLaptop)
}

function Install-TimerResolutionService {
    $dir = Join-Path $env:ProgramFiles 'FocusedTweaks'
    $exe = Join-Path $dir 'TimerResolution.exe'
    $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $skip = Get-TimerSkipReasonHere
    if ($skip) { Write-Log "Timer resolution service skipped: $skip." 'WARN'; return }
    if ($Ctx.Reapply -and (Get-Service -Name $TimerServiceName -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })) { return }
    if (Test-DryRun "build $exe with csc.exe, install and start the service '$TimerServiceName', set GlobalTimerResolutionRequests 1") { return }
    if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe was not found at $csc (.NET Framework 4 is required)." }
    Set-StateValue -Name 'TimerService' -Value ([pscustomobject]@{ Name = $TimerServiceName; Dir = $dir; Exe = $exe })
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $existing = Get-Service -Name $TimerServiceName -ErrorAction SilentlyContinue
    if ($existing -and $existing.Status -ne 'Stopped') { Stop-Service -Name $TimerServiceName -Force }
    $source = Join-Path $dir 'TimerResolution.cs'
    Set-Content -LiteralPath $source -Value $TimerServiceSource -Encoding ASCII
    try {
        $out = Invoke-Native $csc @('/nologo', '/target:exe', "/out:$exe", '/reference:System.ServiceProcess.dll', $source)
        if ($LASTEXITCODE -ne 0) { throw "csc.exe failed: $($out.Trim())" }
    }
    finally { Remove-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue }
    if (-not $existing) {
        & sc.exe create $TimerServiceName binPath= "`"$exe`"" start= auto DisplayName= 'Set Timer Resolution (FocusedTweaks)' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "sc.exe create failed ($LASTEXITCODE)." }
    }
    Set-TweakList $TimerGlobalRegs
    Start-Service -Name $TimerServiceName
    Write-Log "Timer resolution service '$TimerServiceName' installed and running ($exe)." 'OK'
}

function Remove-TimerResolutionService {
    # Name and paths are fixed, never read from the saved state file, so a planted state file cannot point this at other files.
    $dir = Join-Path $env:ProgramFiles 'FocusedTweaks'
    $t = [pscustomobject]@{ Name = $TimerServiceName; Dir = $dir; Exe = (Join-Path $dir 'TimerResolution.exe') }
    if (Get-Service -Name $t.Name -ErrorAction SilentlyContinue) {
        Stop-Service -Name $t.Name -Force -ErrorAction SilentlyContinue
        & sc.exe delete $t.Name | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log "sc.exe delete returned $LASTEXITCODE for $($t.Name)." 'WARN' }
    }
    Remove-Item -LiteralPath $t.Exe -Force -ErrorAction SilentlyContinue
    if ((Test-Path -LiteralPath $t.Dir) -and -not (Get-ChildItem -LiteralPath $t.Dir -Force)) { Remove-Item -LiteralPath $t.Dir -Force }
    Write-Log 'Timer resolution service removed.' 'OK'
}
#endregion

