#region Mouse and registry helper actions -------------------------------------------------
function Sync-MouseSettings {
    if ($Ctx.DryRun) { return }
    if (-not ('Native.User32' -as [type])) {
        Add-Type -Namespace Native -Name User32 -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, int[] pvParam, uint fWinIni);
'@
    }
    $key = 'HKCU:\Control Panel\Mouse'
    $read = {
        param($n, $default)
        $p = Get-ItemProperty -LiteralPath $key -Name $n -ErrorAction SilentlyContinue
        if ($p -and $p.PSObject.Properties[$n]) { [int]$p.$n } else { $default }
    }
    $values = [int[]]@((& $read 'MouseThreshold1' 6), (& $read 'MouseThreshold2' 10), (& $read 'MouseSpeed' 1))
    [void][Native.User32]::SystemParametersInfo(0x0004, 0, $values, 0x03)
}

function Disable-MouseAcceleration {
    # Upstream logic: pick the profile that matches the current display scaling.
    $metrics = Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction SilentlyContinue
    $dpi = if ($metrics -and $metrics.PSObject.Properties['AppliedDPI']) { [int]$metrics.AppliedDPI } else { 96 }
    $scaling = [int]([Math]::Round(($dpi / 96) * 100))
    $mouse = $MouseProfiles[$scaling]
    if (-not $mouse) { Write-Log "Display scaling $scaling% is not supported by the mouse profiles (100, 125, 150, 175, 200, 225). Change it in Display settings, restart and run again." 'WARN'; return }
    Write-Log "Mouse profile for $scaling% display scaling."
    foreach ($path in 'HKEY_CURRENT_USER\Control Panel\Mouse', 'HKEY_USERS\.DEFAULT\Control Panel\Mouse') {
        Set-RegValue -Path $path -Name 'MouseSensitivity' -Value '10' -Type String
        Set-RegValue -Path $path -Name 'MouseSpeed' -Value $mouse.Speed -Type String
        Set-RegValue -Path $path -Name 'MouseThreshold1' -Value $mouse.T1 -Type String
        Set-RegValue -Path $path -Name 'MouseThreshold2' -Value $mouse.T2 -Type String
        if ($mouse.X) {
            Set-RegValue -Path $path -Name 'SmoothMouseXCurve' -Value (ConvertFrom-RegHex $mouse.X) -Type Binary
            Set-RegValue -Path $path -Name 'SmoothMouseYCurve' -Value (ConvertFrom-RegHex $mouse.Y) -Type Binary
        }
        else {
            Remove-RegValue -Path $path -Name 'SmoothMouseXCurve'
            Remove-RegValue -Path $path -Name 'SmoothMouseYCurve'
        }
    }
    Set-RegValue -Path 'HKEY_CURRENT_USER\Control Panel\Desktop' -Name 'Win8DpiScaling' -Value 0
    Set-RegValue -Path 'HKEY_CURRENT_USER\Control Panel\Desktop' -Name 'LogPixels' -Value $mouse.LogPixels
    Set-RegValue -Path 'HKEY_CURRENT_USER\Control Panel\Desktop' -Name 'EnablePerProcessSystemDPI' -Value $mouse.PerProc
    Sync-MouseSettings
}

function Set-MsiMode {
    foreach ($dev in @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue)) {
        $p = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
        Set-RegValue -Path $p -Name 'MSISupported' -Value 1
    }
}

# docs/AUDIT.md B-05: below this much RAM, compression avoids page file reads under load, so it stays on.
$MemoryCompressionMinGB = 32

function Test-MemoryCompressionTarget {
    param([double]$RamGB)
    return $RamGB -ge $MemoryCompressionMinGB
}

function Disable-MemoryCompression {
    $ram = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB
    if (-not (Test-MemoryCompressionTarget -RamGB $ram)) { Write-Log "Memory compression kept (RAM is $([Math]::Round($ram, 1)) GB, the change needs $MemoryCompressionMinGB GB or more)."; return }
    if ($Ctx.Reapply -and -not (Get-MMAgent).MemoryCompression) { return }
    if (Test-DryRun 'disable memory compression') { return }
    if ($null -eq $script:State.MemCompress) { Set-StateValue -Name 'MemCompress' -Value ([bool](Get-MMAgent).MemoryCompression) }
    Disable-MMAgent -MemoryCompression
    Write-Log 'Memory compression disabled (takes effect after a restart).' 'OK'
}

$SleepStudyLogs = 'Microsoft-Windows-SleepStudy/Diagnostic', 'Microsoft-Windows-Kernel-Processor-Power/Diagnostic', 'Microsoft-Windows-UserModePowerService/Diagnostic'

function Disable-SleepStudy {
    if ($Ctx.Reapply -and @($SleepStudyLogs | Where-Object { ((& wevtutil.exe gl $_) | Out-String) -match 'enabled:\s*true' }).Count -eq 0) { return }
    if (Test-DryRun 'turn off the Sleep Study and power diagnostic event logs') { return }
    # Record which logs were on, the first time only, so -Revert turns back on exactly those and no more.
    if ($script:State.SleepStudy -eq $false) {
        Set-StateValue -Name 'SleepStudy' -Value @($SleepStudyLogs | Where-Object { ((& wevtutil.exe gl $_) | Out-String) -match 'enabled:\s*true' })
    }
    foreach ($log in $SleepStudyLogs) {
        & wevtutil.exe sl $log /e:false | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log "wevtutil could not turn off $log ($LASTEXITCODE)." 'WARN' }
    }
}

function Get-MaxPasswordAge {
    # Days, or 'unlimited'. net accounts prints localised labels and words, but its line order is fixed: the third
    # line is the maximum password age, and a number there is days while any word means unlimited.
    $lines = @(& net.exe accounts)
    if ($LASTEXITCODE -ne 0 -or $lines.Count -lt 3) { throw "net accounts failed ($LASTEXITCODE)." }
    $value = ($lines[2] -split ':')[-1].Trim()
    if ($value -match '^\d+$') { return $value }
    return 'unlimited'
}

function Set-PasswordExpiry {
    if ([Environment]::OSVersion.Version.Build -le 19045) { Write-Log 'Password expiry change skipped (Windows 11 only).'; return }
    if ($Ctx.Reapply -and (Get-MaxPasswordAge) -eq 'unlimited') { return }
    if (Test-DryRun 'set the maximum local password age to unlimited') { return }
    if ($script:State.PwAge -eq $false) { Set-StateValue -Name 'PwAge' -Value (Get-MaxPasswordAge) }
    & net.exe accounts /maxpwage:unlimited | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "net accounts /maxpwage:unlimited failed ($LASTEXITCODE)." }
}

function Reset-FaultTolerantHeap {
    if (Test-DryRun 'reset the fault tolerant heap') { return }
    Start-Process rundll32.exe -ArgumentList 'fthsvc.dll, FthSysprepSpecialize' -WindowStyle Hidden
}

function Disable-NotificationSettings {
    $root = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
    $key = Open-RegKey -Full $root
    if (-not $key) { return }
    $subs = @()
    try {
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push(@($key, $root))
        while ($stack.Count -gt 0) {
            $item = $stack.Pop(); $k = $item[0]; $p = $item[1]
            $subs += $p
            foreach ($n in $k.GetSubKeyNames()) {
                $child = $k.OpenSubKey($n)
                if ($child) { $stack.Push(@($child, "$p\$n")) }
            }
            if ($k -ne $key) { $k.Close() }
        }
    }
    finally { $key.Close() }
    foreach ($p in ($subs | Where-Object { $_ -ne $root })) { Set-RegValue -Path $p -Name 'Enabled' -Value 0 }
}

function Reset-ConsentDatabase {
    # Upstream clears the stored app permissions so the privacy denials apply to apps that were already allowed.
    $dir = Join-Path $env:ProgramData 'Microsoft\Windows\CapabilityAccessManager'
    $files = @(Get-ChildItem -Path (Join-Path $dir 'CapabilityConsentStorage.db*') -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return }
    if (Test-DryRun 'back up and delete the capability consent database') { return }
    $backup = Join-Path $StateDir 'consent-db'
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    if (-not $script:State.ConsentDb) {
        foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination $backup -Force }
        Set-StateValue -Name 'ConsentDb' -Value $backup
    }
    Stop-Service -Name camsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    foreach ($f in $files) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop }
        catch { [void](Invoke-AsTI -PsCommand "Remove-Item -LiteralPath $(ConvertTo-PsLiteral $f.FullName) -Force") }
    }
    Write-Log 'Capability consent database reset (backup kept).' 'OK'
}

function Update-UserVisuals {
    if ($Ctx.DryRun) { Write-Log 'DRY RUN, would: refresh user settings and restart Explorer.'; return }
    1..5 | ForEach-Object { & rundll32.exe user32.dll, UpdatePerUserSystemParameters, 1, True; Start-Sleep -Milliseconds 5 }
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
}
#endregion

