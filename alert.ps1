# Started by watcher.ps1 (as SYSTEM) for each logon/unlock/wake/boot event.
# Sends a push notification via ntfy and appends to a local log.
param(
    [ValidateSet('Failed', 'Unlock', 'Wake', 'Boot', 'Test')]
    [string]$Kind = 'Test',
    [string]$User = '',
    [string]$Domain = '',
    [string]$LogonType = '',
    [string]$Status = '',
    [string]$SubStatus = '',
    [string]$Ip = ''
)

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $dir 'alerts.log'
$config = Get-Content (Join-Path $dir 'config.json') -Raw | ConvertFrom-Json

function Write-Log($msg) {
    Add-Content -Path $logFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
}

# Task Scheduler leaves "$(Name)" literally when a value is missing.
foreach ($v in 'User', 'Domain', 'LogonType', 'Status', 'SubStatus', 'Ip') {
    if ((Get-Variable $v -ValueOnly) -like '$(*') { Set-Variable $v '' }
}

# Skip a kind if the same kind already alerted within $seconds (Windows writes
# two 4624s per interactive logon, and wake events can burst).
# Both copies start in the same instant, so the check-and-stamp is done under a
# machine-wide mutex; otherwise both see "not sent yet" and both notify.
function Test-RecentlySent($key, $seconds) {
    $mutex = New-Object System.Threading.Mutex($false, "Global\UnlockAlert-$key")
    try {
        try { $mutex.WaitOne(10000) | Out-Null } catch [System.Threading.AbandonedMutexException] {}
        $stamp = Join-Path $dir "last-$key.txt"
        if ((Test-Path $stamp) -and ((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalSeconds -lt $seconds) {
            return $true
        }
        Set-Content -Path $stamp -Value (Get-Date -Format o)
        return $false
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

$logonTypes = @{
    '2' = 'at the keyboard'; '3' = 'over the network'; '7' = 'unlock screen'
    '10' = 'remote desktop'; '11' = 'cached credentials'; 'PIN' = 'Windows Hello PIN'
}
$reasons = @{
    '0xc0000380' = 'wrong PIN'
    '0xc000006a' = 'wrong password'
    '0xc0000064' = 'user does not exist'
    '0xc000006d' = 'bad credentials (wrong PIN/password)'
    '0xc0000234' = 'account locked out'
    '0xc0000072' = 'account disabled'
    '0xc0000071' = 'password expired'
    '0xc000006f' = 'outside allowed hours'
    '0xc0000133' = 'clock out of sync'
}

$computer = $env:COMPUTERNAME
$time = Get-Date -Format 'HH:mm:ss, ddd d MMM'
$how = $logonTypes[$LogonType]
if (-not $how -and $LogonType) { $how = "logon type $LogonType" }

switch ($Kind) {
    'Failed' {
        if (-not $config.notifyFailed) { exit }
        $reason = $reasons[$SubStatus.ToLower()]
        if (-not $reason) { $reason = $reasons[$Status.ToLower()] }
        if (-not $reason) { $reason = "status $SubStatus" }
        $title = "FAILED sign-in on $computer"
        $body = "$time`nReason: $reason`nHow: $how"
        # Hello PIN failures are logged under SYSTEM, which says nothing useful.
        if ($User -and $User -ne 'SYSTEM' -and $User -ne '-') { $body += "`nUser: $User" }
        if ($Ip -and $Ip -ne '-' -and $Ip -ne '127.0.0.1' -and $Ip -ne '::1') { $body += "`nFrom IP: $Ip" }
        $priority = 'urgent'; $tags = 'rotating_light'
    }
    'Unlock' {
        if (-not $config.notifyUnlock) { exit }
        # System logons that show up as interactive.
        if ($Domain -in 'Window Manager', 'Font Driver Host') { exit }
        if ($User -like 'DWM-*' -or $User -like 'UMFD-*') { exit }
        if (Test-RecentlySent 'unlock' 20) { exit }
        $title = "$computer unlocked"
        $body = "$time`nUser: $User`nHow: $how"
        $priority = 'low'; $tags = 'unlock'
    }
    'Wake' {
        if (-not $config.notifyWake) { exit }
        if (Test-RecentlySent 'wake' 60) { exit }
        $title = "$computer woke up"
        $body = "$time`nLid opened or key/mouse pressed."
        $priority = 'low'; $tags = 'eyes'
    }
    'Boot' {
        if ($config.notifyBoot -eq $false) { exit }
        $title = "$computer was switched on"
        $body = "$time`nPowered on at $Status (full start, not just wake)."
        $priority = 'high'; $tags = 'zap'
    }
    'Test' {
        $title = "Unlock Alert is set up on $computer"
        $body = "$time`nYou'll get a notification here for failed sign-ins, unlocks and wakes."
        $priority = 'default'; $tags = 'white_check_mark'
    }
}

Write-Log ("{0}: {1}" -f $Kind, ($body -replace "`n", ' | '))

$url = "{0}/{1}" -f $config.ntfyServer.TrimEnd('/'), $config.ntfyTopic
$headers = @{ Title = $title; Priority = $priority; Tags = $tags }

# Right after boot/wake Wi-Fi may not be connected yet, so retry for ~3 minutes.
# Send with Windows' built-in curl.exe, not Invoke-RestMethod: on some networks
# (broken IPv6) PowerShell 5.1's web client hangs until timeout, while curl
# falls back to IPv4 instantly. Body goes via a file so quotes/newlines survive.
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$bodyFile = Join-Path $dir ("body-{0}.txt" -f [guid]::NewGuid())
[System.IO.File]::WriteAllText($bodyFile, $body)  # UTF-8 without BOM
$curlArgs = @('-sS', '-f', '--max-time', '15', '-o', 'NUL', '--data-binary', "@$bodyFile")
foreach ($h in $headers.Keys) { $curlArgs += @('-H', "${h}: $($headers[$h])") }
$curlArgs += $url

$deadline = (Get-Date).AddMinutes(3)
try {
    while ($true) {
        $err = & $curl @curlArgs 2>&1
        if ($LASTEXITCODE -eq 0) { exit }
        if ((Get-Date) -gt $deadline) { Write-Log "  send failed: curl exit $LASTEXITCODE $err"; exit 1 }
        Start-Sleep -Seconds 5
    }
} finally {
    Remove-Item $bodyFile -ErrorAction SilentlyContinue
}
