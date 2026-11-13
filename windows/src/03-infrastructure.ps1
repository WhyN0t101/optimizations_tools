#region Infrastructure --------------------------------------------------------------------
$StateFile = Join-Path $StateDir 'state.json'
# One JSON line per recorded change, written and flushed before the change is made (docs/AUDIT.md A-01, A-11).
$JournalFile = Join-Path $StateDir 'journal.jsonl'
# 2: the state file records JournalSeq, the last journal line it holds. Files without it are version 1 (v7.4 and older).
$StateVersion = 2
$LogFile = Join-Path $StateDir ('run-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'

$script:JournalSeq = 0      # number of the last journal line written or read
$script:State = @{
    Registry   = [System.Collections.Generic.List[object]]::new()
    KeyBackups = [System.Collections.Generic.List[object]]::new()
    Tasks      = [System.Collections.Generic.List[object]]::new()
    Removed    = [System.Collections.Generic.List[object]]::new()
    Hosts      = [System.Collections.Generic.List[object]]::new()
    Power      = $null
    Defender   = $false
    DefenderPrefs = $null
    PauseEndTask = $false
    Hibernate  = $null
    MemCompress = $null
    SleepStudy = $false
    PwAge      = $false
    ConsentDb  = $null
    Run        = $null
    StartLayout = $null
    Dep        = $null
    TimerService = $null
    PowerOverlay = $null
    PowerOverlaySet = $null
    PowerOverlaySource = $null
    NvidiaDrs  = $false
    DesktopMoved = [System.Collections.Generic.List[object]]::new()
    CreatedKeys = [System.Collections.Generic.List[object]]::new()
    NetBindings = [System.Collections.Generic.List[object]]::new()
    Features   = [System.Collections.Generic.List[object]]::new()
}
$script:RecordedReg = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    if ($Level -eq 'WARN') { $Ctx.Warnings++ }
    $line = '{0:HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    $colour = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    # With -Json the console gets only the result object; the log file still gets every line.
    if (-not $Json) { Write-Host $line -ForegroundColor $colour }
    Add-Content -Path $LogFile -Value $line
}

# docs/AUDIT.md C-5: exit codes, also in the README and in the -Json result.
$ExitCodes = @{ 0 = 'ok'; 1 = 'failures'; 2 = 'cancelled'; 3 = 'pre flight refused'; 4 = 'state unreadable' }
$script:PreflightResults = @()

function Get-RunMode {
    if ($Revert) { return 'revert' }
    if ($RestoreTask.Count -gt 0) { return 'restoretask' }
    if ($HealthCheck) { return 'healthcheck' }
    if ($Reapply) { return 'reapply' }
    if ($StartupReview) { return 'startupreview' }
    if ($Ctx.DryRun) { return 'dryrun' }
    return 'apply'
}

function Get-RunResult {
    # The object -Json prints: what ran, how it ended, and where the details are.
    param([int]$Code, [string]$Reason = '')
    $health = $null
    if ($script:HealthItems.Count -gt 0) { $health = [ordered]@{ Counts = $script:Health; Items = @($script:HealthItems) } }
    $journal = $null
    if (Test-Path -LiteralPath $JournalFile) { $journal = $JournalFile }
    return [ordered]@{
        ExitCode = $Code; Result = $ExitCodes[$Code]; Reason = $Reason; Mode = (Get-RunMode)
        Failures = $Ctx.Failures; Warnings = $Ctx.Warnings; Preflight = @($script:PreflightResults); Health = $health
        Log = $LogFile; Journal = $journal; StateDir = $StateDir
    }
}

function Exit-Run {
    # Every exit after start up goes through here, so -Json always prints exactly one result object.
    param([int]$Code, [string]$Reason = '')
    if ($Json) { Write-Output (ConvertTo-Json -InputObject (Get-RunResult -Code $Code -Reason $Reason) -Depth 6) }
    exit $Code
}

# -Reapply ($Ctx.Reapply): the apply steps run again, but every primitive leaves alone what is already as the run set
# it, so only what Windows changed back is touched (and, in its first pass, listed).

function Test-DryRun {
    param([Parameter(Mandatory)][string]$Action)
    if ($Ctx.DryRun) { $Ctx.DryRunCount++; Write-Log "DRY RUN, would: $Action"; return $true }
    return $false
}

function ConvertTo-StoredRecord {
    # PowerShell 7 turns ISO date strings into dates when it reads JSON, which would corrupt restored registry
    # strings. Registry records in the state file and the journal therefore carry an 's:' prefix on string values,
    # which ConvertFrom-StoredRecord removes again. Anything that is not a registry record is returned unchanged.
    param($Record)
    if ($null -eq $Record -or -not $Record.PSObject.Properties['Kind']) { return $Record }
    if (($Record.Kind -eq 'String' -or $Record.Kind -eq 'ExpandString') -and $Record.Value -is [string]) {
        return [pscustomobject]@{ Path = $Record.Path; Name = $Record.Name; Existed = $Record.Existed; Kind = $Record.Kind; Value = ('s:' + $Record.Value) }
    }
    return $Record
}

function ConvertFrom-StoredRecord {
    param($Record)
    if ($null -eq $Record -or -not $Record.PSObject.Properties['Kind']) { return $Record }
    if (($Record.Kind -eq 'String' -or $Record.Kind -eq 'ExpandString') -and $Record.Value -is [string] -and $Record.Value.StartsWith('s:')) {
        $Record.Value = $Record.Value.Substring(2)
    }
    return $Record
}

function Save-State {
    if ($Ctx.DryRun) { return }
    $copy = @{}
    foreach ($entry in $script:State.GetEnumerator()) { $copy[$entry.Key] = $entry.Value }
    $copy.Registry = @($script:State.Registry | ForEach-Object { ConvertTo-StoredRecord $_ })
    $copy.StateVersion = $StateVersion
    $copy.JournalSeq = $script:JournalSeq
    # Written to a temporary file and swapped in, so a crash during the write cannot leave a truncated state file.
    # The version before it stays as state.json.bak, which Read-StateFile falls back to.
    $temp = "$StateFile.tmp"
    ConvertTo-Json -InputObject $copy -Depth 8 | Set-Content -LiteralPath $temp -Encoding UTF8
    if (Test-Path -LiteralPath $StateFile) { [IO.File]::Replace($temp, $StateFile, "$StateFile.bak") }
    else { [IO.File]::Move($temp, $StateFile) }
}

function Read-StateFile {
    # The parsed state from state.json or, when that cannot be read, from state.json.bak (one step older).
    $problems = @()
    foreach ($file in $StateFile, "$StateFile.bak") {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        try {
            $raw = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            if ($null -eq $raw) { throw 'the file is empty.' }
            if ($problems.Count -gt 0) { Write-Log "The state file could not be read ($($problems -join ' ')). Using the previous version, $file; the journal fills in what that version lacks." 'WARN' }
            return $raw
        }
        catch { $problems += "$(Split-Path $file -Leaf): $($_.Exception.Message)" }
    }
    throw "The saved state in $StateDir cannot be read, so nothing was changed and -Revert cannot use it ($($problems -join ' ')). Keep the folder as it is: the task, registry key and hosts backups in it are intact."
}

function Add-StateItem {
    # Adds one record to a list in the state. The same rules apply live and when the journal is replayed.
    param([string]$Section, $Item)
    if ($Section -eq 'Registry') {
        if ($script:RecordedReg.Add("$($Item.Path)|$($Item.Name)")) { $script:State.Registry.Add($Item) }
        return
    }
    if ($Section -in 'CreatedKeys', 'Hosts', 'Features') {
        if (@($script:State[$Section]) -notcontains $Item) { $script:State[$Section].Add($Item) }
        return
    }
    $script:State[$Section].Add($Item)
}

function Invoke-JournalEvent {
    # Applies one journal event to the state. Change, Result and Rollback lines are the change log and alter nothing.
    param($JournalEvent)
    switch ($JournalEvent.Op) {
        'Add' { Add-StateItem -Section $JournalEvent.Section -Item $JournalEvent.Item }
        'Set' { $script:State[$JournalEvent.Name] = $JournalEvent.Value }
        'Task' {
            $r = $JournalEvent.Record
            $e = Get-TaskRecord -Path $r.Path -Name $r.Name
            if (-not $e) { $script:State.Tasks.Add($r) }
            elseif ($JournalEvent.Mode -eq 'upgraded') { $e.Action = 'Deleted'; $e.XmlFile = $r.XmlFile }
        }
        'TaskUndo' {
            # A delete that failed must not leave a record claiming the task was removed.
            $e = Get-TaskRecord -Path $JournalEvent.Path -Name $JournalEvent.Name
            if ($e -and $JournalEvent.Outcome -eq 'new') { [void]$script:State.Tasks.Remove($e) }
            elseif ($e -and $JournalEvent.Outcome -eq 'upgraded') { $e.Action = 'Disabled'; $e.XmlFile = $null }
        }
    }
}

function Add-JournalEvents {
    # Writes the events to the journal with one flushed write, and only then applies them to the state: a record of
    # every change is on disk before the change is made. Each event is an ordered hashtable; it gets its Seq here.
    # Dry runs and -Revert write no journal.
    param([AllowEmptyCollection()][object[]]$Events = @())
    if ($Events.Count -eq 0) { return }
    if (-not ($Ctx.DryRun -or $Revert)) {
        $text = New-Object Text.StringBuilder
        foreach ($e in $Events) {
            $script:JournalSeq++
            $e['Seq'] = $script:JournalSeq
            $line = [ordered]@{ Seq = $script:JournalSeq; T = (Get-Date).ToString('o'); Step = $Ctx.StepId; StepName = $Ctx.StepName; Option = $Ctx.JournalOption }
            foreach ($k in @($e.Keys)) {
                if ($k -eq 'Seq') { continue }
                if ($k -eq 'Item' -or $k -eq 'Before') { $line[$k] = ConvertTo-StoredRecord $e[$k] } else { $line[$k] = $e[$k] }
            }
            [void]$text.Append((ConvertTo-Json -InputObject $line -Depth 6 -Compress)).Append("`n")
        }
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text.ToString())
        $stream = [IO.FileStream]::new($JournalFile, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
    }
    foreach ($e in $Events) {
        Invoke-JournalEvent -JournalEvent $e
        $Ctx.StepEvents.Add($e)
    }
}

function Set-StateValue {
    param([Parameter(Mandatory)][string]$Name, $Value)
    Add-JournalEvents @([ordered]@{ Op = 'Set'; Name = $Name; Value = $Value })
}

function Add-StateRecord {
    param([Parameter(Mandatory)][string]$Section, $Item)
    Add-JournalEvents @([ordered]@{ Op = 'Add'; Section = $Section; Item = $Item })
}

function New-ChangeResult {
    # The outcome of one change, as a journal line that refers to the line that announced it.
    param([Parameter(Mandatory)]$Change, [Parameter(Mandatory)][string]$Result, [string]$Now = '')
    $ref = 0
    if ($Change.Contains('Seq')) { $ref = $Change['Seq'] }
    return [ordered]@{ Op = 'Result'; Ref = $ref; Kind = $Change['Kind']; Target = $Change['Target']; Result = $Result; Now = $Now }
}

function Import-Journal {
    # Replays the journal lines the state file does not hold yet (Seq above its JournalSeq). They exist when a run
    # stopped during a step, after it recorded originals but before the state file was saved again.
    param([long]$After = 0)
    $script:JournalSeq = $After
    if (-not (Test-Path -LiteralPath $JournalFile)) { return }
    $replayed = 0; $bad = 0
    foreach ($text in [IO.File]::ReadAllLines($JournalFile)) {
        if (-not $text.Trim()) { continue }
        try { $e = $text | ConvertFrom-Json }
        catch { $bad++; continue }   # a line cut off when a run was killed while writing it
        $seq = [long]$e.Seq
        if ($seq -gt $script:JournalSeq) { $script:JournalSeq = $seq }
        if ($seq -le $After) { continue }
        foreach ($field in 'Item', 'Before') { if ($e.PSObject.Properties[$field]) { [void](ConvertFrom-StoredRecord $e.$field) } }
        Invoke-JournalEvent -JournalEvent $e
        if ($e.Op -in 'Add', 'Set', 'Task', 'TaskUndo') { $replayed++ }
    }
    if ($bad -gt 0) { Write-Log "$bad journal line(s) could not be read and were skipped (a run stopped while writing them)." 'WARN' }
    if ($replayed -gt 0) { Write-Log "Recovered $replayed record(s) from the journal that the state file did not hold yet: the previous run stopped during a step. -Revert can undo those changes too." 'WARN' }
}

function Undo-CreatedKey {
    # Removes one key the run created, only when it is empty again: anything added to it since is left alone.
    param([string]$Full)
    try { $key = Open-RegKey -Full $Full }
    catch { Write-Log "Could not open the created key $Full. $($_.Exception.Message)" 'WARN'; return }
    if (-not $key) { return }
    $empty = ($key.ValueCount -eq 0) -and ($key.SubKeyCount -eq 0)
    $key.Close()
    if (-not $empty) { Write-Log "Key kept, it holds data added after the run: $Full"; return }
    $parts = Split-RegPath $Full
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($script:Hives[$parts[0].ToUpperInvariant()], [Microsoft.Win32.RegistryView]::Default)
    try { $base.DeleteSubKey($parts[1], $false) }
    catch { Write-Log "Could not remove the created key $Full. $($_.Exception.Message)" 'WARN' }
    finally { $base.Close() }
}

function Test-RollbackSafe {
    # Registry values, registry keys, keys the run created and scheduled tasks can be put back exactly from the
    # journal. Other records (hosts file, power plan, features, files, Defender and more) cannot.
    param($JournalEvent)
    switch ($JournalEvent.Op) {
        'Change' { return ($JournalEvent.Kind -in 'Registry', 'RegistryKey', 'Task') }
        'Add' { return ($JournalEvent.Section -in 'Registry', 'KeyBackups', 'CreatedKeys') }
        'Set' { return $false }
        default { return $true }   # Task, TaskUndo, Result and Rollback lines only describe
    }
}

function Undo-FailedStep {
    # docs/AUDIT.md A-04: a step that failed is put back from its own journal lines, newest first, so it is not left
    # half done. When the step changed something the journal cannot put back, the run stops instead: nothing more is
    # built on a half done step, and -Revert still undoes everything recorded.
    param([string]$Name)
    $changes = @($Ctx.StepEvents | Where-Object { $_.Op -ne 'Result' -and $_.Op -ne 'Rollback' })
    if ($changes.Count -eq 0) { Write-Log "Rollback of '$Name': the step recorded no changes, nothing to undo."; return }
    $unsafe = @($changes | Where-Object { -not (Test-RollbackSafe $_) })
    if ($unsafe.Count -gt 0) {
        $Ctx.StopRun = $true
        $what = @($unsafe | ForEach-Object { if ($_.Op -eq 'Set') { $_.Name } elseif ($_.Op -eq 'Add') { $_.Section } else { $_.Kind } } | Select-Object -Unique) -join ', '
        Write-Log "Rollback of '$Name' is not safe: the step also changed $what, which the journal cannot put back. The run stops here. Everything recorded so far is saved, so -Revert undoes it." 'ERROR'
        return
    }
    $failedTasks = @($Ctx.StepEvents | Where-Object { $_.Op -eq 'Result' -and $_.Kind -eq 'Task' -and $_.Result -eq 'FAILED' } | ForEach-Object { $_.Ref })
    $tasks = [System.Collections.Generic.List[object]]::new()
    $undone = 0; $problems = 0
    [array]::Reverse($changes)
    foreach ($e in $changes) {
        try {
            if ($e.Op -eq 'Change' -and $e.Kind -eq 'Registry') { Restore-RegValue -Entry $e.Before; $undone++ }
            elseif ($e.Op -eq 'Change' -and $e.Kind -eq 'RegistryKey') {
                $null = & cmd.exe /d /c "reg.exe import `"$($e.Before)`" >nul 2>&1"
                if ($LASTEXITCODE -ne 0) { throw "reg.exe import failed ($LASTEXITCODE)." }
                $undone++
            }
            elseif ($e.Op -eq 'Change' -and $e.Kind -eq 'Task' -and $failedTasks -notcontains $e.Seq) { $tasks.Add($e.Before) }
            elseif ($e.Op -eq 'Add' -and $e.Section -eq 'CreatedKeys') { Undo-CreatedKey -Full $e.Item }
        }
        catch { $problems++; Write-Log "Rollback of '$Name': could not put back $($e.Target). $($_.Exception.Message)" 'WARN' }
    }
    if ($tasks.Count -gt 0) { Restore-Tasks -Tasks $tasks.ToArray(); $undone += $tasks.Count }
    $outcome = 'OK'; if ($problems -gt 0) { $outcome = 'PARTIAL' }
    Add-JournalEvents @([ordered]@{ Op = 'Rollback'; Kind = 'Step'; Target = $Name; Result = $outcome; Now = "$undone change(s) put back" })
    if ($problems -eq 0) { Write-Log "Rolled back '$Name': $undone change(s) put back from the journal." 'WARN' }
    else {
        $Ctx.StopRun = $true
        Write-Log "Rollback of '$Name' put back $undone change(s) but $problems could not be put back (listed above). The run stops here; -Revert undoes what is recorded." 'ERROR'
    }
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action, [string]$Option = '')
    if ($Ctx.StopRun) { Write-Log "Skipped: $Name. The run stopped after a step that could not be rolled back." 'WARN'; return }
    $Ctx.StepId++
    $Ctx.StepName = $Name
    $Ctx.JournalOption = $Option
    $Ctx.StepEvents.Clear()
    $failuresBefore = $Ctx.Failures
    Write-Log "Starting: $Name"
    try {
        & $Action
        if ($Ctx.Failures -eq $failuresBefore) { Write-Log "Completed: $Name" 'OK' }
        else { Write-Log "Failed: $Name. $($Ctx.Failures - $failuresBefore) change(s) in it failed, listed above." 'ERROR' }
    }
    catch {
        $Ctx.Failures++
        Write-Log "Failed: $Name. $($_.Exception.Message)" 'ERROR'
    }
    finally {
        if ($Ctx.Failures -gt $failuresBefore -and -not $Revert -and -not $Ctx.DryRun) { Undo-FailedStep -Name $Name }
        if (-not $Revert) { Save-State }
        $Ctx.JournalOption = ''
    }
}

function Import-State {
    $after = 0
    if ((Test-Path -LiteralPath $StateFile) -or (Test-Path -LiteralPath "$StateFile.bak")) {
        $raw = Read-StateFile
        foreach ($section in 'Registry', 'KeyBackups', 'Tasks', 'Removed', 'Hosts', 'DesktopMoved', 'CreatedKeys', 'NetBindings', 'Features') {
            if ($raw.PSObject.Properties[$section] -and $raw.$section) {
                foreach ($item in @($raw.$section)) {
                    if ($section -eq 'Registry') { $item = ConvertFrom-StoredRecord $item }
                    Add-StateItem -Section $section -Item $item
                }
            }
        }
        foreach ($scalar in 'Power', 'Defender', 'DefenderPrefs', 'Hibernate', 'MemCompress', 'SleepStudy', 'PwAge', 'ConsentDb', 'Run', 'StartLayout', 'Dep', 'TimerService', 'PowerOverlay', 'PowerOverlaySet', 'PowerOverlaySource', 'NvidiaDrs') {
            if ($raw.PSObject.Properties[$scalar]) { $script:State[$scalar] = $raw.$scalar }
        }
        # Version 1 files (v7.4 and older) have no JournalSeq; there was no journal then, so every line is newer.
        if ($raw.PSObject.Properties['JournalSeq']) { $after = [long]$raw.JournalSeq }
    }
    Import-Journal -After $after
}

function Test-RecordedFirst {
    param([System.Collections.Generic.List[object]]$List, [scriptblock]$Predicate)
    foreach ($item in $List) { if (& $Predicate $item) { return $true } }
    return $false
}

function Initialize-StateDir {
    # The state file is read back by -Revert and -HealthCheck and drives file, service and TrustedInstaller actions, and
    # C:\ProgramData lets standard users create folders. So the folder must belong to administrators and be closed to
    # everyone else before anything is read from it. A folder someone else owns or filled is refused, not repaired.
    $sid = { param($s) [Security.Principal.SecurityIdentifier]$s }
    $admins = & $sid 'S-1-5-32-544'
    $system = & $sid 'S-1-5-18'
    $trusted = @($admins, $system, (& $sid 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'), [Security.Principal.WindowsIdentity]::GetCurrent().User)
    # Order matters: check who owns the folder, close it, and only then look inside. Checking the contents first would
    # leave a gap in which another user could still add a file that the check never sees.
    $isForeign = { param($item) (Test-ReparsePoint $item) -or ($trusted -notcontains (Get-Acl -LiteralPath $item.FullName).GetOwner([Security.Principal.SecurityIdentifier])) }
    $refuse = { param($item) throw "The state folder $StateDir holds an item that is a link or not owned by an administrator ($($item.FullName)). Delete the folder or pass another -StateDir, then run again." }
    # New-Item -Force also succeeds on a folder someone created a moment earlier, so the owner is checked either way.
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $folder = Get-Item -LiteralPath $StateDir -Force
    if (& $isForeign $folder) { & $refuse $folder }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($owner in $admins, $system) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($owner, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $StateDir -AclObject $acl
    # Closed now, so nobody can add anything while the contents are checked.
    $children = @(Get-CleanupTree -Path $StateDir)
    foreach ($child in $children) { if (& $isForeign $child) { & $refuse $child } }
    # Make existing files and folders inherit the closed permissions instead of the old open ones. Only the children are
    # reset: resetting the folder itself would give back the inherited, open permissions.
    if ($children.Count -gt 0) {
        & icacls.exe (Join-Path $StateDir '*') /reset /T /C /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls could not reset the permissions inside $StateDir ($LASTEXITCODE)." }
    }
}

function Test-NameMatch {
    param([string]$Name, [string[]]$Patterns)
    foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
    return $false
}
#endregion

