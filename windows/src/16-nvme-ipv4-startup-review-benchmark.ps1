#region NVMe, IPv4, startup review, benchmark ------------------------------------------------
function Set-NvmeNativeDriver {
    # The native NVMe stack ships with Windows 11 24H2 (build 26100). On older builds the overrides do nothing useful.
    if ([Environment]::OSVersion.Version.Build -lt 26100) { Write-Log 'Native NVMe driver needs Windows 11 24H2 (build 26100) or later, skipped.' 'WARN'; return }
    Set-TweakList $NvmeRegs
    if (-not $Ctx.DryRun) { Write-Log 'Native NVMe driver switched on. It takes effect after a restart; -Revert switches it off again.' 'WARN' }
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

#endregion

