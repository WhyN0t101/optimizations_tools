#Requires -Version 5.1
<#
.SYNOPSIS
    Lists what this Windows ships (services, scheduled tasks, Store apps, startup entries, optional features) and
    says for each whether FocusedTweaks handles it, whether it was reviewed and left alone on purpose, or whether it
    is unknown. Reads only; changes nothing and downloads nothing.

.DESCRIPTION
    Run it on a fresh Windows, before FocusedTweaks, to spot what the script does not know yet. With -Previous it also
    lists what is new since that earlier inventory: what a Windows update added. The weekly CI run on the Windows 11
    runner does both and shows the result in its summary; tools\Test-InVm.ps1 -Stages Inventory does it in the VM.

        .\tools\Get-Inventory.ps1                                  # report in the console, files in .\inventory
        .\tools\Get-Inventory.ps1 -Previous .\old\inventory.json   # also what is new since then

    Handled comes from the built FocusedTweaks.ps1 (its service groups, app lists, keep lists and feature groups), so
    it is always in step with the script. Reviewed comes from tools\inventory-known.json: items looked at and left
    alone on purpose, each with its reason. Run it as administrator: provisioned apps and every service need it.

.PARAMETER Script
    The built FocusedTweaks.ps1 to read what it handles from (not run).
.PARAMETER Known
    The reviewed list (inventory-known.json).
.PARAMETER Previous
    An earlier inventory.json to compare with.
.PARAMETER OutDir
    Where inventory.json and summary.txt are written.
#>
[CmdletBinding()]
param(
    [string]$Script,
    [string]$Known,
    [string]$Previous,
    [string]$OutDir = 'inventory'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Here, not as parameter defaults: Windows PowerShell 5.1 leaves $PSScriptRoot empty there.
if (-not $Script) { $Script = Join-Path (Split-Path $PSScriptRoot -Parent) 'FocusedTweaks.ps1' }
if (-not $Known) { $Known = Join-Path $PSScriptRoot 'inventory-known.json' }

function Get-ScriptLists {
    # The strings in the named top-level assignments of the built script, read from its syntax tree, not by running it.
    param([string]$Path)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $lists = @{}
    $wanted = 'ServiceGroups', 'TelemetryServices', 'CdpServices', 'VendorServicesDisable', 'VendorServicesManual', 'AppsToRemove',
        'KeepApps', 'TaskKeepBuiltIn', 'StartupKeepBuiltIn', 'FeatureGroups'
    foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $false)) {
        if ($a.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $name = $a.Left.VariablePath.UserPath
        if ($wanted -notcontains $name -or $lists.ContainsKey($name)) { continue }
        # Hashtable keys are option names, not items: only the strings inside the values count.
        $strings = $a.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Parent -isnot [System.Management.Automation.Language.HashtableAst] }, $true)
        $lists[$name] = @($strings | ForEach-Object { $_.Value } | Select-Object -Unique)
    }
    foreach ($w in $wanted) { if (-not $lists.ContainsKey($w)) { throw "`$$w not found in $Path. Rebuild the script, or update Get-Inventory.ps1." } }
    # Handled by steps of their own, outside those lists: services set by name (WSearch by SearchIndexingOff, luafv by
    # Uac) and apps removed by name pattern (Quick Assist by RemoveQuickAssist).
    $text = [IO.File]::ReadAllText($Path)
    $lists['StepServices'] = @([regex]::Matches($text, "Set-ServiceStart (?:-Name )?'([\w.-]+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $lists['StepApps'] = @([regex]::Matches($text, "Get-AppxPackage[^\r\n]*?\`$_\.Name -like '([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    return $lists
}

function Test-Match([string]$Name, [object[]]$Patterns) {
    foreach ($p in @($Patterns)) { if ($Name -like $p) { return $true } }
    return $false
}

function Get-KnownReason([string]$Kind, [string]$Name, $KnownLists) {
    if (-not $KnownLists -or -not $KnownLists.PSObject.Properties[$Kind]) { return $null }
    foreach ($p in $KnownLists.$Kind.PSObject.Properties) { if ($Name -like $p.Name) { return [string]$p.Value } }
    return $null
}

function Get-Items {
    # Every item as kind, name, detail. Per user service copies (CDPUserSvc_1a2b3) count under their template name.
    $items = [System.Collections.Generic.List[object]]::new()
    $add = { param($Kind, $Name, $Detail) $items.Add([pscustomobject]@{ Kind = $Kind; Name = $Name; Detail = $Detail; Status = ''; Reason = '' }) }
    $seen = @{}
    foreach ($s in @(Get-CimInstance -ClassName Win32_Service)) {
        $name = $s.Name -replace '_[0-9a-f]{4,8}$', ''
        if ($seen.ContainsKey("s|$name")) { continue }
        $seen["s|$name"] = $true
        $exe = if ($s.PathName) { ([string]$s.PathName -replace '^"([^"]+)".*$', '$1' -replace '\s+-.*$', '') } else { '' }
        & $add 'service' $name "$($s.DisplayName); $($s.StartMode), $($s.State); $exe"
    }
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) { & $add 'task' "$($t.TaskPath)$($t.TaskName)" ([string]$t.State) }
    $apps = @{}
    # Every user's apps and the ones provisioned for new users need administrator rights; without them, this user's.
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { Write-Warning 'Not running as administrator: only your own apps are listed, not every user''s or the ones provisioned for new users.' }
    $packages = if ($admin) { @(Get-AppxPackage -AllUsers) } else { @(Get-AppxPackage) }
    foreach ($p in $packages) {
        if ($p.IsFramework -or $p.NonRemovable -or ($p.PSObject.Properties['IsResourcePackage'] -and $p.IsResourcePackage)) { continue }
        if (-not $apps.ContainsKey($p.Name)) { $apps[$p.Name] = "installed, $($p.SignatureKind)" }
    }
    if ($admin) {
        foreach ($p in @(Get-AppxProvisionedPackage -Online)) {
            if ($apps.ContainsKey($p.DisplayName)) { $apps[$p.DisplayName] += ', provisioned' } else { $apps[$p.DisplayName] = 'provisioned for new users' }
        }
    }
    foreach ($k in $apps.Keys) { & $add 'app' $k $apps[$k] }
    $runKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    foreach ($key in $runKeys) {
        $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($p in $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) { & $add 'startup' $p.Name "Run key ($($key.Split('\')[0])): $($p.Value)" }
    }
    foreach ($folder in [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup')) {
        if ($folder -and (Test-Path -LiteralPath $folder)) { foreach ($f in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)) { & $add 'startup' $f.BaseName "Startup folder: $($f.FullName)" } }
    }
    foreach ($f in @(Get-CimInstance -ClassName Win32_OptionalFeature -Filter 'InstallState = 1' -ErrorAction SilentlyContinue)) { & $add 'feature' $f.Name 'turned on' }
    return $items
}

function Set-Status {
    # Handled: FocusedTweaks changes it by default or by an option. Kept: on a keep list of the script. Reviewed:
    # inventory-known.json. Off: a service that is already disabled. Unknown: the rest.
    param($Items, $Lists, $KnownLists)
    $services = @($Lists.ServiceGroups) + @($Lists.TelemetryServices) + @($Lists.CdpServices) + @($Lists.VendorServicesDisable) + @($Lists.VendorServicesManual) + @($Lists.StepServices)
    foreach ($i in $Items) {
        $section = @{ service = 'services'; app = 'apps'; startup = 'startup'; feature = 'features'; task = 'tasks' }[$i.Kind]
        $reason = Get-KnownReason -Kind $section -Name $i.Name -KnownLists $KnownLists
        switch ($i.Kind) {
            'service' {
                if ($services -contains $i.Name) { $i.Status = 'handled' }
                elseif ($reason) { $i.Status = 'reviewed' }
                elseif ($i.Detail -match '; Disabled,') { $i.Status = 'off' }
                # Started only on demand and not running now: Windows starts these when something needs them, which is
                # not bloat. Counted, not listed; it is listed once it runs or starts by itself.
                elseif ($i.Detail -match '; Manual, Stopped;') { $i.Status = 'idle' }
                else { $i.Status = 'unknown' }
            }
            'task' { $i.Status = if (Test-Match $i.Name $Lists.TaskKeepBuiltIn) { 'kept' } else { 'handled' } }   # TaskMode Delete removes the rest
            'app' {
                if (Test-Match $i.Name $Lists.KeepApps) { $i.Status = 'kept' }
                elseif ((Test-Match $i.Name $Lists.AppsToRemove) -or (Test-Match $i.Name $Lists.StepApps)) { $i.Status = 'handled' }
                elseif ($reason) { $i.Status = 'reviewed' }
                elseif ($i.Detail -like 'installed, System*') { $i.Status = 'system' }   # part of Windows itself
                else { $i.Status = 'unknown' }
            }
            'startup' {
                if (Test-Match $i.Name $Lists.StartupKeepBuiltIn) { $i.Status = 'kept' }
                elseif ($i.Detail -like 'Run key*') { $i.Status = 'handled' }   # RunKeys removes the rest
                elseif ($reason) { $i.Status = 'reviewed' }
                else { $i.Status = 'unknown' }
            }
            'feature' {
                if ($Lists.FeatureGroups -contains $i.Name) { $i.Status = 'handled' }
                elseif ($reason) { $i.Status = 'reviewed' }
                else { $i.Status = 'unknown' }
            }
        }
        if ($reason) { $i.Reason = $reason }
    }
}

function Get-Report {
    param($Items, $Before)
    $lines = [System.Collections.Generic.List[string]]::new()
    $kinds = 'service', 'task', 'app', 'startup', 'feature'
    $plural = @{ service = 'services'; task = 'scheduled tasks'; app = 'Store apps'; startup = 'startup entries'; feature = 'optional features' }
    $lines.Add('Inventory: ' + (($kinds | ForEach-Object { $k = $_; $all = @($Items | Where-Object Kind -eq $k); "$($all.Count) $($plural[$k]) ($(@($all | Where-Object Status -eq 'unknown').Count) unknown)" }) -join ', '))
    $idle = @($Items | Where-Object Status -eq 'idle').Count
    if ($idle -gt 0) { $lines.Add("  ($idle more services start only on demand and are not running: not listed)") }
    if ($Before) {
        $old = @{}; foreach ($b in @($Before.Items)) { $old["$($b.Kind)|$($b.Name)"] = $true }
        $new = @($Items | Where-Object { -not $old.ContainsKey("$($_.Kind)|$($_.Name)") })
        $lines.Add("New since the previous inventory ($($Before.Taken)): $($new.Count)")
        foreach ($n in $new) { $lines.Add("  + $($n.Kind) $($n.Name) [$($n.Status)] $($n.Detail)") }
        $now = @{}; foreach ($i in $Items) { $now["$($i.Kind)|$($i.Name)"] = $true }
        $gone = @($Before.Items | Where-Object { -not $now.ContainsKey("$($_.Kind)|$($_.Name)") })
        if ($gone.Count -gt 0) { $lines.Add("Gone since then: $($gone.Count)"); foreach ($g in $gone) { $lines.Add("  - $($g.Kind) $($g.Name)") } }
    }
    foreach ($k in $kinds) {
        $unknown = @($Items | Where-Object { $_.Kind -eq $k -and $_.Status -eq 'unknown' } | Sort-Object Name)
        if ($unknown.Count -eq 0) { continue }
        $lines.Add("Unknown $($plural[$k]) (not handled by FocusedTweaks, not reviewed): $($unknown.Count)")
        foreach ($u in $unknown) { $lines.Add("  ? $($u.Name): $($u.Detail)") }
    }
    return $lines
}

$lists = Get-ScriptLists -Path (Resolve-Path -LiteralPath $Script).Path
$knownLists = if (Test-Path -LiteralPath $Known) { Get-Content -LiteralPath $Known -Raw | ConvertFrom-Json } else { $null }
$items = Get-Items
Set-Status -Items $items -Lists $lists -KnownLists $knownLists
$before = $null
if ($Previous -and (Test-Path -LiteralPath $Previous)) { $before = Get-Content -LiteralPath $Previous -Raw | ConvertFrom-Json }
$report = Get-Report -Items $items -Before $before

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$os = Get-CimInstance -ClassName Win32_OperatingSystem
[pscustomobject]@{ Taken = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Windows = "$($os.Caption) $($os.Version) $($env:PROCESSOR_ARCHITECTURE)"; Items = @($items) } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutDir 'inventory.json') -Encoding UTF8
$report | Set-Content -LiteralPath (Join-Path $OutDir 'summary.txt') -Encoding UTF8
$report | ForEach-Object { Write-Host $_ }
exit 0
