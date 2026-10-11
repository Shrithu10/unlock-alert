# Runs as the signed-in user (started by watcher.ps1 on a "screenshot" command
# from the phone), because only the user's own session can see the desktop.
# Captures all monitors and posts the image to the ntfy alert topic.
param(
    [string]$OutFile = '',   # keep the image here (testing); default is a temp file
    [switch]$NoUpload        # capture only, don't send (testing)
)

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$config = Get-Content (Join-Path $dir 'config.json') -Raw | ConvertFrom-Json
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$url = "{0}/{1}" -f $config.ntfyServer.TrimEnd('/'), $config.ntfyTopic
$priority = if ($config.priority) { $config.priority } else { 'urgent' }
$time = Get-Date -Format 'HH:mm:ss, ddd d MMM'

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
# Without this, on a scaled display (125%, 150%...) only part of the screen is captured.
Add-Type -Namespace UnlockAlert -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[UnlockAlert.Dpi]::SetProcessDPIAware() | Out-Null

function Send-Text($title, $message) {
    if ($NoUpload) { Write-Output "$title - $message"; return }
    & $curl -sS --max-time 15 -o NUL -H "Title: $title" -H "Priority: $priority" -H 'Tags: camera' -d $message $url
}

$path = if ($OutFile) { $OutFile } else { Join-Path $env:TEMP ("unlock-alert-shot-{0}.jpg" -f [guid]::NewGuid()) }
try {
    $area = [System.Windows.Forms.SystemInformation]::VirtualScreen   # all monitors
    $shot = New-Object System.Drawing.Bitmap $area.Width, $area.Height
    $g = [System.Drawing.Graphics]::FromImage($shot)
    $g.CopyFromScreen($area.Left, $area.Top, 0, 0, $shot.Size)
    $g.Dispose()

    # Shrink to at most 3840 px wide (two 1080p screens side by side) to keep uploads small.
    $scale = [Math]::Min(1.0, 3840 / $shot.Width)
    $out = $shot
    if ($scale -lt 1.0) {
        $out = New-Object System.Drawing.Bitmap ([int]($shot.Width * $scale)), ([int]($shot.Height * $scale))
        $g2 = [System.Drawing.Graphics]::FromImage($out)
        $g2.InterpolationMode = 'HighQualityBicubic'
        $g2.DrawImage($shot, 0, 0, $out.Width, $out.Height)
        $g2.Dispose()
    }

    $jpeg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
    $params = New-Object System.Drawing.Imaging.EncoderParameters 1
    $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), 70L
    $out.Save($path, $jpeg, $params)
    if ($out -ne $shot) { $out.Dispose() }
    $shot.Dispose()
} catch {
    # Typically the screen is locked (the desktop isn't visible to the session).
    Send-Text "$env:COMPUTERNAME screenshot failed" "$time`nCould not capture the screen (it may be locked): $($_.Exception.Message)"
    exit 1
}

if ($NoUpload) { Write-Output $path; exit }

$name = 'screen-{0}.jpg' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
& $curl -sS --max-time 60 -o NUL -T $path `
    -H "Title: $env:COMPUTERNAME screen right now" `
    -H "Message: $time" `
    -H "Filename: $name" `
    -H "Priority: $priority" `
    -H 'Tags: camera' $url
if (-not $OutFile) { [System.IO.File]::Delete($path) }
