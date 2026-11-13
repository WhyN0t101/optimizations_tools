#region Registry primitives (full key names, .NET API, TrustedInstaller fallback) ----------
$script:Hives = @{
    'HKEY_LOCAL_MACHINE' = [Microsoft.Win32.RegistryHive]::LocalMachine
    'HKEY_CURRENT_USER'  = [Microsoft.Win32.RegistryHive]::CurrentUser
    'HKEY_USERS'         = [Microsoft.Win32.RegistryHive]::Users
    'HKEY_CLASSES_ROOT'  = [Microsoft.Win32.RegistryHive]::ClassesRoot
}

function ConvertTo-FullRegPath {
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path -replace '^Registry::', ''
    $p = $p -replace '^HKLM:?\\', 'HKEY_LOCAL_MACHINE\'
    $p = $p -replace '^HKCU:?\\', 'HKEY_CURRENT_USER\'
    $p = $p -replace '^HKU:?\\', 'HKEY_USERS\'
    $p = $p -replace '^HKCR:?\\', 'HKEY_CLASSES_ROOT\'
    # Upstream writes to ControlSet001, which is only the active set on most machines. CurrentControlSet always is.
    $p = $p -replace '^HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\', 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\'
    return $p.TrimEnd('\')
}

function Split-RegPath {
    param([string]$Full)
    $i = $Full.IndexOf('\')
    if ($i -lt 0) { return @($Full, '') }
    return @($Full.Substring(0, $i), $Full.Substring($i + 1))
}

function Open-RegKey {
    param([string]$Full, [switch]$Write, [switch]$Create)
    $parts = Split-RegPath $Full
    $hive = $script:Hives[$parts[0].ToUpperInvariant()]
    if ($null -eq $hive) { throw "Unsupported registry root: $($parts[0])" }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Default)
    try {
        if ($Create) { return $base.CreateSubKey($parts[1], $true) }
        return $base.OpenSubKey($parts[1], [bool]$Write)
    }
    finally { $base.Close() }
}

function ConvertTo-StoredValue {
    param($Value, [string]$Kind)
    switch ($Kind) {
        'Binary' { return (($Value | ForEach-Object { '{0:x2}' -f $_ }) -join '') }
        'None' { return '' }
        default { return $Value }
    }
}

function ConvertFrom-StoredValue {
    param($Value, [string]$Kind)
    switch ($Kind) {
        'Binary' {
            $s = [string]$Value
            $bytes = New-Object byte[] ($s.Length / 2)
            for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($s.Substring($i * 2, 2), 16) }
            , $bytes
        }
        'MultiString' { , ([string[]]$Value) }
        'DWord' { [int]$Value }
        'QWord' { [long]$Value }
        default { $Value }
    }
}

function Get-RegSnapshot {
    param([string]$Full, [string]$Name)
    $existed = $false; $kind = $null; $value = $null
    $key = Open-RegKey -Full $Full
    if ($key) {
        try {
            if ($key.GetValueNames() -contains $Name) {
                $existed = $true
                $kind = $key.GetValueKind($Name).ToString()
                $value = ConvertTo-StoredValue -Value $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') -Kind $kind
            }
        }
        finally { $key.Close() }
    }
    [pscustomobject]@{ Path = $Full; Name = $Name; Existed = $existed; Kind = $kind; Value = $value }
}

function Get-MissingKeyEvents {
    # Journal events for the keys a write is about to create, so -Revert can remove them again. Restoring the values
    # alone would leave empty keys behind, and an empty right click menu key still shows up as a menu entry.
    param([string]$Full)
    $missing = @()
    $path = $Full
    while ($path.Contains('\')) {
        try { $key = Open-RegKey -Full $path }
        catch { break }   # exists but is not readable, so it was not created by this run
        if ($key) { $key.Close(); break }
        $missing += $path
        $path = $path.Substring(0, $path.LastIndexOf('\'))
    }
    # Shallowest first, so a rollback, which goes newest first, removes the deepest key before its parent.
    [array]::Reverse($missing)
    foreach ($m in $missing) { if (@($script:State.CreatedKeys) -notcontains $m) { [ordered]@{ Op = 'Add'; Section = 'CreatedKeys'; Item = $m } } }
}

function New-RegChangeEvents {
    # The journal lines that announce one registry write or removal, in the order they apply: the keys it creates, the
    # original value the first time this value is seen (a set gives a fast test; device options record thousands),
    # and last the change itself, which keeps the value as it is right now for a rollback of the step.
    param([string]$Full, [string]$Name, [string]$After, [switch]$SkipKeys)
    $before = Get-RegSnapshot -Full $Full -Name $Name
    if (-not $SkipKeys) { Get-MissingKeyEvents -Full $Full }
    if (-not $script:RecordedReg.Contains("$Full|$Name")) { [ordered]@{ Op = 'Add'; Section = 'Registry'; Item = $before } }
    [ordered]@{ Op = 'Change'; Kind = 'Registry'; Target = "$Full\$(Show-RegName $Name)"; Before = $before; After = $After }
}

function Format-RegIntent {
    param($Value, [string]$Kind)
    if ($Kind -eq 'Binary') { return '<binary> (Binary)' }
    return '{0} ({1})' -f (@($Value) -join ','), $Kind
}

function Complete-RegChange {
    # docs/AUDIT.md A-06: every write is read back. Returns the journal line with OK or MISMATCH; a mismatch is also
    # logged, unless -Quiet (the batched device writes report one summary instead).
    param([Parameter(Mandatory)]$Change, [string]$Full, [string]$Name, $Value, [string]$Kind, [switch]$Quiet)
    $expected = Format-RegIntent -Value $Value -Kind $Kind
    if (Test-RegValueNow -Full $Full -Name $Name -Value $Value -Kind $Kind) { return New-ChangeResult -Change $Change -Result 'OK' -Now $expected }
    $now = Format-RegValueShort (Get-RegSnapshot -Full $Full -Name $Name)
    if (-not $Quiet) { Write-Log "MISMATCH: $Full\$(Show-RegName $Name) reads back as $now, expected $expected. Windows or security software may protect it." 'WARN' }
    return New-ChangeResult -Change $Change -Result 'MISMATCH' -Now $now
}

function Remove-CreatedKeys {
    # Deepest first, and only keys that are empty again: anything added to them since is left alone.
    foreach ($full in @($script:State.CreatedKeys | Sort-Object { $_.Length } -Descending)) { Undo-CreatedKey -Full $full }
}

function Show-RegName { param([string]$Name) if ($Name -eq '') { '(default)' } else { $Name } }

function Invoke-Native {
    # Runs a native command and returns its stdout and stderr as one string; $LASTEXITCODE is set as usual.
    # Windows PowerShell 5.1 turns redirected stderr into error records, which stop the script under 'Stop' as soon
    # as a command prints any error text (2>&1 and *> $null alike), so the redirect runs under 'Continue' here.
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" }) -join "`n" }
    finally { $ErrorActionPreference = $saved }
}

function Test-AccessDenied {
    param($ErrorRecord)
    $e = $ErrorRecord.Exception
    while ($e) {
        if ($e -is [System.UnauthorizedAccessException] -or $e -is [System.Security.SecurityException]) { return $true }
        if ($e.Message -match 'denied|not allowed|privilege') { return $true }
        $e = $e.InnerException
    }
    return $false
}

function Invoke-AsTI {
    # Runs a PowerShell command as TrustedInstaller by briefly pointing the TrustedInstaller service at it.
    # The service path is always restored to the default afterwards.
    param([Parameter(Mandatory)][string]$PsCommand)
    $script:TiCount++
    $flag = Join-Path $env:TEMP ('ft-ti-{0}.done' -f [guid]::NewGuid().ToString('N'))
    $wrapped = "try { $PsCommand } catch { } ; New-Item -ItemType File -Force -Path '$flag' | Out-Null"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapped))
    $tiExe = Join-Path $env:SystemRoot 'servicing\TrustedInstaller.exe'
    $stopTi = {
        try { Stop-Service -Name TrustedInstaller -Force -ErrorAction Stop -WarningAction Stop }
        catch { $null = Invoke-Native taskkill.exe @('/im', 'trustedinstaller.exe', '/f') }
    }
    & $stopTi
    & sc.exe config TrustedInstaller binPath= "cmd.exe /c powershell.exe -NoProfile -EncodedCommand $b64" | Out-Null
    $ok = $false
    try {
        & sc.exe start TrustedInstaller | Out-Null
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Test-Path -LiteralPath $flag) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    }
    finally {
        & sc.exe config TrustedInstaller binPath= "`"$tiExe`"" | Out-Null
        & $stopTi
        $ok = Test-Path -LiteralPath $flag
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }
    return $ok
}

function Repair-TrustedInstallerPath {
    # Invoke-AsTI points the TrustedInstaller service at a command for a moment. If a run was killed in that moment
    # (window closed, power cut), the service keeps that command and Windows servicing and updates fail. Put it back.
    $default = Join-Path $env:SystemRoot 'servicing\TrustedInstaller.exe'
    $snap = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\TrustedInstaller' -Name 'ImagePath'
    if (-not $snap.Existed) { return }
    $now = [Environment]::ExpandEnvironmentVariables([string]$snap.Value).Trim().Trim('"')
    if ($now -ieq $default) { return }
    if (Test-DryRun "repair the TrustedInstaller service path, which points at '$now'") { return }
    & sc.exe config TrustedInstaller binPath= "`"$default`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not repair the TrustedInstaller service path ($LASTEXITCODE). It points at '$now'." }
    Write-Log "TrustedInstaller service path repaired. It pointed at '$now', left by an interrupted run." 'WARN'
}

function ConvertTo-PsLiteral {
    # Single quoted PowerShell string. PowerShell also treats the typographic single quotes as quotes, so they are doubled too.
    param([AllowEmptyString()][string]$Text)
    $quotes = "'" + [string]::Join('', [char[]](0x2018, 0x2019, 0x201A, 0x201B))
    return "'" + [regex]::Replace($Text, '([' + [regex]::Escape($quotes) + '])', '$1$1') + "'"
}

function Format-TiRegAdd {
    param([string]$Full, [string]$Name, $Value, [string]$Kind)
    $q = { param($s) ConvertTo-PsLiteral ([string]$s) }
    $nameArg = if ($Name -eq '') { '/ve' } else { '/v ' + (& $q $Name) }
    switch ($Kind) {
        'DWord' { $t = 'REG_DWORD'; $d = '/d ' + [uint32]([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Value), 0)) }
        'QWord' { $t = 'REG_QWORD'; $d = '/d ' + [uint64]([BitConverter]::ToUInt64([BitConverter]::GetBytes([long]$Value), 0)) }
        'String' { $t = 'REG_SZ'; $d = '/d ' + (& $q $Value) }
        'ExpandString' { $t = 'REG_EXPAND_SZ'; $d = '/d ' + (& $q $Value) }
        'Binary' { $t = 'REG_BINARY'; $d = '/d ' + (& $q (ConvertTo-StoredValue -Value $Value -Kind 'Binary')) }
        'None' { $t = 'REG_NONE'; $d = '' }
        default { throw "Registry type $Kind is not supported through TrustedInstaller." }
    }
    return "& reg.exe add $(& $q $Full) $nameArg /t $t $d /f | Out-Null"
}

function Write-RegRaw {
    param([string]$Full, [string]$Name, $Value, [string]$Kind)
    if ($Kind -eq 'None') {
        $nameArgs = if ($Name -eq '') { @('/ve') } else { @('/v', $Name) }
        & reg.exe add $Full @nameArgs /t REG_NONE /f | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "reg.exe add failed for $Full ($LASTEXITCODE)" }
        return
    }
    $key = Open-RegKey -Full $Full -Create
    try { $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind) }
    finally { $key.Close() }
}

function Test-RegValueNow {
    param([string]$Full, [string]$Name, $Value, [string]$Kind)
    $now = Get-RegSnapshot -Full $Full -Name $Name
    if (-not $now.Existed) { return $false }
    $expected = ConvertTo-StoredValue -Value $Value -Kind $Kind
    return (@($now.Value) -join ',') -eq (@($expected) -join ',')
}

function Test-RegValueIs {
    # True when the value already holds exactly this data and type.
    param([string]$Full, [string]$Name, $Value, [string]$Type)
    $snap = Get-RegSnapshot -Full $Full -Name $Name
    if (-not $snap.Existed -or $snap.Kind -ne $Type) { return $false }
    $want = ConvertTo-StoredValue -Value $Value -Kind $Type
    return ((@($snap.Value) -join ',') -ceq (@($want) -join ','))
}

function Set-RegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'String', 'ExpandString', 'QWord', 'Binary', 'MultiString', 'None')][string]$Type = 'DWord'
    )
    $full = ConvertTo-FullRegPath $Path
    if ($script:Reapply -and (Test-RegValueIs -Full $full -Name $Name -Value $Value -Type $Type)) { return }
    if (Test-DryRun "set $full\$(Show-RegName $Name) = $(if ($Type -eq 'Binary') { '<binary>' } else { $Value }) ($Type)") { return }
    $change = $null
    try {
        $events = @(New-RegChangeEvents -Full $full -Name $Name -After (Format-RegIntent -Value $Value -Kind $Type))
        $change = $events[-1]
        Add-JournalEvents $events
        try { Write-RegRaw -Full $full -Name $Name -Value $Value -Kind $Type }
        catch {
            if (-not (Test-AccessDenied $_)) { throw }
            [void](Invoke-AsTI -PsCommand (Format-TiRegAdd -Full $full -Name $Name -Value $Value -Kind $Type))
        }
        Add-JournalEvents @(Complete-RegChange -Change $change -Full $full -Name $Name -Value $Value -Kind $Type)
    }
    catch {
        $script:Failures++
        Write-Log "Registry write failed: $full\$(Show-RegName $Name). $($_.Exception.Message)" 'ERROR'
        if ($change) { Add-JournalEvents @(New-ChangeResult -Change $change -Result 'FAILED' -Now $_.Exception.Message) }
    }
}

function Remove-RegValueRaw {
    # Deletes one value, falling back to TrustedInstaller when administrators may read the key but not write it. The
    # key is opened inside the try: OpenSubKey(..., $true) itself throws on such keys, and that must reach the fallback.
    param([Parameter(Mandatory)][string]$Full, [Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    if (-not (Get-RegSnapshot -Full $Full -Name $Name).Existed) { return }
    $key = $null
    try {
        $key = Open-RegKey -Full $Full -Write
        if ($key) { $key.DeleteValue($Name, $false) }
    }
    catch {
        if (-not (Test-AccessDenied $_)) { throw }
        $nameArg = if ($Name -eq '') { '/ve' } else { '/v ' + (ConvertTo-PsLiteral $Name) }
        [void](Invoke-AsTI -PsCommand "& reg.exe delete $(ConvertTo-PsLiteral $Full) $nameArg /f | Out-Null")
    }
    finally { if ($key) { $key.Close() } }
    if ((Get-RegSnapshot -Full $Full -Name $Name).Existed) { throw 'The value is still there, even after trying as TrustedInstaller.' }
}

function Remove-RegValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    $full = ConvertTo-FullRegPath $Path
    if ($script:Reapply -and -not (Get-RegSnapshot -Full $full -Name $Name).Existed) { return }
    if (Test-DryRun "delete value $full\$(Show-RegName $Name)") { return }
    $change = $null
    try {
        $events = @(New-RegChangeEvents -Full $full -Name $Name -After '<missing>' -SkipKeys)
        $change = $events[-1]
        Add-JournalEvents $events
        Remove-RegValueRaw -Full $full -Name $Name
        Add-JournalEvents @(New-ChangeResult -Change $change -Result 'OK' -Now '<missing>')
    }
    catch {
        $script:Failures++
        Write-Log "Registry value removal failed: $full\$(Show-RegName $Name). $($_.Exception.Message)" 'ERROR'
        if ($change) { Add-JournalEvents @(New-ChangeResult -Change $change -Result 'FAILED' -Now $_.Exception.Message) }
    }
}

function Remove-RegKey {
    param([Parameter(Mandatory)][string]$Path)
    $full = ConvertTo-FullRegPath $Path
    if ($script:Reapply) {
        $exists = Open-RegKey -Full $full
        if (-not $exists) { return }
        $exists.Close()
    }
    if (Test-DryRun "delete key $full (a backup is exported first)") { return }
    $change = $null
    try {
        $probe = Open-RegKey -Full $full
        if (-not $probe) { return }
        $probe.Close()
        $dir = Join-Path $StateDir 'keys'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        # docs/AUDIT.md A-02: every deletion gets its own export, also on a later run, because the key may hold entries
        # added since the last one. -Revert imports them all, newest first, so the oldest (the original) wins.
        $file = Join-Path $dir ('{0}-{1:yyyyMMdd-HHmmss-fff}.reg' -f ($full -replace '[\\/:*?"<>| {}]', '_'), (Get-Date))
        & reg.exe export $full $file /y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not back up $full, so it was not deleted." }
        $change = [ordered]@{ Op = 'Change'; Kind = 'RegistryKey'; Target = $full; Before = $file; After = '<deleted>' }
        Add-JournalEvents @([ordered]@{ Op = 'Add'; Section = 'KeyBackups'; Item = [pscustomobject]@{ Path = $full; File = $file } }, $change)
        $parts = Split-RegPath $full
        $hive = $script:Hives[$parts[0].ToUpperInvariant()]
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Default)
        try { $base.DeleteSubKeyTree($parts[1], $false) }
        catch {
            if (-not (Test-AccessDenied $_)) { throw }
            [void](Invoke-AsTI -PsCommand "& reg.exe delete $(ConvertTo-PsLiteral $full) /f | Out-Null")
        }
        finally { $base.Close() }
        $gone = $null -eq (Open-RegKey -Full $full)
        Add-JournalEvents @(New-ChangeResult -Change $change -Result $(if ($gone) { 'OK' } else { 'MISMATCH' }) -Now $(if ($gone) { '<deleted>' } else { 'still present' }))
        if (-not $gone) { Write-Log "MISMATCH: the key $full is still present after deleting it." 'WARN' }
    }
    catch {
        $script:Failures++
        Write-Log "Registry key removal failed: $full. $($_.Exception.Message)" 'ERROR'
        if ($change) { Add-JournalEvents @(New-ChangeResult -Change $change -Result 'FAILED' -Now $_.Exception.Message) }
    }
}

function Restore-KeyBackups {
    # Newest export first: where exports of the same key overlap, the oldest one, the original, is imported last and
    # wins, while entries that only a later export holds come back too. reg.exe reports success on stderr, which
    # Windows PowerShell 5.1 turns into an error record that stops the step even when redirected, so cmd.exe
    # swallows the output and only the exit code counts.
    $backups = @($script:State.KeyBackups)
    [array]::Reverse($backups)
    foreach ($k in $backups) {
        if (-not (Test-Path -LiteralPath $k.File)) { Write-Log "Registry key backup $($k.File) is missing, so $($k.Path) cannot be restored from it." 'WARN'; continue }
        $null = & cmd.exe /d /c "reg.exe import `"$($k.File)`" >nul 2>&1"
        if ($LASTEXITCODE -ne 0) { Write-Log "Could not import $($k.File) (reg.exe exit $LASTEXITCODE)" 'WARN' }
    }
}

function Restore-RegValue {
    param($Entry)
    if ($Entry.Existed) {
        $value = ConvertFrom-StoredValue -Value $Entry.Value -Kind $Entry.Kind
        try { Write-RegRaw -Full $Entry.Path -Name $Entry.Name -Value $value -Kind $Entry.Kind }
        catch {
            if (-not (Test-AccessDenied $_)) { throw }
            [void](Invoke-AsTI -PsCommand (Format-TiRegAdd -Full $Entry.Path -Name $Entry.Name -Value $value -Kind $Entry.Kind))
        }
    }
    else { Remove-RegValueRaw -Full $Entry.Path -Name $Entry.Name }
}

function Set-TweakList {
    param([object[]]$Tweaks)
    foreach ($t in $Tweaks) { Set-RegValue -Path $t.Path -Name $t.Name -Value $t.Value -Type $t.Type }
}

#endregion

