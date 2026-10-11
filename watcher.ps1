# Long-running SYSTEM process: listens to the event logs directly and hands each
# hit to alert.ps1. Replaces one-task-per-event triggers, which Windows stops
# starting once Energy Saver kicks in; an already-running process keeps going.
param([switch]$SelfTest)  # also watch PowerShell's own log, to test without admin

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$alert = Join-Path $dir 'alert.ps1'
$logFile = Join-Path $dir 'alerts.log'
$heartbeat = Join-Path $dir 'watcher-heartbeat.txt'

function Write-Log($msg) {
    Add-Content -Path $logFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
}

# One watcher at a time (the keep-alive trigger fires every 5 minutes).
$single = New-Object System.Threading.Mutex($false, 'Global\UnlockAlert-Watcher')
try { if (-not $single.WaitOne(0)) { exit } } catch [System.Threading.AbandonedMutexException] {}

$recentSends = New-Object System.Collections.Generic.Queue[datetime]
function Send-Alert([string]$kind, [hashtable]$values = @{}) {
    # Storm guard: never more than 15 alerts a minute, whatever the event logs do.
    while ($recentSends.Count -and ((Get-Date) - $recentSends.Peek()).TotalSeconds -gt 60) { [void]$recentSends.Dequeue() }
    if ($recentSends.Count -ge 15) {
        if ($recentSends.Count -eq 15) { Write-Log "watcher: over 15 alerts in a minute, holding off"; $recentSends.Enqueue((Get-Date)) }
        return
    }
    $recentSends.Enqueue((Get-Date))
    $argList = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$alert`" -Kind $kind"
    foreach ($k in $values.Keys) {
        $v = "$($values[$k])" -replace '"', ''
        $argList += " -$k `"$v`""
    }
    # Separate process so a slow send (Wi-Fi not up yet) never blocks the watcher.
    Start-Process powershell.exe -ArgumentList $argList -WindowStyle Hidden
}

function Get-EventData($record) {
    $data = @{}
    foreach ($d in ([xml]$record.ToXml()).Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
    $data
}

$queries = [ordered]@{
    'Security' = "*[System[(EventID=4624 or EventID=4625)] and EventData[Data[@Name='LogonType']='2' or Data[@Name='LogonType']='3' or Data[@Name='LogonType']='7' or Data[@Name='LogonType']='10' or Data[@Name='LogonType']='11']]"
    # A wrong Windows Hello PIN never reaches the Security log; it shows up here.
    'Microsoft-Windows-HelloForBusiness/Operational' = '*[System[EventID=7001]]'
    # Power-Troubleshooter 1 = resume from sleep; Kernel-Power 507 = exit Modern Standby.
    'System' = "*[System[(Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1) or (Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=507)]]"
}
if ($SelfTest) { $queries['Windows PowerShell'] = '*[System[EventID=400]]' }

$watchers = @{}
$watchFailed = @{}
function Start-Watchers {
    foreach ($logName in $queries.Keys) {
        if ($watchers[$logName] -and $watchers[$logName].Enabled) { continue }
        try {
            $query = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery($logName, [System.Diagnostics.Eventing.Reader.PathType]::LogName, $queries[$logName])
            $w = New-Object System.Diagnostics.Eventing.Reader.EventLogWatcher($query)
            Unregister-Event -SourceIdentifier "UA:$logName" -ErrorAction SilentlyContinue
            Register-ObjectEvent -InputObject $w -EventName EventRecordWritten -SourceIdentifier "UA:$logName" | Out-Null
            $w.Enabled = $true
            $watchers[$logName] = $w
        } catch {
            if (-not $watchFailed[$logName]) { Write-Log "watcher: cannot watch ${logName}: $($_.Exception.Message)" }
            $watchFailed[$logName] = $true
        }
    }
}

function Invoke-Record($record) {
    switch ($record.LogName) {
        'Security' {
            $d = Get-EventData $record
            if ($record.Id -eq 4625) {
                Send-Alert 'Failed' @{ User = $d.TargetUserName; LogonType = $d.LogonType; Status = $d.Status; SubStatus = $d.SubStatus; Ip = $d.IpAddress }
            } elseif ($d.LogonType -in '2', '7', '11') {
                Send-Alert 'Unlock' @{ User = $d.TargetUserName; Domain = $d.TargetDomainName; LogonType = $d.LogonType }
            }
        }
        'Microsoft-Windows-HelloForBusiness/Operational' {
            $d = Get-EventData $record
            Send-Alert 'Failed' @{ LogonType = 'PIN'; Status = $d.AuthenticationErrorStatus; SubStatus = $d.AuthenticationErrorSubStatus }
        }
        'System' { Send-Alert 'Wake' }
        # alert.ps1 itself starts PowerShell (another event 400), so fire once only.
        'Windows PowerShell' { if (-not $script:selfTestSent) { $script:selfTestSent = $true; Send-Alert 'Test' } }
    }
}

Write-Log "watcher: started (pid $PID)"
Start-Watchers

# "Switched on" alert: the watcher starts at boot, so a boot event in the last
# 15 minutes that we haven't reported yet means someone just powered it on.
try {
    $boot = Get-WinEvent -LogName System -MaxEvents 1 -FilterXPath "*[System[(Provider[@Name='Microsoft-Windows-Kernel-General'] and EventID=12) or (Provider[@Name='Microsoft-Windows-Kernel-Boot'] and EventID=27)]]"
    $seen = Join-Path $dir 'last-boot.txt'
    if ($boot -and ((Get-Date) - $boot.TimeCreated).TotalMinutes -lt 15 -and (Get-Content $seen -ErrorAction SilentlyContinue) -ne "$($boot.TimeCreated.ToString('o'))") {
        Set-Content $seen $boot.TimeCreated.ToString('o')
        Send-Alert 'Boot' @{ Status = $boot.TimeCreated.ToString('HH:mm:ss') }
    }
} catch {
    Write-Log "watcher: boot check failed: $($_.Exception.Message)"
}

# --- Commands from the phone -------------------------------------------------
# The notification buttons post "lock" or "status" to a second private topic.
# We poll it every ~10 s with curl. Only these two harmless commands exist.
$config = Get-Content (Join-Path $dir 'config.json') -Raw | ConvertFrom-Json
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$cmdSince = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()  # ignore anything sent before we started

function Get-LaptopState {
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    if (-not $user) { return @{ State = 'at the sign-in screen'; Detail = 'Nobody is signed in.' } }
    # LogonUI is what draws the lock screen, so if it's running the screen is locked.
    if (Get-Process LogonUI -ErrorAction SilentlyContinue) {
        return @{ State = 'LOCKED'; Detail = "$user is signed in, lock screen showing." }
    }
    @{ State = 'UNLOCKED'; Detail = "In use by $user right now." }
}

function Invoke-PhoneCommands {
    if (-not $config.ntfyCommandTopic) { return }
    $url = "{0}/{1}/json?poll=1&since={2}" -f $config.ntfyServer.TrimEnd('/'), $config.ntfyCommandTopic, $script:cmdSince
    $lines = & $curl -sS --max-time 10 $url 2>$null
    if ($LASTEXITCODE -ne 0) { return }  # offline; try again next round
    foreach ($line in @($lines)) {
        if (-not $line) { continue }
        $msg = $line | ConvertFrom-Json
        if ($msg.event -ne 'message') { continue }
        $script:cmdSince = $msg.id
        $command = "$($msg.message)".Trim().ToLower()
        Write-Log "watcher: phone command '$command'"
        switch ($command) {
            'status' {
                $s = Get-LaptopState
                Send-Alert 'Status' @{ Status = $s.State; SubStatus = $s.Detail }
            }
            'lock' {
                $s = Get-LaptopState
                if ($s.State -ne 'UNLOCKED') {
                    Send-Alert 'Status' @{ Status = $s.State; SubStatus = "Already locked. $($s.Detail)" }
                    continue
                }
                # Locking has to happen inside the user's session, so it's a task that runs as them.
                try { Start-ScheduledTask -TaskPath '\UnlockAlert\' -TaskName 'Lock' } catch { Write-Log "watcher: lock task: $($_.Exception.Message)" }
                Start-Sleep -Seconds 3
                $s = Get-LaptopState
                $detail = if ($s.State -eq 'UNLOCKED') { 'Lock was sent but it still looks unlocked.' } else { 'Locked from your phone.' }
                Send-Alert 'Status' @{ Status = $s.State; SubStatus = $detail }
            }
            default { Write-Log "watcher: ignored unknown command '$command'" }
        }
    }
}

while ($true) {
    $ev = Wait-Event -Timeout 10
    if ($ev) {
        try {
            if ($ev.SourceEventArgs.EventException) { throw $ev.SourceEventArgs.EventException }
            if ($ev.SourceEventArgs.EventRecord) { Invoke-Record $ev.SourceEventArgs.EventRecord }
        } catch {
            Write-Log "watcher: $($_.Exception.Message)"
        }
        Remove-Event -EventIdentifier $ev.EventIdentifier
    }
    try { Invoke-PhoneCommands } catch { Write-Log "watcher: commands: $($_.Exception.Message)" }
    Set-Content -Path $heartbeat -Value (Get-Date -Format o)
    Start-Watchers  # re-arm anything that got disabled
}
