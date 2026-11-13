#region Hosts file ------------------------------------------------------------------------
function Remove-HostsText {
    param([string]$Text, [string]$Name)
    $n = [regex]::Escape($Name)
    return [regex]::Replace($Text, "(?ms)^# FocusedTweaks BEGIN $n\r?\n.*?^# FocusedTweaks END $n\r?\n?", '')
}

function Write-HostsFile {
    param([string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    for ($i = 1; $i -le 5; $i++) {
        try { [IO.File]::WriteAllText($HostsPath, $Text, $enc); return }
        catch [System.IO.IOException] { Start-Sleep -Milliseconds 600 }
    }
    throw 'The hosts file is locked or protected (security software can block this).'
}

function Set-HostsBlock {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Domains)
    $block = "# FocusedTweaks BEGIN $Name`r`n" + (($Domains | ForEach-Object { "0.0.0.0 $_" }) -join "`r`n") + "`r`n# FocusedTweaks END $Name`r`n"
    if ($Ctx.Reapply -and ([IO.File]::ReadAllText($HostsPath)).Contains($block)) { return }
    if (Test-DryRun "add $($Domains.Count) entries to the hosts file ($Name)") { return }
    $backup = Join-Path $StateDir 'hosts.original'
    if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $HostsPath -Destination $backup -Force }
    $text = Remove-HostsText -Text ([IO.File]::ReadAllText($HostsPath)) -Name $Name
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`r`n" }
    if (-not (Test-RecordedFirst $script:State.Hosts { param($e) $e -eq $Name })) { Add-StateRecord -Section 'Hosts' -Item $Name }
    Write-HostsFile -Text ($text + $block)
    Write-Log "Hosts file: blocked $($Domains.Count) domain(s) ($Name)." 'OK'
}
#endregion

