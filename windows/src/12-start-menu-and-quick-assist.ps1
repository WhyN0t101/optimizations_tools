#region Start menu and Quick Assist -------------------------------------------------------
$script:StartLayoutDir = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState'

function Get-DesktopFolders {
    $dirs = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'))
    return @($dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

function Clear-DesktopIcons {
    $panel = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons'
    # Recycle Bin, This PC, user files, Network, Control Panel.
    $system = '{645FF040-5081-101B-9F08-00AA002F954E}', '{20D04FE0-3AEA-1069-A2D8-08002B30309D}', '{59031a47-3f72-44a7-89c5-5595fe6b30ee}', '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}', '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}'
    foreach ($p in 'NewStartPanel', 'ClassicStartMenu') {
        foreach ($g in $system) { Set-RegValue -Path "$panel\$p" -Name $g -Value 1 }
    }
    if ($Opt['HideAllDesktopIcons']) {
        Set-RegValue -Path 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideIcons' -Value 1
    }
    # Shortcuts are moved (not deleted) so -Revert can put them back. Other files and folders are never touched.
    $moved = 0; $left = 0
    foreach ($dir in Get-DesktopFolders) {
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            if ($item.PSIsContainer -or $item.Extension -notin '.lnk', '.url') { $left++; continue }
            if (Test-DryRun "move the shortcut $($item.FullName) out of the desktop") { continue }
            $target = Join-Path $StateDir ('desktop-backup\' + (($dir -replace '[\\/:*?"<>| ]', '_')))
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            $to = Join-Path $target $item.Name
            # Recorded first: Restore-DesktopIcons only moves back what really arrived in the backup folder.
            Add-StateRecord -Section 'DesktopMoved' -Item ([pscustomobject]@{ From = $item.FullName; To = $to })
            Move-Item -LiteralPath $item.FullName -Destination $to -Force
            $moved++
        }
    }
    if (-not $Ctx.DryRun) {
        Write-Log "Desktop cleared: $moved shortcut(s) moved to the backup folder. $left file or folder item(s) were left on the desktop untouched." 'OK'
        $Ctx.ShellDirty = $true
    }
}

function Restore-DesktopIcons {
    foreach ($m in $script:State.DesktopMoved) {
        if ((Test-Path -LiteralPath $m.To) -and -not (Test-Path -LiteralPath $m.From)) {
            New-Item -ItemType Directory -Path (Split-Path $m.From -Parent) -Force | Out-Null
            Move-Item -LiteralPath $m.To -Destination $m.From -Force
        }
    }
    Write-Log 'Desktop shortcuts restored.' 'OK'
    $Ctx.ShellDirty = $true
}

function Clear-StartPins {
    if ([Environment]::OSVersion.Version.Build -le 19045) { Write-Log 'Start pin reset is for Windows 11 only, skipped.'; return }
    if (-not (Test-Path -LiteralPath $script:StartLayoutDir)) { Write-Log 'Start menu data folder not found, skipped.' 'WARN'; return }
    if (Test-DryRun 'clear every pinned app in the Start menu (the current layout is backed up first)') { return }
    $file = Join-Path $script:StartLayoutDir 'start2.bin'
    $backup = Join-Path $StateDir 'start2.bin.original'
    # Backed up once per run cycle, keyed on the state: a backup left by an earlier, reverted cycle is outdated.
    if (-not $script:State.StartLayout -and (Test-Path -LiteralPath $file)) {
        Copy-Item -LiteralPath $file -Destination $backup -Force
        Set-StateValue -Name 'StartLayout' -Value $backup
    }
    $bytes = [Convert]::FromBase64String(($EmptyStartLayout -join ''))
    # Same approach as upstream: stop the shell host, replace the layout file, let the Start menu reload.
    Stop-Process -Name sihost -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    [IO.File]::WriteAllBytes($file, $bytes)
    Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
    Write-Log 'Start menu pins cleared. If old pins still show, sign out and back in. All apps are still under All apps.' 'OK'
}

function Restore-StartPins {
    if (-not $script:State.StartLayout -or -not (Test-Path -LiteralPath $script:State.StartLayout)) { return }
    Stop-Process -Name sihost -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Copy-Item -LiteralPath $script:State.StartLayout -Destination (Join-Path $script:StartLayoutDir 'start2.bin') -Force
    Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
    # Used up: the next run takes a fresh backup of whatever layout exists then.
    Remove-Item -LiteralPath $script:State.StartLayout -Force -ErrorAction SilentlyContinue
    Write-Log 'Start menu layout restored.' 'OK'
}

# Optional features turned off by LegacyFeatures and HypervisorFeatures. Turning a feature off removes it from the
# running system; -Revert turns back on only the ones the run turned off. Names missing on a build are skipped.
$FeatureGroups = [ordered]@{
    LegacyFeatures     = @('SMB1Protocol', 'MicrosoftWindowsPowerShellV2Root', 'MicrosoftWindowsPowerShellV2', 'Recall', 'WorkFolders-Client', 'WindowsMediaPlayer')
    HypervisorFeatures = @('Microsoft-Hyper-V-All', 'VirtualMachinePlatform', 'HypervisorPlatform', 'Microsoft-Windows-Subsystem-Linux', 'Containers-DisposableClientVM')
}

function Get-EnabledFeatureNames {
    # Listing every feature through Windows servicing took about a minute on the Windows 11 ARM runner, in every dry
    # run, run and -Reapply pass (CI step times, 13 Nov 2026). Win32_OptionalFeature answers for just these names in
    # about a second. It may still call a feature turned off before the restart "enabled", so each one it calls enabled
    # is confirmed by name through servicing, which tells Enabled from DisablePending.
    param([string[]]$Names)
    $filter = (@($Names) | ForEach-Object { "Name='$($_ -replace "'", "''")'" }) -join ' OR '
    $maybe = @(Get-CimInstance -ClassName Win32_OptionalFeature -Filter $filter -ErrorAction Stop | Where-Object { $_.InstallState -eq 1 } | ForEach-Object { $_.Name })
    return @(foreach ($name in $maybe) {
            $f = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction Stop
            if ($f -and [string]$f.State -eq 'Enabled') { $name }
        })
}

function Disable-FeatureGroup {
    param([Parameter(Mandatory)][string]$Group)
    $on = @(Get-EnabledFeatureNames -Names $FeatureGroups[$Group])
    if ($on.Count -eq 0) { Write-Log "$Group`: none of $($FeatureGroups[$Group] -join ', ') is turned on."; return }
    $todo = @($on | Where-Object { -not (Test-DryRun "turn off the optional feature $_") })
    if ($todo.Count -eq 0) { return }
    foreach ($name in $todo) { if (@($script:State.Features) -notcontains $name) { Add-StateRecord -Section 'Features' -Item $name } }
    Set-FeatureState -Names $todo -Enable $false
}

function Set-FeatureState {
    # All names in one call: each call is one Windows servicing session and waits its turn in the servicing queue,
    # which took minutes per feature in the VM test of 13 Nov 2026. If the joint call fails, each name is tried alone
    # so the log says which one failed.
    param([Parameter(Mandatory)][string[]]$Names, [Parameter(Mandatory)][bool]$Enable)
    $verb = if ($Enable) { 'turned back on' } else { 'turned off' }
    $call = {
        param([string[]]$n)
        if ($Enable) { Enable-WindowsOptionalFeature -Online -FeatureName $n -All -NoRestart -ErrorAction Stop | Out-Null }
        else { Disable-WindowsOptionalFeature -Online -FeatureName $n -NoRestart -ErrorAction Stop | Out-Null }
    }
    try {
        & $call $Names
        foreach ($name in $Names) { Write-Log "Optional feature $verb`: $name (finishes at the next restart)." 'OK' }
        return
    }
    catch {
        if ($Names.Count -eq 1) { Write-Log "Could not change the optional feature $($Names[0]). $($_.Exception.Message)" 'WARN'; return }
        Write-Log "Changing the optional features $($Names -join ', ') together failed ($($_.Exception.Message)); trying one at a time."
    }
    foreach ($name in $Names) {
        try { & $call @(, $name); Write-Log "Optional feature $verb`: $name (finishes at the next restart)." 'OK' }
        catch { Write-Log "Could not change the optional feature $name. $($_.Exception.Message)" 'WARN' }
    }
}

function Restore-Features {
    # Only names this script knows, never whatever a state file says.
    $known = @($FeatureGroups.Values | ForEach-Object { $_ })
    $names = @()
    foreach ($name in @($script:State.Features)) {
        if ($known -notcontains $name) { Write-Log "Unexpected feature '$name' in the state file, not restoring it." 'WARN'; continue }
        $names += $name
    }
    if ($names.Count -gt 0) { Set-FeatureState -Names $names -Enable $true }
}

function Test-QuickAssistPresent {
    if (@(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*QuickAssist*' }).Count -gt 0) { return $true }
    return Test-Path -LiteralPath (Join-Path $env:windir 'System32\quickassist.exe')
}

function Remove-QuickAssist {
    # -Reapply: Quick Assist that is still gone is not drift.
    if ($Ctx.Reapply -and -not (Test-QuickAssistPresent)) { return }
    if (Test-DryRun 'remove Quick Assist (Windows capability, package and app)') { return }
    $removed = 0
    foreach ($cap in @(Get-WindowsCapability -Online | Where-Object { $_.Name -like 'App.Support.QuickAssist~~~~*' -and $_.State -eq 'Installed' })) {
        try { Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null; $removed++; Write-Log "Removed capability: $($cap.Name)" 'OK' }
        catch { Write-Log "Could not remove capability $($cap.Name). $($_.Exception.Message)" 'WARN' }
    }
    foreach ($pkg in @(Get-WindowsPackage -Online | Where-Object { $_.PackageName -like 'Microsoft-Windows-QuickAssist-Package*' -and $_.PackageName -notlike '*wow64*' -and $_.PackageState -eq 'Installed' })) {
        try { Remove-WindowsPackage -Online -PackageName $pkg.PackageName -NoRestart -ErrorAction Stop | Out-Null; $removed++; Write-Log "Removed package: $($pkg.PackageName)" 'OK' }
        catch { Write-Log "Could not remove package $($pkg.PackageName). $($_.Exception.Message)" 'WARN' }
    }
    if ($PSVersionTable.PSEdition -eq 'Core') { Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue }
    foreach ($app in @(Get-AppxPackage -AllUsers | Where-Object { $_.Name -like '*QuickAssist*' })) {
        try { Remove-AppxPackage -Package $app.PackageFullName -AllUsers -ErrorAction Stop; $removed++; Write-Log "Removed app: $($app.Name)" 'OK' }
        catch { Write-Log "Could not remove app $($app.Name). $($_.Exception.Message)" 'WARN' }
    }
    if ($removed -eq 0) { Write-Log 'Quick Assist was not found, nothing to remove.' }
    else { Write-Log 'Quick Assist removed. To get it back: Add-WindowsCapability -Online -Name App.Support.QuickAssist~~~~0.0.1.0, or install it from the Store.' 'WARN' }
}

function Get-OneDriveState {
    # Where OneDrive is installed (per user, or per machine in Program Files), its uninstallers, and the accounts
    # signed in for the user running the script.
    param([string]$LocalAppData = $env:LOCALAPPDATA, [string[]]$ProgramDirs = @($env:ProgramFiles, ${env:ProgramFiles(x86)}))
    $machineDirs = @($ProgramDirs | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'Microsoft OneDrive' })
    $installed = @(@((Join-Path $LocalAppData 'Microsoft\OneDrive')) + $machineDirs | ForEach-Object { Join-Path $_ 'OneDrive.exe' } | Where-Object { Test-Path -LiteralPath $_ })
    # This runs elevated, so uninstallers come only from folders that need administrator rights to write to: never
    # the per user copy under %LOCALAPPDATA%, which any program running as the user could replace. The Windows stub
    # below uninstalls a per user install as well.
    $uninstallers = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $machineDirs) {
        foreach ($f in @(Get-ChildItem -Path (Join-Path $d '*\OneDriveSetup.exe') -ErrorAction SilentlyContinue)) { $uninstallers.Add([pscustomobject]@{ Path = $f.FullName; Arguments = @('/uninstall', '/allusers') }) }
    }
    foreach ($f in @('System32', 'SysWOW64' | ForEach-Object { Join-Path $env:windir "$_\OneDriveSetup.exe" } | Where-Object { Test-Path -LiteralPath $_ })) { $uninstallers.Add([pscustomobject]@{ Path = $f; Arguments = @('/uninstall') }) }
    $accounts = @()
    $key = Open-RegKey -Full 'HKEY_CURRENT_USER\Software\Microsoft\OneDrive\Accounts'
    if ($key) {
        try {
            foreach ($n in $key.GetSubKeyNames()) {
                $k = $key.OpenSubKey($n)
                if (-not $k) { continue }
                try { if ([string]$k.GetValue('UserEmail', '')) { $accounts += $n } } finally { $k.Close() }
            }
        }
        finally { $key.Close() }
    }
    return [pscustomobject]@{ Installed = $installed; Uninstallers = $uninstallers.ToArray(); SignedIn = $accounts }
}

function Get-EdgeState {
    # Edge itself, its uninstallers (always under Program Files, which only administrators can write to), and whether
    # the WebView2 runtime is present. WebView2 lives in its own EdgeWebView folder and is never touched here.
    param([string[]]$ProgramDirs = @(${env:ProgramFiles(x86)}, $env:ProgramFiles))
    $roots = @($ProgramDirs | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'Microsoft\Edge\Application' })
    $installed = @($roots | ForEach-Object { Join-Path $_ 'msedge.exe' } | Where-Object { Test-Path -LiteralPath $_ })
    $setups = @($roots | ForEach-Object { Get-ChildItem -Path (Join-Path $_ '*\Installer\setup.exe') -ErrorAction SilentlyContinue } | Sort-Object { [version]($_.Directory.Parent.Name -replace '[^0-9.]', '') } -Descending -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $webview = @($ProgramDirs | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'Microsoft\EdgeWebView\Application' } | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
    return [pscustomobject]@{ Installed = ($installed.Count -gt 0); Paths = $installed; Setups = $setups; WebView2 = $webview }
}

function Get-DefaultHandler {
    # The ProgId the user chose for a URL protocol or file type, or '' when Windows decides.
    param([string]$Key)
    $snap = Get-RegSnapshot -Full "HKEY_CURRENT_USER\Software\Microsoft\Windows\Shell\Associations\$Key\UserChoice" -Name 'ProgId'
    if ($snap.Existed) { return [string]$snap.Value }
    return ''
}

function Get-EdgeRemovalBlock {
    # Why Edge must stay, or $null. Removing the default browser would leave links with nothing to open them.
    param([string]$HttpsHandler, [string]$HttpHandler)
    foreach ($h in $HttpsHandler, $HttpHandler) {
        if (-not $h -or $h -like 'MSEdge*') { return 'Edge is the default browser. Set another browser as default (Settings, Apps, Default apps) and run again.' }
    }
    return $null
}

function Remove-Edge {
    # Gone or kept, never half: Edge's own uninstaller runs, and Windows lets it finish only where Edge may be
    # uninstalled (device region in the EEA, Windows 11 23H2 or later). Elsewhere it refuses and Edge is kept; the
    # region is not faked. WebView2 and Microsoft Edge Update stay: apps embed WebView2 and it updates through them.
    $edge = Get-EdgeState
    if (-not $edge.Installed) { Write-Log 'Microsoft Edge is not installed.'; return }
    if ($Ctx.Reapply -and @($script:State.Removed) -notcontains 'Microsoft.Edge') { return }
    $block = Get-EdgeRemovalBlock -HttpsHandler (Get-DefaultHandler 'UrlAssociations\https') -HttpHandler (Get-DefaultHandler 'UrlAssociations\http')
    if ($block) { Write-Log "Edge kept: $block" 'WARN'; return }
    if ((Get-DefaultHandler 'FileAssociations\.pdf') -like 'MSEdge*') { Write-Log 'Edge opens PDF files now; after the removal choose another PDF app (Settings, Apps, Default apps).' 'WARN' }
    if ($edge.Setups.Count -eq 0) { Write-Log "Edge kept: its uninstaller was not found under $($edge.Paths -join ', ')." 'WARN'; return }
    $setup = $edge.Setups[0]
    if (Test-DryRun "uninstall Microsoft Edge with $setup (WebView2 stays)") { return }
    $sig = Get-AuthenticodeSignature -FilePath $setup
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft Corporation') { throw "The Edge uninstaller $setup is not validly signed by Microsoft. Refusing to run it." }
    Stop-Process -Name msedge -Force -ErrorAction SilentlyContinue   # only the browser; msedgewebview2 keeps running
    $proc = Start-Process -FilePath $setup -ArgumentList '--uninstall', '--system-level', '--force-uninstall', '--verbose-logging' -PassThru -WindowStyle Hidden
    $null = $proc.Handle
    if (-not $proc.WaitForExit(300000)) { Write-Log 'The Edge uninstaller did not finish within 5 minutes.' 'WARN' }
    if ((Get-EdgeState).Installed) {
        Write-Log "Edge kept: Windows refused the uninstall (exit code $($proc.ExitCode)). It allows it only when the device region is in the European Economic Area." 'WARN'
        return
    }
    if (@($script:State.Removed) -notcontains 'Microsoft.Edge') { Add-StateRecord -Section 'Removed' -Item 'Microsoft.Edge' }
    $links = @(
        (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Microsoft Edge.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Microsoft Edge.lnk'),
        (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Microsoft Edge.lnk'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk'))
    foreach ($l in $links) { Remove-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue }
    Write-Log "Microsoft Edge uninstalled; WebView2 $(if ((Get-EdgeState).WebView2) { 'is still installed' } else { 'was not installed before either' }). Your Edge profile stays in %LOCALAPPDATA%\Microsoft\Edge. To get Edge back: winget install Microsoft.Edge." 'OK'
}

function Remove-OneDrive {
    # Gone or kept, never half: with an account signed in, files that live only in the cloud would become unreachable
    # here, so OneDrive stays as it is and the log says why.
    $od = Get-OneDriveState
    if ($od.SignedIn.Count -gt 0) {
        Write-Log "OneDrive kept: an account is signed in ($($od.SignedIn -join ', ')). Removing it would leave files that are only in the cloud unreachable here. Sign out of OneDrive (Settings, Account, Unlink this PC) and run again, or skip RemoveOneDrive." 'WARN'
        return
    }
    Set-TweakList $OneDriveRegs
    if ($od.Installed.Count -eq 0) { Write-Log 'OneDrive is not installed; the policy keeps it from setting itself up again.'; return }
    if (Test-DryRun "uninstall OneDrive ($($od.Installed -join ', '))") { return }
    Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
    foreach ($u in $od.Uninstallers) {
        if (@((Get-OneDriveState).Installed).Count -eq 0) { break }
        $proc = Start-Process -FilePath $u.Path -ArgumentList $u.Arguments -PassThru -WindowStyle Hidden
        $null = $proc.Handle   # keeps the exit code readable after the process ends
        if (-not $proc.WaitForExit(300000)) { Write-Log "OneDrive uninstaller $($u.Path) did not finish within 5 minutes." 'WARN'; continue }
        Write-Log "OneDrive uninstaller $($u.Path) $($u.Arguments -join ' ') exited with code $($proc.ExitCode)."
    }
    $left = @((Get-OneDriveState).Installed)
    if ($left.Count -eq 0) { Write-Log 'OneDrive uninstalled. Files in the OneDrive folder stay on disk. To get it back: -Revert (lifts the policy), then winget install Microsoft.OneDrive.' 'OK' }
    else { $Ctx.Failures++; Write-Log "OneDrive is still installed: $($left -join ', ')." 'ERROR' }
}
#endregion

