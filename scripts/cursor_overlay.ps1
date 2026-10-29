# ChatGPT-style cursor overlay: rounded arrow + soft circular glow tracking the real cursor.
# The arrow/glow colour matches the running OpenBot agent's avatar hue by default.
# Usage:
#   powershell -ExecutionPolicy Bypass -File cursor_overlay.ps1 [-DurationSec 9] [-Pattern demo|point] [-X n] [-Y n]
#              [-Color "#RRGGBB"] [-Hue 0-360] [-AgentId <guid>]
# -Pattern demo : sweeps a figure-eight across the screen (showcase).
# -Pattern point: glides from the current cursor position to -X,-Y (physical pixels) and holds.
# -Color  : hex colour override (wins over -Hue).
# -Hue    : HSL hue 0-360 for the agent-style colour; default: auto-detect agent's avatarHue.
# -AgentId: OpenBot agent id for hue auto-detection; default: inferred from script/cwd path.
param(
    [int]$DurationSec = 9,
    [ValidateSet('demo', 'point')]
    [string]$Pattern = 'demo',
    [int]$X = -1,
    [int]$Y = -1,
    [string]$Color = '',
    [double]$Hue = -1,
    [string]$AgentId = ''
)

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class CursorOverlayNative {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out P p);
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
  [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr dc, int idx);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }
  public static int DpiX() { IntPtr dc = GetDC(IntPtr.Zero); int v = GetDeviceCaps(dc, 88); ReleaseDC(IntPtr.Zero, dc); return v; }
}
'@

# ---- colour resolution: -Color hex > -Hue > agent avatarHue > ChatGPT blue (hue 221) ----
function Convert-HslToRgb([double]$h, [double]$s, [double]$l) {
    $h = ((($h % 360) + 360) % 360) / 360.0
    if ($s -le 0) { $v = [int][Math]::Round($l * 255); return , @($v, $v, $v) }
    $q = if ($l -lt 0.5) { $l * (1 + $s) } else { $l + $s - $l * $s }
    $p = 2 * $l - $q
    function HuePart([double]$t) {
        if ($t -lt 0) { $t += 1 }; if ($t -gt 1) { $t -= 1 }
        if ($t -lt 1.0 / 6) { return $p + ($q - $p) * 6 * $t }
        if ($t -lt 1.0 / 2) { return $q }
        if ($t -lt 2.0 / 3) { return $p + ($q - $p) * (2.0 / 3 - $t) * 6 }
        return $p
    }
    , @(
        [int][Math]::Round((HuePart ($h + 1.0 / 3)) * 255),
        [int][Math]::Round((HuePart $h) * 255),
        [int][Math]::Round((HuePart ($h - 1.0 / 3)) * 255)
    )
}

function Find-AgentHue([string]$agentId) {
    $db = Join-Path $env:APPDATA 'OpenBot\openbot.db'
    if (-not (Test-Path $db)) { return $null }
    $tmp = Join-Path $env:TEMP ('ob_hue_' + [guid]::NewGuid().ToString('N') + '.db')
    try {
        Copy-Item $db $tmp -Force
        $s = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::GetEncoding('ISO-8859-1'))
        $m = [regex]::Match($s, ('"id":"' + $agentId + '".{0,800}?"avatarHue":\s*(\d+)'))
        if ($m.Success) { return [int]$m.Groups[1].Value }
    } catch {} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    return $null
}

$rgb = $null
$usedHue = $null
if ($Color) {
    $hex = $Color.TrimStart('#')
    if ($hex -notmatch '^[0-9a-fA-F]{6}$') { throw "-Color must be #RRGGBB" }
    $rgb = @(
        [Convert]::ToInt32($hex.Substring(0, 2), 16),
        [Convert]::ToInt32($hex.Substring(2, 2), 16),
        [Convert]::ToInt32($hex.Substring(4, 2), 16)
    )
} else {
    if ($Hue -lt 0 -and -not $AgentId) {
        foreach ($p in @($PSScriptRoot, (Get-Location).Path)) {
            $m = [regex]::Match($p, 'agent-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
            if ($m.Success) { $AgentId = $m.Value; break }
        }
    }
    if ($Hue -lt 0 -and $AgentId) {
        $h = Find-AgentHue $AgentId
        if ($null -ne $h) { $Hue = $h }
    }
    if ($Hue -lt 0) { $Hue = 221 }  # ChatGPT blue fallback
    $usedHue = $Hue
    $rgb = Convert-HslToRgb $Hue 0.72 0.53
}

$app = [System.Windows.Application]::Current
if (-not $app) { $app = New-Object System.Windows.Application }

# SetCursorPos is physical pixels; WPF window Left/Top are DIPs. Scale between them.
$scale = [CursorOverlayNative]::DpiX() / 96.0
if ($scale -le 0) { $scale = 1.0 }
$physW = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
$physH = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height

# Overlay window: transparent, borderless, topmost, click-through, not in taskbar.
$win = New-Object System.Windows.Window
$win.WindowStyle = 'None'
$win.AllowsTransparency = $true
$win.Background = 'Transparent'
$win.Topmost = $true
$win.ShowInTaskbar = $false
$win.ShowActivated = $false
$win.IsHitTestVisible = $false
$win.Focusable = $false
$win.Width = 64
$win.Height = 64

$cv = New-Object System.Windows.Controls.Canvas

# Hotspot (arrow tip) centred in the window so the 52px glow is never clipped by the window edge.
$tipX = 32.0
$tipY = 32.0

$glow = New-Object System.Windows.Shapes.Ellipse
$glow.Width = 52
$glow.Height = 52
$rg = New-Object System.Windows.Media.RadialGradientBrush
$rg.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(55, $rgb[0], $rgb[1], $rgb[2]), 0.0)))
$rg.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(0, $rgb[0], $rgb[1], $rgb[2]), 1.0)))
$glow.Fill = $rg
[System.Windows.Controls.Canvas]::SetLeft($glow, ($tipX - 26))
[System.Windows.Controls.Canvas]::SetTop($glow, ($tipY - 26))

# Arrow path scaled to 70%. Rounded look = fat white round-join stroke (outline) under
# a coloured round-join stroke + fill (body) of the same path.
$geo = [System.Windows.Media.Geometry]::Parse('M8,6 L8,26 L13.6,20.8 L17.4,29.6 L21,28 L17.2,19.4 L25,19.4 Z')
$stt = New-Object System.Windows.Media.ScaleTransform(0.7, 0.7)
$geo = $geo.Clone()
$geo.Transform = $stt
$geo = $geo.GetFlattenedPathGeometry()
$geo.Freeze()
$cL = $tipX - 8 * 0.7
$cT = $tipY - 6 * 0.7

$brW = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(235, 255, 255, 255))
$brW.Freeze()
$brB = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, $rgb[0], $rgb[1], $rgb[2]))
$brB.Freeze()

$outline = New-Object System.Windows.Shapes.Path
$outline.Data = $geo
$outline.Fill = $brW
$outline.Stroke = $brW
$outline.StrokeThickness = 5.0
$outline.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
$outline.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
$outline.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
[System.Windows.Controls.Canvas]::SetLeft($outline, $cL)
[System.Windows.Controls.Canvas]::SetTop($outline, $cT)

$body = New-Object System.Windows.Shapes.Path
$body.Data = $geo
$body.Fill = $brB
$body.Stroke = $brB
$body.StrokeThickness = 2.6
$body.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
$body.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
$body.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
[System.Windows.Controls.Canvas]::SetLeft($body, $cL)
[System.Windows.Controls.Canvas]::SetTop($body, $cT)

$cv.Children.Add($glow) | Out-Null
$cv.Children.Add($outline) | Out-Null
$cv.Children.Add($body) | Out-Null
$win.Content = $cv

# Motion in DIP units; converted to physical pixels only for SetCursorPos.
$w = $physW / $scale
$h = $physH / $scale
$ticks = 0
$totalTicks = [int]($DurationSec * 60)

# point pattern: capture start, ease to target
$cp = New-Object CursorOverlayNative+P
[CursorOverlayNative]::GetCursorPos([ref]$cp) | Out-Null
$sx = $cp.X / $scale
$sy = $cp.Y / $scale
if ($X -lt 0) { $X = $cp.X }
if ($Y -lt 0) { $Y = $cp.Y }
$tx = $X / $scale
$ty = $Y / $scale

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(16)
$timer.Add_Tick({
    $script:ticks++
    if ($Pattern -eq 'demo') {
        $a = $script:ticks * 0.022
        $x = ($w / 2) + ($w / 3.2) * [Math]::Sin($a)
        $y = ($h / 2) + ($h / 4.2) * [Math]::Sin(2 * $a)
    }
    else {
        $t = [Math]::Min(1.0, $script:ticks / ([Math]::Max(1, $totalTicks * 0.4)))
        $e = $t * $t * (3 - 2 * $t)  # smoothstep ease
        $x = $sx + ($tx - $sx) * $e
        $y = $sy + ($ty - $sy) * $e
    }
    $win.Left = $x - $tipX
    $win.Top = $y - $tipY
    [CursorOverlayNative]::SetCursorPos([int]($x * $scale), [int]($y * $scale)) | Out-Null
    if ($script:ticks -ge $totalTicks) {
        $timer.Stop()
        $win.Close()
    }
})
$win.Show()
$timer.Start()
$app.Run() | Out-Null
$colorTag = if ($usedHue -ne $null) { "hue=$([int]$usedHue)" } else { "color=#$($Color.TrimStart('#'))" }
Write-Output "overlay finished (agent=$AgentId $colorTag rgb=$($rgb -join ','))"
