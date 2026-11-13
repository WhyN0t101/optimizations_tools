#Requires -Version 5.1
<#
.SYNOPSIS
    Checks the mouse: Enhance pointer precision, pointer speed, display scaling and the background polling cap, then
    measures the real polling rate while you move the mouse. Reads only; changes nothing and downloads nothing.

.DESCRIPTION
    A small window opens. Move the mouse in fast circles inside it until the time is up; pauses are left out of the
    result. The rate comes from Windows raw input events (the same input games read), so it shows what the mouse
    really delivers, not what its software says. Rates of 4000 Hz and up may read a little low: PowerShell cannot
    take every event at that speed.

        .\tools\Test-Mouse.ps1              # settings and a 5 second polling test
        .\tools\Test-Mouse.ps1 -Seconds 10
        .\tools\Test-Mouse.ps1 -SkipPolling # settings only
        .\tools\Test-Mouse.ps1 -Json        # one JSON object, for scripts

.PARAMETER Seconds
    How long to measure while the mouse moves (2 to 60).
#>
[CmdletBinding()]
param(
    [ValidateRange(2, 60)][int]$Seconds = 5,
    [switch]$SkipPolling,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows Forms needs Windows PowerShell here; PowerShell 7 hands over to it with the same parameters.
if ($PSVersionTable.PSEdition -eq 'Core') {
    $argsOut = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Seconds', $Seconds)
    if ($SkipPolling) { $argsOut += '-SkipPolling' }
    if ($Json) { $argsOut += '-Json' }
    & powershell.exe @argsOut
    exit $LASTEXITCODE
}

function Get-MouseSettings {
    $mouse = Get-ItemProperty -Path 'HKCU:\Control Panel\Mouse'
    $desktop = Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop'
    $epp = ([string]$mouse.MouseSpeed -ne '0')
    $sens = [int]$mouse.MouseSensitivity
    $throttle = if ($mouse.PSObject.Properties['RawMouseThrottleEnabled']) { [int]$mouse.RawMouseThrottleEnabled } else { $null }
    $dpi = if ($desktop.PSObject.Properties['LogPixels']) { [int]$desktop.LogPixels } else { 96 }
    [pscustomobject]@{
        EnhancePointerPrecision = $epp
        MouseSpeed              = [string]$mouse.MouseSpeed
        MouseThreshold1         = [string]$mouse.MouseThreshold1
        MouseThreshold2         = [string]$mouse.MouseThreshold2
        PointerSpeed            = $sens
        BackgroundThrottle      = $throttle
        ScalingPercent          = [int][Math]::Round($dpi / 96 * 100)
    }
}

function Get-SettingFindings([pscustomobject]$s) {
    $out = [System.Collections.Generic.List[object]]::new()
    $add = { param($Status, $Text) $out.Add([pscustomobject]@{ Status = $Status; Check = $Text }) }
    if ($s.EnhancePointerPrecision) {
        & $add 'WARN' "Enhance pointer precision is ON (MouseSpeed $($s.MouseSpeed), thresholds $($s.MouseThreshold1)/$($s.MouseThreshold2)): the pointer speeds up with hand speed. FocusedTweaks MouseAccel turns it off."
    } else { & $add 'OK' 'Enhance pointer precision is off: the pointer moves the same distance for the same hand movement.' }
    if ($s.PointerSpeed -eq 10) { & $add 'OK' 'Pointer speed is 10 (the middle notch, 6 of 11): one count moves one pixel.' }
    else { & $add 'WARN' "Pointer speed is $($s.PointerSpeed), not 10 (the middle notch): Windows scales every count, so some are skipped or doubled. Set the speed in the mouse software (DPI) instead." }
    if ($s.BackgroundThrottle -eq 0) { & $add 'OK' 'Background polling cap is off: windows in the background get every mouse report.' }
    else { & $add 'INFO' 'Background polling cap is on (Windows default): windows in the background, such as a game on a second screen, get about 125 reports a second. FocusedTweaks MouseFullRateBackground turns it off.' }
    if ($s.ScalingPercent -ne 100) { & $add 'INFO' "Display scaling is $($s.ScalingPercent)%. Games with raw input are not affected; FocusedTweaks MouseAccel picks the matching pointer curve for desktop use." }
    return $out
}

$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class FtMousePollForm : Form {
    [StructLayout(LayoutKind.Sequential)]
    struct RAWINPUTDEVICE { public ushort UsagePage; public ushort Usage; public uint Flags; public IntPtr Target; }

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devices, uint count, uint size);

    const int WM_INPUT = 0x00FF;
    readonly Stopwatch clock = Stopwatch.StartNew();
    readonly Label label;
    readonly Timer timer;
    readonly double gapMs;
    readonly double wantMs;
    double lastMs = -1;
    double movingMs;
    public readonly List<double> Intervals = new List<double>();

    public FtMousePollForm(int seconds, double gap) {
        wantMs = seconds * 1000.0;
        gapMs = gap;
        Text = "FocusedTweaks mouse polling test";
        Width = 560; Height = 260;
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;
        label = new Label();
        label.Dock = DockStyle.Fill;
        label.Font = new Font("Segoe UI", 13);
        label.TextAlign = ContentAlignment.MiddleCenter;
        label.Text = "Move the mouse in fast circles inside this window.\nClose the window to stop early.";
        Controls.Add(label);
        timer = new Timer();
        timer.Interval = 200;
        timer.Tick += delegate { Refresh_(); };
        timer.Start();
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        RAWINPUTDEVICE[] d = new RAWINPUTDEVICE[1];
        d[0].UsagePage = 1; d[0].Usage = 2; d[0].Flags = 0; d[0].Target = Handle;
        if (!RegisterRawInputDevices(d, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)))) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_INPUT) {
            double now = clock.Elapsed.TotalMilliseconds;
            if (lastMs >= 0) {
                double d = now - lastMs;
                // A gap longer than this is a pause in movement, not a slow report.
                if (d < gapMs) { Intervals.Add(d); movingMs += d; }
            }
            lastMs = now;
        }
        base.WndProc(ref m);
    }

    void Refresh_() {
        if (movingMs >= wantMs) { timer.Stop(); Close(); return; }
        int n = Intervals.Count;
        if (n < 20) return;
        double sum = 0;
        int take = Math.Min(n, 400);
        for (int i = n - take; i < n; i++) sum += Intervals[i];
        label.Text = string.Format("About {0:0} Hz\n\nKeep moving: {1:0.0} of {2:0} s measured", 1000.0 * take / sum, movingMs / 1000.0, wantMs / 1000.0);
    }
}
'@

function Measure-PollingRate([int]$Seconds) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    if (-not ('FtMousePollForm' -as [type])) {
        Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms, System.Drawing
    }
    # 25 ms: slower than any mouse report (125 Hz is 8 ms), faster than a hand pausing.
    $form = New-Object FtMousePollForm -ArgumentList $Seconds, 25.0
    [void]$form.ShowDialog()
    $iv = @($form.Intervals | Where-Object { $_ -gt 0.01 } | Sort-Object)
    $form.Dispose()
    if ($iv.Count -lt 200) { return $null }
    $median = $iv[[int]($iv.Count / 2)]
    $p10 = $iv[[int]($iv.Count * 0.1)]
    $p90 = $iv[[int]($iv.Count * 0.9)]
    $hz = 1000 / $median
    $standard = @(125, 250, 500, 1000, 2000, 4000, 8000) | Sort-Object { [Math]::Abs([Math]::Log($_ / $hz)) } | Select-Object -First 1
    $stable = @($iv | Where-Object { [Math]::Abs($_ - $median) -le $median * 0.25 }).Count / $iv.Count
    [pscustomobject]@{
        Reports       = $iv.Count
        MedianHz      = [Math]::Round($hz)
        NearestRate   = $standard
        SlowestHz     = [Math]::Round(1000 / $p90)
        FastestHz     = [Math]::Round(1000 / $p10)
        StablePercent = [Math]::Round($stable * 100, 1)
    }
}

function Get-PollingFindings($p) {
    if (-not $p) { return @([pscustomobject]@{ Status = 'WARN'; Check = 'Too little movement to measure. Run it again and keep the mouse moving in the window.' }) }
    $out = @()
    $out += [pscustomobject]@{ Status = 'INFO'; Check = "Polling rate about $($p.MedianHz) Hz (nearest standard rate $($p.NearestRate) Hz; 80% of reports between $($p.SlowestHz) and $($p.FastestHz) Hz, $($p.Reports) reports)." }
    if ($p.NearestRate -lt 1000) {
        $out += [pscustomobject]@{ Status = 'WARN'; Check = "Below 1000 Hz. Most gaming mice can do 1000 Hz or more: set it in the mouse software. Wireless mice may also drop rate on battery saving." }
    }
    if ($p.StablePercent -lt 90) {
        $out += [pscustomobject]@{ Status = 'WARN'; Check = "Only $($p.StablePercent)% of reports arrive on time (within 25% of the usual gap). Try another USB port on the PC itself (not a hub or front panel), a wired connection, and FocusedTweaks DevicePowerSaving." }
    } else {
        $out += [pscustomobject]@{ Status = 'OK'; Check = "$($p.StablePercent)% of reports arrive on time: the rate is steady." }
    }
    return $out
}

$settings = Get-MouseSettings
$findings = @(Get-SettingFindings $settings)
$polling = $null
if (-not $SkipPolling) {
    if (-not $Json) { Write-Host 'A window opens: move the mouse in fast circles inside it.' }
    $polling = Measure-PollingRate -Seconds $Seconds
    $findings += @(Get-PollingFindings $polling)
}

if ($Json) {
    [pscustomobject]@{ Settings = $settings; Polling = $polling; Findings = $findings } | ConvertTo-Json -Depth 4
} else {
    $colors = @{ OK = 'Green'; WARN = 'Yellow'; INFO = 'Gray' }
    foreach ($f in $findings) { Write-Host ("[{0,-4}] {1}" -f $f.Status, $f.Check) -ForegroundColor $colors[$f.Status] }
}
exit 0
