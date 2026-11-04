<#
.SYNOPSIS
    Tests FocusedTweaks in the VMware test VM through vmrun and copies the results back. Nothing runs on this PC.

.DESCRIPTION
    Reverts the VM to a snapshot, copies FocusedTweaks.ps1 (and a profile) into it, and runs these stages there:
    Dry (dry run), Apply (real run, then a restart), Health (health check), Revert (-Revert with its revert check,
    then a restart). After each stage the console output, logs and result files are copied to
    test-results\<time>\<stage> and a summary is printed.

    The VM needs VMware Tools, an Administrator account with a password that signs in automatically, and a
    snapshot taken on its desktop. See docs\VM-TESTING.md.

    The guest password is asked for once (or read from FT_VM_PASSWORD). vmrun takes it on its command line, so
    use a password for the test VM only.

.EXAMPLE
    .\tools\Test-InVm.ps1 -ProfilePath .\profiles\my-pc.json

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
    [ValidateSet('Dry', 'Apply', 'Health', 'Revert')][string[]]$Stages = @('Dry', 'Apply', 'Health', 'Revert'),
    [string]$OutDir,
    [int]$BootTimeoutSeconds = 600
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
    # Ready means VMware Tools answer and Explorer runs for the signed in account.
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $tools = Invoke-Vmrun -Arguments @('checkToolsState', $Vmx) -AllowFail
        if ($tools.Output -match 'running') {
            $procs = Invoke-Vmrun -Arguments @('listProcessesInGuest', $Vmx) -Guest -AllowFail
            if ($procs.Code -eq 0 -and $procs.Output -match 'explorer\.exe') {
                Start-Sleep -Seconds 20   # let the desktop and its startup work settle
                return
            }
            if ($procs.Output -match 'password|credential|authenticat') { throw "The VM refused the guest login for ${GuestUser}: $($procs.Output)" }
        }
        Start-Sleep -Seconds 5
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

function Invoke-GuestStage {
    param([string]$Name, [string]$Arguments)
    $runner = Join-Path $OutDir "run-$Name.ps1"
    $zipGuest = "$guestDir\out-$Name.zip"
    # The runner keeps all quoting inside one PowerShell file, so lists such as -Only A,B work.
    @"
`$start = Get-Date
`$out = '$guestDir\out\$Name'
Remove-Item -LiteralPath `$out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path `$out -Force | Out-Null
`$code = 0
try {
    & '$guestDir\FocusedTweaks.ps1' $Arguments *> (Join-Path `$out 'console.txt')
    if (`$null -ne `$LASTEXITCODE) { `$code = `$LASTEXITCODE }
}
catch {
    Add-Content -LiteralPath (Join-Path `$out 'console.txt') -Value ('SCRIPT STOPPED: ' + `$_.Exception.Message)
    `$code = 99
}
Get-ChildItem -LiteralPath 'C:\ProgramData\FocusedTweaks' -File -ErrorAction SilentlyContinue |
    Where-Object { `$_.LastWriteTime -ge `$start -and `$_.Extension -in '.log', '.json' } |
    Copy-Item -Destination `$out
Set-Content -LiteralPath (Join-Path `$out 'exitcode.txt') -Value `$code
Compress-Archive -Path (Join-Path `$out '*') -DestinationPath '$zipGuest' -Force
exit `$code
"@ | Set-Content -LiteralPath $runner -Encoding ASCII
    [void](Invoke-Vmrun -Arguments @('CopyFileFromHostToGuest', $Vmx, $runner, "$guestDir\run-$Name.ps1") -Guest)
    Write-Step "Stage $Name in the VM: FocusedTweaks.ps1 $Arguments"
    $run = Invoke-Vmrun -Arguments @('runProgramInGuest', $Vmx, '-activeWindow', '-interactive', $guestPs, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$guestDir\run-$Name.ps1") -Guest -AllowFail
    $dest = Join-Path $OutDir $Name
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $zip = Join-Path $dest 'out.zip'
    $copy = Invoke-Vmrun -Arguments @('CopyFileFromGuestToHost', $Vmx, $zipGuest, $zip) -Guest -AllowFail
    if ($copy.Code -ne 0) { throw "Stage $Name produced no results ($($run.Output)). Look in the VM, folder $guestDir." }
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
    Remove-Item -LiteralPath $zip -Force
    $code = (Get-Content -LiteralPath (Join-Path $dest 'exitcode.txt') -Raw).Trim()
    Write-Step "Stage $Name finished with exit code $code. Results: $dest"
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
    foreach ($name in $Stages) {
        $dir = Join-Path $OutDir $name
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $code = (Get-Content -LiteralPath (Join-Path $dir 'exitcode.txt') -Raw).Trim()
        $errors = @(Get-ChildItem -Path (Join-Path $dir 'run-*.log') -ErrorAction SilentlyContinue | Select-String -SimpleMatch '[ERROR]')
        $lines.Add("$name`: exit code $code, $($errors.Count) error line(s) in the log")
        foreach ($e in ($errors | Select-Object -First 5)) { $lines.Add("    $($e.Line.Trim())") }
        if ($code -ne '0' -or $errors.Count -gt 0) { $bad = $true }
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
$start = Invoke-Vmrun -Arguments @('start', $Vmx, 'gui') -AllowFail
if ($start.Code -ne 0 -and $start.Output -notmatch 'already|running') { throw "vmrun start failed: $($start.Output)" }
Wait-GuestDesktop

Write-Step "Copying the script into $guestDir"
[void](Invoke-Vmrun -Arguments @('createDirectoryInGuest', $Vmx, $guestDir) -Guest -AllowFail)
[void](Invoke-Vmrun -Arguments @('CopyFileFromHostToGuest', $Vmx, $scriptFile, "$guestDir\FocusedTweaks.ps1") -Guest)
if ($ProfilePath) { [void](Invoke-Vmrun -Arguments @('CopyFileFromHostToGuest', $Vmx, (Resolve-Path -LiteralPath $ProfilePath).Path, "$guestDir\profile.json") -Guest) }

foreach ($stage in $Stages) {
    switch ($stage) {
        'Dry' { Invoke-GuestStage -Name 'Dry' -Arguments "-DryRun -Force $common" }
        'Apply' { Invoke-GuestStage -Name 'Apply' -Arguments "-Force $common"; Restart-Guest }
        'Health' { Invoke-GuestStage -Name 'Health' -Arguments '-HealthCheck' }
        'Revert' { Invoke-GuestStage -Name 'Revert' -Arguments '-Revert'; Restart-Guest }
    }
}

$ok = Write-Summary
exit ([int](-not $ok))
