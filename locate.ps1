# Sends the laptop's location to your phone (started by watcher.ps1 on a
# "locate" command). Runs as the signed-in user when there is one, because
# Windows location only answers inside a user session; otherwise as SYSTEM.
#
# Precise fix (Wi-Fi/GPS, tens of metres) needs Settings > Privacy & security >
# Location turned on. Without it, falls back to an approximate city-level
# location from the public IP address.
param(
    [switch]$NoUpload   # print instead of sending (testing)
)

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$config = Get-Content (Join-Path $dir 'config.json') -Raw | ConvertFrom-Json
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$url = "{0}/{1}" -f $config.ntfyServer.TrimEnd('/'), $config.ntfyTopic
$time = Get-Date -Format 'HH:mm:ss, ddd d MMM'

# 1. Windows location (Wi-Fi positioning / GPS).
$lat = $null; $lon = $null; $accuracy = $null; $source = $null
$why = ''
try {
    Add-Type -AssemblyName System.Device
    $w = New-Object System.Device.Location.GeoCoordinateWatcher([System.Device.Location.GeoPositionAccuracy]::High)
    [void]$w.TryStart($false, [TimeSpan]::FromSeconds(5))
    # A fresh Wi-Fi fix can take a few seconds; wait up to 20 s for a good one.
    for ($i = 0; $i -lt 40; $i++) {
        if ($w.Permission -eq 'Denied') { break }
        $c = $w.Position.Location
        if (-not $c.IsUnknown -and $c.HorizontalAccuracy -le 200) { break }
        Start-Sleep -Milliseconds 500
    }
    $c = $w.Position.Location
    if (-not $c.IsUnknown) {
        $lat = $c.Latitude; $lon = $c.Longitude; $accuracy = [math]::Round($c.HorizontalAccuracy); $source = 'precise'
    } elseif ($w.Permission -eq 'Denied') {
        $why = 'Windows location is off'
    } else {
        $why = 'no Windows location fix'
    }
    $w.Stop()
} catch { $why = 'Windows location unavailable' }

# 2. Public IP: always useful, and the fallback location.
$ipInfo = $null
try { $ipInfo = (& $curl -sS --max-time 10 https://ipinfo.io/json 2>$null) -join "`n" | ConvertFrom-Json } catch {}
if (-not $source -and $ipInfo -and $ipInfo.loc) {
    $parts = $ipInfo.loc -split ','
    $lat = [double]$parts[0]; $lon = [double]$parts[1]; $source = 'approximate'
}

# 3. Wi-Fi network name (Windows may hide it while location is off).
$ssid = $null
try {
    $line = netsh wlan show interfaces | Where-Object { $_ -match '^\s*SSID\s*:' } | Select-Object -First 1
    if ($line) { $ssid = ($line -split ':', 2)[1].Trim() }
} catch {}

# Build the message.
$lines = @($time)
if ($source -eq 'precise') {
    $lines += "Precise location (within about $accuracy m)"
} elseif ($source -eq 'approximate') {
    $place = (@($ipInfo.city, $ipInfo.region, $ipInfo.country) | Where-Object { $_ }) -join ', '
    $lines += "Approximate location: $place (from internet IP; $why)"
} else {
    $lines += "Location unknown ($why, and no internet IP lookup)."
}
if ($lat -ne $null) { $lines += ('{0:F5}, {1:F5}' -f $lat, $lon) }
if ($ssid) { $lines += "Wi-Fi: $ssid" }
if ($ipInfo -and $ipInfo.ip) { $lines += "Internet: $($ipInfo.ip)$(if ($ipInfo.org) { " ($($ipInfo.org))" })" }
if ($source -ne 'precise') { $lines += 'For a precise fix, turn on Windows location (Settings > Privacy & security > Location).' }
$message = $lines -join "`n"
# %2C, not a bare comma: a comma would split the ntfy action header.
$map = if ($lat -ne $null) { 'https://maps.google.com/?q={0:F6}%2C{1:F6}' -f $lat, $lon } else { $null }

if ($NoUpload) { Write-Output $message; if ($map) { Write-Output $map }; exit }

$headers = @(
    '-H', "Title: $env:COMPUTERNAME location",
    '-H', "Priority: $(if ($config.priority) { $config.priority } else { 'urgent' })",
    '-H', 'Tags: round_pushpin'
)
if ($map) { $headers += @('-H', "Click: $map", '-H', "Actions: view, Open map, $map") }
$bodyFile = Join-Path $env:TEMP ("unlock-alert-loc-{0}.txt" -f [guid]::NewGuid())
[System.IO.File]::WriteAllText($bodyFile, $message)
& $curl -sS --max-time 20 -o NUL @headers --data-binary "@$bodyFile" $url
[System.IO.File]::Delete($bodyFile)
