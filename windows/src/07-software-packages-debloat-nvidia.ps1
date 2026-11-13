#region Software: packages, debloat, NVIDIA ----------------------------------------------
function ConvertFrom-DmtfDate {
    # System Restore stores times as DMTF text (yyyyMMddHHmmss.ffffff+UUU, UUU = minutes from UTC). Local time, or $null.
    param($Value)
    if ($Value -is [DateTime]) { return $Value }
    $m = [regex]::Match([string]$Value, '^(\d{14})\.\d{6}([+-])(\d{3})$')
    if (-not $m.Success) { return $null }
    $clock = [DateTime]::ParseExact($m.Groups[1].Value, 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $offset = [TimeSpan]::FromMinutes([int]$m.Groups[3].Value)
    if ($m.Groups[2].Value -eq '-') { $offset = $offset.Negate() }
    return ([DateTimeOffset]::new($clock, $offset)).LocalDateTime
}

function Get-RestorePoints {
    # Through CIM, which works in Windows PowerShell 5.1 and PowerShell 7 alike (Get-ComputerRestorePoint is 5.1 only).
    return @(Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction SilentlyContinue)
}

function Test-RestorePointSince {
    param([DateTime]$Since, [object[]]$Points = @())
    foreach ($p in $Points) {
        $made = ConvertFrom-DmtfDate $p.CreationTime
        if ($made -and $made -ge $Since.AddSeconds(-2)) { return $true }
    }
    return $false
}

function Invoke-Checkpoint {
    # Asks Windows for a restore point and returns what it said when it refused: the error, or the warning Windows
    # gives when one was made in the last 24 hours. Empty when it said nothing.
    $said = $null
    try { Checkpoint-Computer -Description 'Before FocusedTweaks' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable said }
    catch { return $_.Exception.Message }
    return ((@($said) | ForEach-Object { "$_" }) -join ' ').Trim()
}

function New-SafetyRestorePoint {
    # docs/AUDIT.md A-07: a restore point counts only when System Restore lists one made since this step started, so a
    # refusal that arrives as a warning (one per 24 hours) is not mistaken for success. Returns Created and Reason.
    $start = Get-Date
    $reason = Invoke-Checkpoint
    if (Test-RestorePointSince -Since $start -Points (Get-RestorePoints)) {
        Write-Log 'Restore point created (System Restore lists it).' 'OK'
        return [pscustomobject]@{ Created = $true; Reason = '' }
    }
    if (-not $reason) { $reason = 'Checkpoint-Computer reported nothing, but System Restore lists no restore point made since the run started.' }
    if ($Opt['EnableSystemRestore']) {
        Write-Log "Restore point not created. Windows said: $reason Turning System Protection on for $env:SystemDrive and trying again (EnableSystemRestore)."
        try {
            # Same approach as the Ultimate repo: allow several restore points per day, switch System Protection on, retry.
            Set-RegValue -Path 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'SystemRestorePointCreationFrequency' -Value 0
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        }
        catch { $reason = "$reason Turning System Protection on failed: $($_.Exception.Message)" }
        $retry = Invoke-Checkpoint
        if (Test-RestorePointSince -Since $start -Points (Get-RestorePoints)) {
            Write-Log 'Restore point created after turning System Protection on (-Revert does not turn it off again).' 'OK'
            return [pscustomobject]@{ Created = $true; Reason = '' }
        }
        if ($retry) { $reason = $retry }
    }
    $hint = " Run with -Enable EnableSystemRestore to turn System Protection on for $env:SystemDrive and allow more than one restore point a day."
    if ($Opt['EnableSystemRestore']) { $hint = ' The System Restore or Volume Shadow Copy service may be disabled on this machine.' }
    Write-Log "Restore point NOT created. Windows said: $reason$hint" 'WARN'
    return [pscustomobject]@{ Created = $false; Reason = $reason }
}

function Confirm-NoRestorePoint {
    # A run that turns off mitigations and deletes tasks should not start without a way back unless the user agrees.
    param([string]$Reason)
    if ($Force) { Write-Log "Continuing without a restore point because of -Force. Reason it failed: $Reason" 'WARN'; return $true }
    $answer = Read-Host "No restore point was created ($Reason). -Revert still undoes what this script records. Type YES to continue without one"
    return ($answer -ceq 'YES')
}

function Install-RuntimePackages {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Write-Log 'winget not found in this session (common on a fresh VM). Update App Installer from the Microsoft Store, open a new elevated window and run again.' 'WARN'
        return
    }
    $acceptable = @(0, -1978335189, -1978335135)
    $nvidia = Test-NvidiaGpu
    foreach ($id in $PackageIds) {
        if ($NvidiaOnlyPackages -contains $id -and -not $nvidia) { Write-Log "Package $id skipped: no NVIDIA GPU."; continue }
        if (Test-DryRun "winget install $id") { continue }
        # Tools this script later runs elevated go into an administrator-only folder (see Find-ProfileInspector).
        $scope = @()
        if ($NvidiaOnlyPackages -contains $id) { $scope = @('--scope', 'machine') }
        & winget.exe install --id $id --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements @scope | Out-Null
        if ($acceptable -contains $LASTEXITCODE) { Write-Log "Package ready: $id" 'OK' }
        else { $script:Failures++; Write-Log "Package $id returned exit code $LASTEXITCODE (check the ID with: winget search $id)" 'ERROR' }
    }
}

function Remove-BloatApps {
    if ($PSVersionTable.PSEdition -eq 'Core') { Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue }
    $removed = 0
    foreach ($pkg in @(Get-AppxPackage -AllUsers | Where-Object { -not $_.IsFramework -and -not $_.NonRemovable })) {
        if (-not (Test-NameMatch $pkg.Name $AppsToRemove)) { continue }
        if (Test-NameMatch $pkg.Name $KeepApps) { Write-Log "Kept (protected): $($pkg.Name)"; continue }
        # -Reapply removes only apps the earlier run removed that came back, never ones installed since.
        if ($script:Reapply -and @($script:State.Removed) -notcontains $pkg.Name) { continue }
        if (Test-DryRun "remove app $($pkg.Name)") { continue }
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            Add-StateRecord -Section 'Removed' -Item $pkg.Name; $removed++
            Write-Log "Removed app: $($pkg.Name)" 'OK'
        }
        catch { Write-Log "Could not remove $($pkg.Name). $($_.Exception.Message)" 'WARN' }
    }
    foreach ($prov in @(Get-AppxProvisionedPackage -Online)) {
        if (-not (Test-NameMatch $prov.DisplayName $AppsToRemove)) { continue }
        if (Test-NameMatch $prov.DisplayName $KeepApps) { continue }
        if ($script:Reapply -and @($script:State.Removed) -notcontains $prov.DisplayName) { continue }
        if (Test-DryRun "remove provisioned app $($prov.DisplayName)") { continue }
        try { Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null; Write-Log "Removed provisioned app: $($prov.DisplayName)" 'OK' }
        catch { Write-Log "Could not remove provisioned $($prov.DisplayName). $($_.Exception.Message)" 'WARN' }
    }
    if (-not $script:DryRun -and -not ($script:Reapply -and $removed -eq 0)) { Write-Log "Debloat removed $removed installed app(s). Not reversible by -Revert, reinstall from the Store or winget." 'WARN' }
}

function Get-NvidiaInstallerPath {
    if ($NvidiaInstaller) {
        if (-not (Test-Path -LiteralPath $NvidiaInstaller -PathType Leaf)) { throw "Installer not found: $NvidiaInstaller" }
        return $NvidiaInstaller
    }
    # Same lookup service and URL patterns as upstream NvidiaAutoinstall.ps1 (GeForce desktop and notebook DCH drivers).
    $uri = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php' +
    '?func=DriverManualLookup&psid=120&pfid=929&osID=57&languageCode=1033&isWHQL=1&dch=1&sort1=0&numberOfResults=4'
    $version = $NvidiaVersion
    if (-not $version) {
        $resp = Invoke-RestMethod -Uri $uri -UseBasicParsing
        $versions = @($resp.IDS.downloadInfo.Version)
        if ($versions.Count -eq 0) { throw 'Could not read the driver list from NVIDIA. Pass -NvidiaVersion (for example 576.80) or -NvidiaInstaller.' }
        $version = $versions[0]
    }
    $num = $version -replace 'hf', ''
    $kind = if ($NvidiaNotebook) { 'notebook' } else { 'desktop' }
    $base = "https://international.download.nvidia.com/Windows/$version"
    $candidates = if ($version -like '*hf') {
        @("$base/$num-$kind-win10-win11-64bit-international-dch-hf.exe", "$base/$num-desktop-notebook-win10-win11-64bit-international-dch.hf.exe")
    }
    else { @("$base/$version-$kind-win10-win11-64bit-international-dch-whql.exe") }

    if (Test-DryRun "download the NVIDIA $kind driver $version from $($candidates[0])") { return $null }
    $dest = Join-Path $env:TEMP "nvidia-driver-$version.exe"
    foreach ($url in $candidates) {
        try {
            Write-Log "Downloading $url"
            try { Start-BitsTransfer -Source $url -Destination $dest -ErrorAction Stop }
            catch { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop }
            if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -gt 100MB) { return $dest }
        }
        catch { Write-Log "Download failed for $url. $($_.Exception.Message)" 'WARN' }
    }
    throw "Could not download NVIDIA driver $version. Try -NvidiaVersion with another version, or download it from nvidia.com and use -NvidiaInstaller."
}

function Remove-NvidiaTelemetry {
    $store = Join-Path $env:windir 'System32\DriverStore\FileRepository'
    $dirs = @(Get-ChildItem -Path (Join-Path $store 'nv_dispi*') -Directory -ErrorAction SilentlyContinue)
    if ($dirs.Count -eq 0) { $dirs = @(Get-ChildItem -Path (Join-Path $store 'nvmdi*') -Directory -ErrorAction SilentlyContinue) }
    $plugins = '_DisplayDriverRAS.dll', '_NvMsgBusBroadcast.dll', '_nvtopps.dll', 'nvprofileupdaterplugin.dll', 'wksServicePlugin.dll', 'wksServicePluginZ.dll', '_NvGSTPlugin.dll'
    Stop-Service NVDisplay.ContainerLocalSystem -Force -ErrorAction SilentlyContinue
    foreach ($d in $dirs) {
        $targets = @()
        $dll = Join-Path $d.FullName 'NvTelemetry64.dll'
        if (Test-Path -LiteralPath $dll) { $targets += $dll }
        $pluginDir = Join-Path $d.FullName 'Display.NvContainer\plugins'
        if (Test-Path -LiteralPath $pluginDir) {
            $targets += @(Get-ChildItem -LiteralPath $pluginDir -Recurse -File | Where-Object { $plugins -contains $_.Name } | ForEach-Object { $_.FullName })
        }
        foreach ($f in $targets) {
            $null = Invoke-Native takeown.exe @('/f', $f)
            $null = Invoke-Native icacls.exe @($f, '/grant', '*S-1-5-32-544:F', '/t')
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $f) { Write-Log "Could not remove NVIDIA telemetry file: $f" 'WARN' }
            else { Write-Log "Removed NVIDIA telemetry file: $(Split-Path $f -Leaf)" 'OK' }
        }
    }
    foreach ($pattern in '*NvDriverUpdateCheckDaily*', '*NVIDIA GeForce Experience SelfUpdate*', '*NvProfileUpdaterDaily*', '*NvProfileUpdaterOnLogon*', '*NvTmRep_CrashReport*') {
        # Recorded like every other task change, so -Revert turns them back on.
        foreach ($task in @(Get-ScheduledTask -TaskName $pattern -ErrorAction SilentlyContinue)) { Disable-TaskRecorded -Task $task }
    }
    Start-Service NVDisplay.ContainerLocalSystem -ErrorAction SilentlyContinue
}

function Test-NvidiaGpu {
    return @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.PNPDeviceID -like 'PCI\VEN_10DE*' }).Count -gt 0
}

function Find-ProfileInspector {
    # This runs elevated, so only folders that need administrator rights to write are searched: never PATH or
    # %LOCALAPPDATA%, where any program running as the user could plant a file named like Profile Inspector.
    # Packages installs it per machine (winget --scope machine); Ultimate uses its own folder under Program Files.
    $candidates = @(
        @(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WinGet\Packages\Orbmu2k.nvidiaProfileInspector_*') -Directory -ErrorAction SilentlyContinue)
        @(Get-Item -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Nvidia Profile Inspector') -ErrorAction SilentlyContinue)
    )
    foreach ($dir in $candidates) {
        $hit = Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Depth 2 -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(nvidiaProfileInspector|Nvidia Profile Inspector)\.exe$' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Save-NvidiaDrs {
    # The driver keeps every profile setting in its DRS database. A copy taken before the first import is what
    # -Revert puts back, so the import is fully undone. Taken once: later runs must not overwrite the original.
    if ($script:State.NvidiaDrs) { return }
    $backup = Join-Path $StateDir 'nvidia-drs'
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $files = @(Get-ChildItem -LiteralPath $NvidiaDrsDir -Filter 'nvdrsdb*.bin' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { throw "No NVIDIA settings database found in $NvidiaDrsDir. Is the NVIDIA driver installed?" }
    foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination $backup -Force }
    Set-StateValue -Name 'NvidiaDrs' -Value $true
}

function Import-NvidiaSettings {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][object[]]$Settings)
    if (-not (Test-NvidiaGpu)) { Write-Log "$Label skipped: no NVIDIA GPU."; return }
    $list = ($Settings | ForEach-Object { "$($_.Name) = $($_.Value)" }) -join ', '
    if (Test-DryRun "import into the NVIDIA global profile with Profile Inspector ($Label): $list") { return }
    $npi = Find-ProfileInspector
    if (-not $npi) { throw 'NVIDIA Profile Inspector not found in an administrator-only folder. Keep the Packages option on, or install it with: winget install Orbmu2k.nvidiaProfileInspector --scope machine' }
    Save-NvidiaDrs
    $rows = foreach ($s in $Settings) {
        "      <ProfileSetting>`r`n        <SettingNameInfo>$($s.Name)</SettingNameInfo>`r`n        <SettingID>$($s.Id)</SettingID>`r`n        <SettingValue>$($s.Value)</SettingValue>`r`n        <ValueType>Dword</ValueType>`r`n      </ProfileSetting>"
    }
    $nip = "<?xml version=`"1.0`" encoding=`"utf-16`"?>`r`n<ArrayOfProfile>`r`n  <Profile>`r`n    <ProfileName>Base Profile</ProfileName>`r`n    <Executables />`r`n    <Settings>`r`n" + ($rows -join "`r`n") + "`r`n    </Settings>`r`n  </Profile>`r`n</ArrayOfProfile>"
    $file = Join-Path $StateDir ("nvidia-$Label.nip" -replace '\s', '-')
    Set-Content -LiteralPath $file -Value $nip -Encoding Unicode
    Get-ChildItem -LiteralPath $NvidiaDrsDir -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $npi -ArgumentList '-silentImport', '-mergeImport', '-silent', "`"$file`"" -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "Profile Inspector returned exit code $($proc.ExitCode) importing $Label." }
    Write-Log "NVIDIA global profile updated ($Label): $list. Takes effect for games started from now on." 'OK'
}

function Restore-NvidiaDrs {
    # Fixed backup path, never one read from the state file.
    $backup = Join-Path $StateDir 'nvidia-drs'
    $files = @(Get-ChildItem -LiteralPath $backup -Filter 'nvdrsdb*.bin' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { Write-Log "No NVIDIA settings backup in $backup, nothing to restore." 'WARN'; return }
    # The display container holds the database open; stop it while the files are put back.
    $svc = Get-Service -Name NVDisplay.ContainerLocalSystem -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { [void](Stop-ServiceBounded -Name $svc.Name) }
    try { foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination $NvidiaDrsDir -Force } }
    finally { if ($svc) { Start-Service -Name $svc.Name -ErrorAction SilentlyContinue } }
    Write-Log 'NVIDIA settings database restored from before the run. Restart Windows so every app sees it.' 'OK'
}

function Install-NvidiaDriver {
    if (-not (Test-NvidiaGpu)) { Write-Log 'No NVIDIA GPU detected, skipping the driver install.' 'WARN'; return }
    $installer = Get-NvidiaInstallerPath
    if (Test-DryRun "extract and install the NVIDIA driver ($(if ($installer) { $installer } else { 'the downloaded package' }))") { return }

    $sig = Get-AuthenticodeSignature -FilePath $installer
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'NVIDIA Corporation') {
        throw 'The installer is not validly signed by NVIDIA Corporation. Refusing to run it.'
    }
    $sevenZip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (-not (Test-Path -LiteralPath $sevenZip)) { throw '7-Zip is required to unpack the driver. Keep the Packages option on, or install 7-Zip first.' }

    # Same component selection as upstream: display driver, installer core and setup files.
    $files = @('Display.Driver', 'NVI2', 'EULA.txt', 'ListDevices.txt', 'setup.cfg', 'setup.exe')
    if ($NvidiaApp) {
        $num = $null
        try { $num = [version](($NvidiaVersion -replace 'hf', '')) } catch { }
        $files += $(if ($num -and $num -lt [version]'566.36') { 'GFExperience' } else { 'NvApp' })
    }
    if ($NvidiaHdAudio) { $files += 'HDAudio' }

    $work = Join-Path $env:TEMP ('nvidia-' + [guid]::NewGuid().ToString('N'))
    try {
        Write-Log "Extracting: $($files -join ', ')"
        & $sevenZip x $installer "-o$work" -y @files | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7-Zip failed with exit code $LASTEXITCODE" }
        $setup = Join-Path $work 'setup.exe'
        if (-not (Test-Path -LiteralPath $setup)) { throw 'setup.exe not found in the extracted package.' }
        $setupArgs = @('-s', '-noreboot', '-noeula', '-nofinish')
        if (-not $NvidiaNoClean) { $setupArgs += '-clean' }
        $proc = Start-Process -FilePath $setup -ArgumentList $setupArgs -WorkingDirectory $work -Wait -PassThru
        if (@(0, 1, 1641, 3010) -contains $proc.ExitCode) { Write-Log "NVIDIA driver installed (exit code $($proc.ExitCode)). Restart before gaming." 'OK' }
        else { throw "NVIDIA setup returned exit code $($proc.ExitCode)" }
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

    if ($Opt['NvidiaTelemetryStrip']) { Remove-NvidiaTelemetry }
    if (-not $NvidiaInstaller) { Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue }
}
#endregion

