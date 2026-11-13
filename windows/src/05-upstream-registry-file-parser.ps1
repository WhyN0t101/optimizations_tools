#region Upstream registry file parser -----------------------------------------------------
function ConvertFrom-RegHex {
    param([string]$Body)
    $out = [System.Collections.Generic.List[byte]]::new()
    foreach ($tok in ($Body -split ',')) {
        $t = $tok.Trim()
        if ($t) { $out.Add([Convert]::ToByte($t, 16)) }
    }
    , $out.ToArray()
}

function ConvertFrom-RegText {
    param([Parameter(Mandatory)][string]$Text)
    $ops = [System.Collections.Generic.List[object]]::new()
    $rawLines = ($Text -replace "`r`n", "`n" -replace "`r", "`n") -split "`n"

    # Join hex values that continue over several lines with a trailing backslash.
    $lines = [System.Collections.Generic.List[string]]::new()
    $cont = $null
    foreach ($raw in $rawLines) {
        $line = $raw.Trim()
        if ($null -ne $cont) {
            if ($line.EndsWith('\')) { $cont += $line.Substring(0, $line.Length - 1) }
            else { $lines.Add($cont + $line); $cont = $null }
            continue
        }
        if ($line -match '^(?:"[^"]*"|@)=hex(?:\([0-9a-fA-F]+\))?:.*\\$') { $cont = $line.Substring(0, $line.Length - 1); continue }
        $lines.Add($line)
    }

    $group = ''; $key = $null
    foreach ($line in $lines) {
        if (-not $line -or $line.StartsWith('Windows Registry Editor')) { continue }
        if ($line.StartsWith(';')) { $group = $line.TrimStart(';').Trim(); continue }
        if ($line -match '^\[(-?)(.+)\]$') {
            if ($Matches[1] -eq '-') {
                $ops.Add([pscustomobject]@{ Group = $group; Action = 'DeleteKey'; Path = $Matches[2]; Name = $null; Type = $null; Value = $null })
                $key = $null
            }
            else { $key = $Matches[2] }
            continue
        }
        if ($null -eq $key) { continue }
        if ($line -notmatch '^(?:"((?:[^"\\]|\\.)*)"|@)=(.*)$') { continue }
        $name = if ($line[0] -eq '@') { '' } else { [regex]::Replace($Matches[1], '\\(.)', '$1') }
        $rhs = $Matches[2].Trim()
        $op = [pscustomobject]@{ Group = $group; Action = 'Set'; Path = $key; Name = $name; Type = $null; Value = $null }
        if ($rhs -eq '-') { $op.Action = 'DeleteValue' }
        elseif ($rhs -match '^dword:([0-9a-fA-F]{1,8})$') {
            $op.Type = 'DWord'
            $op.Value = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]::Parse($Matches[1], 'AllowHexSpecifier')), 0)
        }
        elseif ($rhs -match '^"(.*)"$') { $op.Type = 'String'; $op.Value = [regex]::Replace($Matches[1], '\\(.)', '$1') }
        elseif ($rhs -match '^hex(?:\(([0-9a-fA-F]+)\))?:(.*)$') {
            $code = if ($Matches[1]) { $Matches[1].ToLowerInvariant() } else { '3' }
            $bytes = ConvertFrom-RegHex $Matches[2]
            $supported = $true
            switch ($code) {
                '3' { $op.Type = 'Binary'; $op.Value = $bytes }
                '0' { $op.Type = 'None'; $op.Value = $bytes }
                '2' { $op.Type = 'ExpandString'; $op.Value = [Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0) }
                '7' { $op.Type = 'MultiString'; $op.Value = [string[]]([Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0) -split [char]0) }
                'b' { $op.Type = 'QWord'; $op.Value = [BitConverter]::ToInt64(($bytes + (New-Object byte[] 8))[0..7], 0) }
                default { $supported = $false }
            }
            if (-not $supported) { continue }
        }
        else { continue }
        $ops.Add($op)
    }
    , $ops
}

function Get-RegGroupOption {
    param([string]$Title)
    switch -Wildcard ($Title) {
        'Disable core isolation*' { return 'CoreIsolation' }
        'Disable user account control' { return 'Uac' }
        'Remove logons' { return 'RunKeys' }
        'Privacy deny*' { return 'PrivacyDenials' }
        'Disable lock' { return 'HideLockOption' }
        'Disable sleep' { return 'HideSleepOption' }
        'Disable hibernate' { return 'RegHibernateOff' }
        'Enable end task*' { return 'TaskbarEndTask' }
        '100% DPI scaling' { return 'ForceDpi100' }
        'Disable fix scaling for apps' { return 'ForceDpi100' }
        'Disable automatic maintenance' { return 'NoAutoMaintenance' }
        # Upstream groups that do the same job as an existing option belong to it, so skipping the option
        # really keeps the feature (before, the Registry option still applied them).
        'Turn off enhance pointer precision' { return 'MouseAccel' }
        'Disable notifications' { return 'NotificationSettings' }
        'Disable sleep study' { return 'SleepStudy' }
        'Disable background apps global' { return 'PrivacyDenials' }
        'Disable fault tolerant heap' { return 'FaultTolerantHeap' }
        'Disable delivery optimization' { return 'SvcDeliveryOpt' }
        'Turn on hardware accelerated GPU scheduling' { return 'HardwareGpuScheduling' }
        default { return 'Registry' }
    }
}

# A single upstream value can need its own option when its side effect is out of proportion to its group.
# NoRecentDocsHistory sits in two unrelated groups and quietly breaks Quick Access pins.
function Get-RegOpOption {
    param($Op)
    if ($Op.Name -eq 'NoRecentDocsHistory') { return 'NoRecentDocsHistory' }
    return Get-RegGroupOption $Op.Group
}

function Show-RegGroups {
    $ops = ConvertFrom-RegText -Text $UpstreamRegText
    $ops | Group-Object Group | ForEach-Object {
        Write-Host ('{0,-22} {1,3} item(s)  {2}' -f (Get-RegGroupOption $_.Name), $_.Count, $_.Name)
    }
}

function Test-HagsDriverSupport {
    # Hardware accelerated GPU scheduling needs a WDDM 2.7 driver (DirectX blog, June 2020). The first field of a
    # display driver's version is the WDDM version it is built for (27 = WDDM 2.7, 31 = WDDM 3.1); the Microsoft Basic
    # Display Adapter reports 10.x. One capable adapter is enough, so hybrid graphics laptops qualify.
    param([string[]]$DriverVersions = @())
    foreach ($v in $DriverVersions) {
        $m = [regex]::Match([string]$v, '^(\d+)\.')
        if ($m.Success -and [int]$m.Groups[1].Value -ge 27) { return $true }
    }
    return $false
}

function Get-GatedRegOptions {
    # Upstream registry options that this machine cannot use, with the reason. Their values are not written, and the
    # health check notes them instead of judging them.
    $gated = @{}
    if ($Opt['HardwareGpuScheduling']) {
        $versions = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.DriverVersion } | Where-Object { $_ })
        if (-not (Test-HagsDriverSupport -DriverVersions $versions)) {
            $found = 'none'; if ($versions.Count -gt 0) { $found = $versions -join ', ' }
            $gated['HardwareGpuScheduling'] = "no display driver is WDDM 2.7 or later (driver versions found: $found)"
        }
    }
    return $gated
}

function Test-StartupKept {
    param([string]$Name)
    return (Test-NameMatch $Name $StartupKeepBuiltIn) -or (Test-NameMatch $Name $StartupKeep)
}

function Remove-StartupEntries {
    # RunKeys: every value of a Run key goes, except the kept ones. Each removal is journaled with its value, so
    # -Revert puts back exactly what was there, and entries added later are never touched by -Revert.
    param([Parameter(Mandatory)][string]$Path)
    $full = ConvertTo-FullRegPath $Path
    $key = Open-RegKey -Full $full
    if (-not $key) { return }
    try { $names = @($key.GetValueNames() | Where-Object { $_ }) } finally { $key.Close() }
    $kept = @($names | Where-Object { Test-StartupKept $_ })
    foreach ($n in @($names | Where-Object { -not (Test-StartupKept $_) })) {
        Remove-RegValue -Path $full -Name $n
        if (-not $script:DryRun -and -not (Get-RegSnapshot -Full $full -Name $n).Existed) { Write-Log "Startup entry removed: $n ($full)" 'OK' }
    }
    if ($kept.Count -gt 0) { Write-Log "Startup entries kept in $full`: $($kept -join ', ')" }
}

function Import-UpstreamRegistry {
    $ops = ConvertFrom-RegText -Text $UpstreamRegText
    $applied = 0; $byOption = 0; $byGroup = 0
    $gated = Get-GatedRegOptions
    foreach ($g in $gated.Keys) { Write-Log "$g skipped on this PC: $($gated[$g])." 'WARN' }
    foreach ($op in $ops) {
        $script:JournalOption = Get-RegOpOption $op
        if (-not $Opt[$script:JournalOption]) { $byOption++; continue }
        if ($gated.ContainsKey($script:JournalOption)) { $byOption++; continue }
        if (Test-NameMatch $op.Group $SkipRegGroup) { $byGroup++; continue }
        switch ($op.Action) {
            'Set' { Set-RegValue -Path $op.Path -Name $op.Name -Value $op.Value -Type $op.Type }
            'DeleteValue' { Remove-RegValue -Path $op.Path -Name $op.Name }
            'DeleteKey' {
                # The Run keys lose their entries one by one, so -StartupKeep can spare some and -Revert restores each.
                if ($script:JournalOption -eq 'RunKeys') { Remove-StartupEntries -Path $op.Path } else { Remove-RegKey -Path $op.Path }
            }
        }
        $applied++
    }
    Write-Log "Registry import: $applied item(s) processed, $byOption left out by option, $byGroup left out by -SkipRegGroup."
}
#endregion

if ($ListRegGroups) { Show-RegGroups; exit 0 }

