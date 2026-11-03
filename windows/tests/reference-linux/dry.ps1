param([hashtable]$Params)
$env:ProgramData='/tmp/dryrun/pd'; $env:SystemRoot='/tmp/dryrun/sr'; $env:LOCALAPPDATA='/tmp/dryrun/la'; $env:TEMP='/tmp'; $env:ProgramFiles='/tmp/dryrun/pf'
New-Item -ItemType Directory -Force -Path /tmp/dryrun | Out-Null
# Patch a copy: drop the admin requirement and neutralise the .NET registry open (Linux has no registry)
$src = Get-Content /mnt/user-data/outputs/FocusedTweaks.ps1 -Raw
$src = $src -replace '#Requires -RunAsAdministrator',''
$src = $src -replace '(?s)function Open-RegKey \{.*?\r?\n\}\r?\n', "function Open-RegKey { param([string]`$Full, [switch]`$Write, [switch]`$Create) return `$null }`n"
Set-Content /tmp/dry_copy.ps1 $src
# Stubs for Windows only cmdlets
function Get-CimInstance { param($ClassName, $ErrorAction)
  switch ($ClassName) {
    'Win32_PhysicalMemory' { [pscustomobject]@{ Capacity = 16GB } }
    'Win32_VideoController' { [pscustomobject]@{ PNPDeviceID='PCI\VEN_10DE&DEV_2684' } }
    default { $null } } }
function Get-AppxPackage { param([switch]$AllUsers)
  @('Microsoft.BingNews','Microsoft.WindowsStore','Microsoft.Paint','SpotifyAB.SpotifyMusic','Microsoft.XboxGamingOverlay','Microsoft.Windows.Photos','Clipchamp.Clipchamp') | % {
    [pscustomobject]@{ Name=$_; IsFramework=$false; NonRemovable=$false; PackageFullName="$_`_1.0_x64__abc" } } }
function Get-AppxProvisionedPackage { param([switch]$Online) @([pscustomobject]@{ DisplayName='Microsoft.BingNews'; PackageName='Microsoft.BingNews_1' }, [pscustomobject]@{ DisplayName='Microsoft.WindowsStore'; PackageName='x' }) }
function Get-ScheduledTask { param($TaskPath,$TaskName,$ErrorAction)
  @([pscustomobject]@{TaskName='Consolidator';TaskPath='\Microsoft\Windows\Customer Experience Improvement Program\';State='Ready'},
    [pscustomobject]@{TaskName='Schedule Scan';TaskPath='\Microsoft\Windows\UpdateOrchestrator\';State='Ready'},
    [pscustomobject]@{TaskName='SvcRestartTask';TaskPath='\Microsoft\Windows\X\';State='Ready'}) }
function Get-PnpDevice { param($Class,$ErrorAction) [pscustomobject]@{ InstanceId='PCI\VEN_10DE&DEV_2684\4&1' } }
function Get-MMAgent { [pscustomobject]@{ MemoryCompression = $true } }
function Get-MpComputerStatus { param($ErrorAction) [pscustomobject]@{ IsTamperProtected = $false } }
function Get-Service { param($Name,$ErrorAction) $null }
& /tmp/dry_copy.ps1 @Params
"EXIT: $LASTEXITCODE"
