<#
.SYNOPSIS
    Tests FocusedTweaks in the VMware test VM through vmrun and copies the results back. Nothing runs on this PC.

.DESCRIPTION
    Reverts the VM to a snapshot, copies FocusedTweaks.ps1 (and a profile) into it, and runs these stages there:
    Dry (dry run), Apply (real run, then a restart), Health (health check), Revert (-Revert with its revert check,
    then a restart). After each stage the console output, logs and result files are copied to
    test-results\<time>\<stage> and a summary is printed. Each stage also records what else happened in the guest
    (Windows Update, restarts, crashed services, VMware Tools state) in guest-diag.txt. Benchmark stages run with
    the VM's network unplugged. A stage survives VMware Tools dropping out for up to -BootTimeoutSeconds; when a
    stage fails, whatever the guest has is still copied back.

    The VM needs VMware Tools, an Administrator account with a password that signs in automatically, and a
    snapshot taken on its desktop. See docs\VM-TESTING.md.

    The guest password is asked for once (or read from FT_VM_PASSWORD). vmrun takes it on its command line, so
    use a password for the test VM only.

.EXAMPLE
    .\tools\Test-InVm.ps1 -ProfilePath .\profiles\desktop-max.json

.EXAMPLE
    .\tools\Test-InVm.ps1 -Stages Dry -ScriptArgs '-Only MpoOff,TimeServerPool'
#>
[CmdletBinding()]
param(
    [string]$Vmx = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Virtual Machines\Windows 11\Windows 11.vmx'),
    [string]$Snapshot = 'ft-base',
    [string]$GuestUser = 'Administrator',
    [string]$ProfilePath,
    [string]$ScriptArgs = '',
    [ValidateSet('Dry', 'Benchmark', 'Apply', 'Health', 'Revert', 'StartupReview')][string[]]$Stages = @('Dry', 'Benchmark', 'Apply', 'Health', 'Benchmark', 'Revert'),
    [string]$OutDir,
    [int]$BootTimeoutSeconds = 600,
    [int]$StageTimeoutMinutes = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
$scriptFile = Join-Path $repo 'FocusedTweaks.ps1'
$guestDir = 'C:\FT'
$guestPs = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not $OutDir) { $OutDir = Join-Path $repo ('test-results\{0:yyyyMMdd-HHmmss}' -f (Get-Date)) }

$vmrun = @(
    (Join-Path ${env:ProgramFiles(x86)} 'VMware\VMware Workstation\vmrun.exe'),
    (Join-Path $env:ProgramFiles 'VMware\VMware Workstation\vmrun.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $vmrun) { throw 'vmrun.exe not found. Install VMware Workstation, or check its install folder.' }
if (-not (Test-Path -LiteralPath $Vmx)) { throw "VM not found: $Vmx (pass -Vmx)." }
if (-not (Test-Path -LiteralPath $scriptFile)) { throw "Script not found: $scriptFile. Build it first with tools\build.py." }
if ($ProfilePath -and -not (Test-Path -LiteralPath $ProfilePath)) { throw "Profile not found: $ProfilePath" }

$password = $env:FT_VM_PASSWORD
if (-not $password) {
    $secure = Read-Host "Password for $GuestUser in the VM" -AsSecureString
    $password = [Net.NetworkCredential]::new('', $secure).Password
}

function Invoke-Vmrun {
    # Returns the exit code and output. The password is passed to vmrun but never written to the console or a file.
    param([string[]]$Arguments, [switch]$Guest, [switch]$AllowFail)
    $all = @('-T', 'ws')
    if ($Guest) { $all += @('-gu', $GuestUser, '-gp', $password) }
    $output = (& $vmrun @($all + $Arguments) 2>&1) | Out-String
    $result = [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output.Trim() }
    if ($result.Code -ne 0 -and -not $AllowFail) { throw "vmrun $($Arguments[0]) failed ($($result.Code)): $($result.Output)" }
    return $result
}

function Write-Step {
    param([string]$Text)
    Write-Host ('{0:HH:mm:ss} {1}' -f (Get-Date), $Text) -ForegroundColor Cyan
}

function Wait-GuestDesktop {
    # Ready means the guest account itself is at the desktop (its explorer.exe) and the VMware Tools user process
    # (vmtoolsd.exe -n vmusr) runs in that session: vmrun needs both to start interactive programs. After a running
    # snapshot is restored the user process is sometimes not connected; one restart brings it back.
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    $owners = @()
    $desktopSince = $null
    $restarted = $false
    $mine = { param($line) ($line -match 'owner=([^,]+)') -and (($Matches[1].Trim() -split '\\')[-1] -ieq $GuestUser) }
    while ((Get-Date) -lt $deadline) {
        $tools = Invoke-Vmrun -Arguments @('checkToolsState', $Vmx) -AllowFail
        if ($tools.Output -match 'running') {
            $procs = Invoke-Vmrun -Arguments @('listProcessesInGuest', $Vmx) -Guest -AllowFail
            if ($procs.Output -match 'password|credential|authenticat') { throw "The VM refused the guest login for ${GuestUser}: $($procs.Output)" }
            $lines = @($procs.Output -split "`r?`n")
            $owners = @($lines | Where-Object { $_ -match 'explorer\.exe' } | ForEach-Object { if ($_ -match 'owner=([^,]+)') { $Matches[1].Trim() } } | Select-Object -Unique)
            $desktop = @($lines | Where-Object { $_ -match 'explorer\.exe' -and (& $mine $_) }).Count -gt 0
            # The service copy runs as SYSTEM, so a vmtoolsd.exe owned by the guest account is the user process. The
            # listing does not always show its '-n vmusr' argument.
            $toolsUser = @($lines | Where-Object { $_ -match 'vmtoolsd\.exe' -and (& $mine $_) }).Count -gt 0
            if ($desktop -and $toolsUser) {
                Start-Sleep -Seconds 20   # let the desktop and its startup work settle
                return
            }
            if ($desktop -and -not $desktopSince) { $desktopSince = Get-Date }
            if ($desktop -and -not $restarted -and ((Get-Date) - $desktopSince).TotalSeconds -gt 60) {
                Write-Step "The VMware Tools user process is not running for $GuestUser, restarting the VM once"
                [void](Invoke-Vmrun -Arguments @('reset', $Vmx, 'soft'))
                $restarted = $true; $desktopSince = $null
                Start-Sleep -Seconds 30
            }
        }
        Start-Sleep -Seconds 5
    }
    if ($restarted -and ($owners | Where-Object { ($_ -split '\\')[-1] -ieq $GuestUser })) {
        throw "$GuestUser is at the desktop, but the VMware Tools user process (vmtoolsd.exe -n vmusr) does not start in that session. Reinstall VMware Tools in the VM, restart, and retake the '$Snapshot' snapshot."
    }
    if ($owners.Count -gt 0) {
        throw "The VM desktop belongs to $($owners -join ', '), not $GuestUser. Sign in as $GuestUser (Autologon), retake the '$Snapshot' snapshot on its desktop, or pass -GuestUser."
    }
    throw "The VM did not reach the desktop within $BootTimeoutSeconds seconds. Check that Autologon signs in $GuestUser."
}

function Restart-Guest {
    Write-Step 'Restarting the VM'
    [void](Invoke-Vmrun -Arguments @('reset', $Vmx, 'soft'))
    # Wait for the shutdown to begin, otherwise the old session could still look ready.
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline -and (Invoke-Vmrun -Arguments @('checkToolsState', $Vmx) -AllowFail).Output -match 'running') { Start-Sleep -Seconds 3 }
    Wait-GuestDesktop
}

function Restore-ToolsAutostart {
    # RunKeys deletes HKLM\...\Run, which also holds the "VMware User Process" entry that starts the VMware Tools user
    # process at sign in. Without it vmrun cannot start programs at the desktop after the restart, so put just that
    # entry back before restarting. RunKeys itself was still tested by the Apply stage.
    $fix = Join-Path $OutDir 'restore-tools-autostart.ps1'
    @'
$run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
if (-not (Test-Path $run)) { New-Item -Path $run -Force | Out-Null }
$exe = Join-Path $env:ProgramFiles 'VMware\VMware Tools\vmtoolsd.exe'
Set-ItemProperty -Path $run -Name 'VMware User Process' -Value ('"' + $exe + '" -n vmusr')
'@ | Set-Content -LiteralPath $fix -Encoding ASCII
    [void](Invoke-Vmrun -Arguments @('CopyFileFromHostToGuest', $Vmx, $fix, "$guestDir\restore-tools-autostart.ps1") -Guest)
    $r = Invoke-Vmrun -Arguments @('runProgramInGuest', $Vmx, $guestPs, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$guestDir\restore-tools-autostart.ps1") -Guest -AllowFail
    if ($r.Code -ne 0) { Write-Step "Could not restore the VMware Tools autostart entry ($($r.Output)); the restart may need the Tools user process started by hand." }
    else { Write-Step 'VMware Tools autostart entry put back (RunKeys removed it)' }
}

# Copied into the guest once and run at the end of every stage (and after a failed one). Read only: it records what
# else happened in the guest while the stage ran, so an update, a restart or a dead VMware Tools leaves evidence.
$guestDiagScript = @'
param([Parameter(Mandatory = $true)][string]$Out)
$since = (Get-Date).AddHours(-3)
$startFile = Join-Path $Out 'start.txt'
if (Test-Path -LiteralPath $startFile) {
    $since = [datetime]::Parse((Get-Content -LiteralPath $startFile -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
}
function Get-StageEvents([hashtable]$Filter) {
    $Filter['StartTime'] = $since
    return @(Get-WinEvent -FilterHashtable $Filter -ErrorAction SilentlyContinue)
}
$groups = [ordered]@{
    'Windows Update' = Get-StageEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient' }
    'Restarts and shutdowns' = Get-StageEvents @{ LogName = 'System'; Id = 41, 1074, 6005, 6006, 6008 }
    'Service crashes' = Get-StageEvents @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7031, 7034 }
}
$pending = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending += 'Windows Update' }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending += 'servicing' }
if ($pending.Count -eq 0) { $pending = @('no') }
$restarted = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime -gt $since
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("SUMMARY: update events=$(@($groups['Windows Update']).Count); restart pending=$($pending -join '+'); restarted during stage=$restarted; service crashes=$(@($groups['Service crashes']).Count)")
$lines.Add("Stage start (guest clock): $($since.ToString('o'))")
$lines.Add('')
$lines.Add('VMware Tools:')
foreach ($s in @(Get-Service VMTools, VGAuthService -ErrorAction SilentlyContinue)) { $lines.Add("  service $($s.Name): $($s.Status), $($s.StartType)") }
foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='vmtoolsd.exe'" -ErrorAction SilentlyContinue)) {
    $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction SilentlyContinue
    $lines.Add("  vmtoolsd.exe pid $($p.ProcessId) as $($o.Domain)\$($o.User), started $($p.CreationDate): $($p.CommandLine)")
}
foreach ($name in $groups.Keys) {
    $events = @($groups[$name] | Sort-Object TimeCreated)
    $lines.Add('')
    $lines.Add("$name ($($events.Count)):")
    foreach ($e in $events) {
        $first = @($e.Message -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)
        $lines.Add("  $($e.TimeCreated.ToString('HH:mm:ss')) id $($e.Id): $($first -join '')")
    }
}
$lines | Set-Content -LiteralPath (Join-Path $Out 'guest-diag.txt') -Encoding UTF8
'@

function Get-GuestPackText {
    # Guest code shared by the runner and the salvage script. Needs $out and $start: copies this stage's logs next to
    # the console output, adds the diagnostics and zips everything for the host.
    param([string]$Name)
    @"
Get-ChildItem -LiteralPath 'C:\ProgramData\FocusedTweaks' -File -ErrorAction SilentlyContinue |
    Where-Object { `$_.LastWriteTime -ge `$start -and `$_.Extension -in '.log', '.json', '.jsonl', '.txt' } |
    Copy-Item -Destination `$out
& '$guestDir\collect-diag.ps1' -Out `$out
Compress-Archive -Path (Join-Path `$out '*') -DestinationPath '$guestDir\out-$Name.zip' -Force
"@
}

function Test-GuestFile {
    # $true or $false, or $null when the guest cannot answer (VMware Tools down, guest busy or restarting).
    param([string]$Path)
    $r = Invoke-Vmrun -Arguments @('fileExistsInGuest', $Vmx, $Path) -Guest -AllowFail
    if ($r.Output -match 'does not exist') { return $false }
    if ($r.Code -eq 0 -and $r.Output -match 'exists') { return $true }
    return $null
}

function Wait-GuestTools {
    # A busy or restarting guest can stop answering for a while. Returns $false if it does not come back in time.
    param([string]$Path)
    Write-Step "VMware Tools stopped answering; waiting up to $BootTimeoutSeconds s for it to come back"
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        if ($null -ne (Test-GuestFile -Path $Path)) { Write-Step 'VMware Tools answers again'; return $true }
    }
    return $false
}

function Test-GuestRunnerAlive {
    # $false only when the process list shows command lines and none of them is this stage's runner. When vmrun
    # cannot list processes or shows no arguments, it cannot tell, so the stage keeps waiting (up to its timeout).
    param([string]$Name)
    $r = Invoke-Vmrun -Arguments @('listProcessesInGuest', $Vmx) -Guest -AllowFail
    if ($r.Code -ne 0 -or $r.Output -notmatch 'cmd=.*\s-') { return $true }
    return $r.Output -match [regex]::Escape("run-$Name.ps1")
}

function Receive-GuestZip {
    param([string]$Name, [string]$Dest)
    $zip = Join-Path $Dest 'out.zip'
    $source = "$guestDir\out-$Name.zip"
    $copy = Invoke-Vmrun -Arguments @('CopyFileFromGuestToHost', $Vmx, $source, $zip) -Guest -AllowFail
    if ($copy.Code -ne 0 -and (Wait-GuestTools -Path $source)) {
        $copy = Invoke-Vmrun -Arguments @('CopyFileFromGuestToHost', $Vmx, $source, $zip) -Guest -AllowFail
    }
    if ($copy.Code -ne 0) { return $copy.Output }
    Expand-Archive -LiteralPath $zip -DestinationPath $Dest -Force
    Remove-Item -LiteralPath $zip -Force
    return $null
}

function Save-GuestSalvage {
    # After a failed stage: packs whatever the guest has (console output so far, logs, diagnostics) without the
    # desktop session, which may be gone.
    param([string]$Name, [string]$Dest)
    $salvage = Join-Path $OutDir "salvage-$Name.ps1"
    @"
`$out = '$guestDir\out\$Name'
New-Item -ItemType Directory -Path `$out -Force | Out-Null
`$start = (Get-Date).AddHours(-3)
`$startFile = Join-Path `$out 'start.txt'
if (Test-Path -LiteralPath `$startFile) {
    `$start = [datetime]::Parse((Get-Content -LiteralPath `$startFile -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
}
if (-not (Test-Path -LiteralPath (Join-Path `$out 'exitcode.txt'))) { Set-Content -LiteralPath (Join-Path `$out 'exitcode.txt') -Value 'none' }
$(Get-GuestPackText -Name $Name)
"@ | Set-Content -LiteralPath $salvage -Encoding ASCII
    $steps = @(
        { Invoke-Vmrun -Arguments @('CopyFileFromHostToGuest', $Vmx, $salvage, "$guestDir\salvage-$Name.ps1") -Guest -AllowFail },
        { Invoke-Vmrun -Arguments @('runProgramInGuest', $Vmx, $guestPs, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$guestDir\salvage-$Name.ps1") -Guest -AllowFail }
    )
    foreach ($step in $steps) {
        $r = & $step
        if ($r.Code -ne 0) { Write-Step "Could not collect results from the guest: $($r.Output)"; return }
    }
    $err = Receive-GuestZip -Name $Name -Dest $Dest
    if ($err) { Write-Step "Could not copy the collected results: $err" }
    else { Write-Step "Collected what the guest had into $Dest" }
}

function Invoke-GuestStage {
    param([string]$Name, [string]$Arguments)
    $runner = Join-Path $OutDir "run-$Name.ps1"
    $done = "$guestDir\done-$Name.txt"
    # The runner keeps all quoting inside one PowerShell file, so lists such as -Only A,B work. It is started without
    # waiting and writes a marker when it is done, so a short VMware Tools outage does not lose the stage.
    @"
`$out = '$guestDir\out\$Name'
Remove-Item -LiteralPath `$out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path `$out -Force | Out-Null
`$start = Get-Date
Set-Content -LiteralPath (Join-Path `$out 'start.txt') -Value `$start.ToString('o')
`$code = 0
try {
    & '$guestDir\FocusedTweaks.ps1' $Arguments *> (Join-Path `$out 'console.txt')
    if (`$null -ne `$LASTEXITCODE) { `$code = `$LASTEXITCODE }
}
catch {
    Add-Content -LiteralPath (Join-Path `$out 'console.txt') -Value ('SCRIPT STOPPED: ' + `$_.Exception.Message)
    `$code = 99
}
Set-Content -LiteralPath (Join-Path `$out 'exitcode.txt') -Value `$code
$(Get-GuestPackText -Name $Name)
Set-Content -LiteralPath '$done' -Value `$code
exit `$code
"@ | Set-Content -LiteralPath $runner -Encoding ASCII
    [void](Invoke-Vmrun -Arguments @('CopyFileFromHostToGuest', $Vmx, $runner, "$guestDir\run-$Name.ps1") -Guest)
    Write-Step "Stage $Name in the VM: FocusedTweaks.ps1 $Arguments"
    $launch = Invoke-Vmrun -Arguments @('runProgramInGuest', $Vmx, '-noWait', '-activeWindow', '-interactive', $guestPs, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$guestDir\run-$Name.ps1") -Guest -AllowFail
    $problem = $null
    if ($launch.Code -ne 0) { $problem = "it did not start ($($launch.Output))" }
    $deadline = (Get-Date).AddMinutes($StageTimeoutMinutes)
    $polls = 0
    $checkRunner = $false
    while (-not $problem) {
        Start-Sleep -Seconds 15
        $polls++
        $state = Test-GuestFile -Path $done
        if ($state -eq $true) { break }
        if ($null -eq $state) {
            if (-not (Wait-GuestTools -Path $done)) { $problem = "VMware Tools did not answer again within $BootTimeoutSeconds s" }
            $checkRunner = $true   # the guest may have restarted, which ends the runner
            continue
        }
        if ((Get-Date) -gt $deadline) { $problem = "it ran longer than $StageTimeoutMinutes minutes"; break }
        if ($checkRunner -or $polls % 4 -eq 0) {
            $checkRunner = $false
            if (-not (Test-GuestRunnerAlive -Name $Name) -and (Test-GuestFile -Path $done) -ne $true) {
                $problem = 'its runner is no longer running in the guest (restart or sign out?)'
            }
        }
    }
    $dest = Join-Path $OutDir $Name
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    if (-not $problem) {
        $err = Receive-GuestZip -Name $Name -Dest $dest
        if ($err) { $problem = "its results could not be copied ($err)" }
    }
    if ($problem) {
        Write-Step "Stage $Name failed: $problem. Collecting what the guest has"
        Save-GuestSalvage -Name $Name -Dest $dest
        $null = Write-Summary
        throw "Stage $Name failed: $problem. Results so far are in $dest (see guest-diag.txt). Look in the VM before reverting it: $guestDir\out\$Name and the System event log."
    }
    $code = (Get-Content -LiteralPath (Join-Path $dest 'exitcode.txt') -Raw).Trim()
    Write-Step "Stage $Name finished with exit code $code. Results: $dest"
}

$nics = @(Select-String -LiteralPath $Vmx -Pattern '^\s*(ethernet\d+)\.present\s*=\s*"TRUE"' | ForEach-Object { $_.Matches[0].Groups[1].Value })

function Set-GuestNetwork {
    # Benchmarks run offline so Windows Update, Store and Defender cloud traffic add no noise. This unplugs the
    # virtual cable only; nothing inside Windows changes, so the script still sees the real update settings.
    param([bool]$Connected)
    $verb = 'disconnectNamedDevice'
    if ($Connected) { $verb = 'connectNamedDevice' }
    foreach ($nic in $nics) {
        $r = Invoke-Vmrun -Arguments @($verb, $Vmx, $nic) -AllowFail
        if ($r.Code -ne 0) { Write-Step "vmrun $verb $nic failed: $($r.Output)" }
    }
    if ($nics.Count -gt 0) { Write-Step ("VM network " + $(if ($Connected) { 'connected' } else { 'disconnected for the benchmark' })) }
}

function Get-StageJson {
    param([string]$Name, [string]$Kind)
    $file = Get-ChildItem -Path (Join-Path (Join-Path $OutDir $Name) "$Kind-*.json") -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if ($file) { return Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json }
    return $null
}

function Write-Summary {
    $lines = [System.Collections.Generic.List[string]]::new()
    $bad = $false
    foreach ($stageDir in @(Get-ChildItem -LiteralPath $OutDir -Directory | Sort-Object Name)) {
        $name = $stageDir.Name
        $dir = $stageDir.FullName
        $codeFile = Join-Path $dir 'exitcode.txt'
        $code = 'none'
        if (Test-Path -LiteralPath $codeFile) { $code = (Get-Content -LiteralPath $codeFile -Raw).Trim() }
        $errors = @(Get-ChildItem -Path (Join-Path $dir 'run-*.log') -ErrorAction SilentlyContinue | Select-String -SimpleMatch '[ERROR]')
        $lines.Add("$name`: exit code $code, $($errors.Count) error line(s) in the log")
        foreach ($e in ($errors | Select-Object -First 5)) { $lines.Add("    $($e.Line.Trim())") }
        if ($code -ne '0' -or $errors.Count -gt 0) { $bad = $true }
        # Only worth a line when something else happened in the guest during the stage.
        $diagFile = Join-Path $dir 'guest-diag.txt'
        if (Test-Path -LiteralPath $diagFile) {
            $diag = (Get-Content -LiteralPath $diagFile -TotalCount 1) -replace '^SUMMARY: ', ''
            if ($diag -notmatch 'update events=0; restart pending=no; restarted during stage=False; service crashes=0') { $lines.Add("    guest: $diag (see guest-diag.txt)") }
        }
        if ($name -like '*-Benchmark') {
            foreach ($l in @(Get-Content -LiteralPath (Join-Path $dir 'console.txt') -ErrorAction SilentlyContinue | Where-Object { $_ -match '\S' -and $_ -notmatch '^\d\d:\d\d:\d\d ' })) { $lines.Add("    $l") }
        }
        $health = Get-StageJson -Name $name -Kind 'health'
        if ($health) {
            $lines.Add("    health: $($health.Counts.PASS) passed, $($health.Counts.WARN) warning(s), $($health.Counts.FAIL) failed, $($health.Counts.INFO) note(s)")
            foreach ($i in @($health.Items | Where-Object { $_.Status -in 'WARN', 'FAIL' })) { $lines.Add("    [$($i.Status)] $($i.Area): $($i.Message)") }
            if ($health.Counts.FAIL -gt 0) { $bad = $true }
        }
        $revert = Get-StageJson -Name $name -Kind 'revert-check'
        if ($revert) {
            $lines.Add("    revert check: $($revert.Counts.Checked) value(s) checked, $($revert.Counts.Differ) item(s) differ")
            foreach ($i in @($revert.Items | Select-Object -First 15)) { $lines.Add("    [$($i.Area)] $($i.Message)") }
        }
    }
    $lines | Set-Content -LiteralPath (Join-Path $OutDir 'summary.txt') -Encoding UTF8
    Write-Host ''
    $lines | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host "Everything is in $OutDir" -ForegroundColor Cyan
    return (-not $bad)
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$common = @()
if ($ProfilePath) { $common += "-ProfilePath '$guestDir\profile.json'" }
if ($ScriptArgs) { $common += $ScriptArgs }
$common = $common -join ' '

Write-Step "Reverting $(Split-Path $Vmx -Leaf) to snapshot '$Snapshot'"
[void](Invoke-Vmrun -Arguments @('revertToSnapshot', $Vmx, $Snapshot))
# Not through Invoke-Vmrun: when Workstation is not open yet, 'start ... gui' launches vmware.exe, which inherits the
# output pipe, and reading that pipe would then wait until the Workstation window is closed. Without redirection
# vmrun shares this console instead; reading Handle right away keeps the exit code available.
$startProc = Start-Process -FilePath $vmrun -ArgumentList @('-T', 'ws', 'start', "`"$Vmx`"", 'gui') -NoNewWindow -PassThru
$null = $startProc.Handle
$startProc.WaitForExit()
if ($startProc.ExitCode -ne 0 -and (Invoke-Vmrun -Arguments @('checkToolsState', $Vmx) -AllowFail).Output -notmatch 'running|installed') {
    throw "vmrun start failed with exit code $($startProc.ExitCode)."
}
Wait-GuestDesktop

Write-Step "Copying the script into $guestDir"
[void](Invoke-Vmrun -Arguments @('createDirectoryInGuest', $Vmx, $guestDir) -Guest -AllowFail)
[void](Invoke-Vmrun -Arguments @('CopyFileFromHostToGuest', $Vmx, $scriptFile, "$guestDir\FocusedTweaks.ps1") -Guest)
if ($ProfilePath) { [void](Invoke-Vmrun -Arguments @('CopyFileFromHostToGuest', $Vmx, (Resolve-Path -LiteralPath $ProfilePath).Path, "$guestDir\profile.json") -Guest) }
$diagFile = Join-Path $OutDir 'collect-diag.ps1'
$guestDiagScript | Set-Content -LiteralPath $diagFile -Encoding ASCII
[void](Invoke-Vmrun -Arguments @('CopyFileFromHostToGuest', $Vmx, $diagFile, "$guestDir\collect-diag.ps1") -Guest)

# Folders are numbered, so a stage can run twice (a benchmark before and after the run).
$index = 0
foreach ($stage in $Stages) {
    $index++
    $label = '{0:00}-{1}' -f $index, $stage
    switch ($stage) {
        'Dry' { Invoke-GuestStage -Name $label -Arguments "-DryRun -Force $common" }
        'Benchmark' {
            Set-GuestNetwork -Connected $false
            try { Invoke-GuestStage -Name $label -Arguments '-Benchmark' }
            finally { Set-GuestNetwork -Connected $true; Start-Sleep -Seconds 10 }   # time for DHCP before the next stage
        }
        'StartupReview' { Invoke-GuestStage -Name $label -Arguments '-StartupReview' }
        'Apply' { Invoke-GuestStage -Name $label -Arguments "-Force $common"; Restore-ToolsAutostart; Restart-Guest }
        'Health' { Invoke-GuestStage -Name $label -Arguments '-HealthCheck' }
        'Revert' { Invoke-GuestStage -Name $label -Arguments '-Revert'; Restart-Guest }
    }
}

$ok = Write-Summary
exit ([int](-not $ok))
