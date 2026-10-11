#Requires -RunAsAdministrator
# Installs Unlock Alert: copies scripts to ProgramData, enables logon auditing,
# and registers one always-running SYSTEM watcher (watcher.ps1).

$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = Join-Path $env:ProgramData 'UnlockAlert'

# Remove the old one-task-per-event setup, and stop a running watcher before upgrading it.
foreach ($old in 'Failed', 'FailedPin', 'Unlock', 'Wake', 'Watcher', 'Lock') {
    Unregister-ScheduledTask -TaskPath '\UnlockAlert\' -TaskName $old -Confirm:$false -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*UnlockAlert\watcher.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force -Path $dest | Out-Null
foreach ($f in 'alert.ps1', 'watcher.ps1') { Copy-Item (Join-Path $src $f) $dest -Force }

# Keep an existing config (and its topic) on reinstall.
$configPath = Join-Path $dest 'config.json'
if (-not (Test-Path $configPath)) { Copy-Item (Join-Path $src 'config.json') $configPath }
$config = Get-Content $configPath -Raw | ConvertFrom-Json

# Settings added in newer versions get their defaults on upgrade.
$defaults = Get-Content (Join-Path $src 'config.json') -Raw | ConvertFrom-Json
foreach ($p in $defaults.PSObject.Properties) {
    if ($config.PSObject.Properties.Name -notcontains $p.Name) { $config | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
}

# Anyone who knows an ntfy topic can use it, so both topics are random and unguessable:
# one for alerts to the phone, one for commands (lock/status) from the phone.
function New-Topic($prefix) { $prefix + (-join ((48..57) + (97..122) | Get-Random -Count 20 | ForEach-Object { [char]$_ })) }
if (-not $config.ntfyTopic) { $config.ntfyTopic = New-Topic 'unlock-alert-' }
if (-not $config.ntfyCommandTopic) { $config.ntfyCommandTopic = New-Topic 'unlock-cmd-' }
$config | ConvertTo-Json | Set-Content $configPath

# The scripts run as SYSTEM, so ordinary users must not be able to edit them.
icacls $dest /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' 'Users:(OI)(CI)RX' | Out-Null

# Audit "Logon" success + failure (GUID form works on any Windows language).
# Usually already on by default on Windows 11, this just makes sure.
auditpol /set /subcategory:'{0CCE9215-69AE-11D9-BED3-505054503030}' /success:enable /failure:enable | Out-Null

# Watcher task: starts at boot, at any logon, and every 5 minutes as a keep-alive
# (IgnoreNew + the watcher's own mutex mean only one ever runs). No time limit,
# restarts on crash, never stopped for battery.
$arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File &quot;$dest\watcher.ps1&quot;"
$start = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Unlock Alert watcher: push notification on sign-in activity.</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
    <LogonTrigger><Enabled>true</Enabled></LogonTrigger>
    <TimeTrigger>
      <StartBoundary>$start</StartBoundary>
      <Repetition><Interval>PT5M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure>
    <Priority>5</Priority>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>powershell.exe</Command><Arguments>$arguments</Arguments></Exec>
  </Actions>
</Task>
"@
Register-ScheduledTask -TaskPath '\UnlockAlert\' -TaskName 'Watcher' -Xml $xml -Force | Out-Null

# Lock task: no trigger; the watcher starts it when the phone sends "lock".
# Locking only works from inside the user's own session, so it runs as you.
$me = [Security.SecurityElement]::Escape("$env:USERDOMAIN\$env:USERNAME")
$lockXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Unlock Alert: lock this PC on request from your phone.</Description></RegistrationInfo>
  <Principals><Principal id="Author"><UserId>$me</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT1M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>rundll32.exe</Command><Arguments>user32.dll,LockWorkStation</Arguments></Exec>
  </Actions>
</Task>
"@
Register-ScheduledTask -TaskPath '\UnlockAlert\' -TaskName 'Lock' -Xml $lockXml -Force | Out-Null
Write-Host "Remote lock enabled for $env:USERDOMAIN\$env:USERNAME."
Start-ScheduledTask -TaskPath '\UnlockAlert\' -TaskName 'Watcher'
Write-Host 'Watcher installed and started.'

Write-Host 'Sending test notification (in the background)...'
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$dest\alert.ps1`" -Kind Test"

Start-Sleep -Seconds 3
$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*UnlockAlert\watcher.ps1*' }
if ($running) { Write-Host "Watcher is running (pid $($running.ProcessId))." -ForegroundColor Green }
else { Write-Host "Watcher is NOT running - check $dest\alerts.log" -ForegroundColor Red }

Write-Host ''
Write-Host 'On your phone: ntfy app -> + -> subscribe to topic:' -ForegroundColor Green
Write-Host "  $($config.ntfyTopic)"
Write-Host ''
Write-Host 'Every alert has "Lock now" and "Check status" buttons to control the laptop from your phone.'
Write-Host 'To lock it any time (no alert needed), save these links to your phone''s home screen. Keep them private:' -ForegroundColor Green
$cmdBase = "{0}/{1}/publish?message=" -f $config.ntfyServer.TrimEnd('/'), $config.ntfyCommandTopic
Write-Host "  Lock:   ${cmdBase}lock"
Write-Host "  Status: ${cmdBase}status"
Write-Host '(They are also in the test notification on your phone.)'
Write-Host "Config: $configPath   Log: $dest\alerts.log"
