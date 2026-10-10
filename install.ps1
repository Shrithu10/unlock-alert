#Requires -RunAsAdministrator
# Installs Unlock Alert: copies scripts to ProgramData, enables logon auditing,
# and registers one always-running SYSTEM watcher (watcher.ps1).

$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = Join-Path $env:ProgramData 'UnlockAlert'

# Remove the old one-task-per-event setup, and stop a running watcher before upgrading it.
foreach ($old in 'Failed', 'FailedPin', 'Unlock', 'Wake', 'Watcher') {
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
if (-not $config.ntfyTopic) {
    # Anyone who knows an ntfy topic can read it, so make it unguessable.
    $config.ntfyTopic = 'unlock-alert-' + (-join ((48..57) + (97..122) | Get-Random -Count 20 | ForEach-Object { [char]$_ }))
    $config | ConvertTo-Json | Set-Content $configPath
}

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
Write-Host "Config: $configPath   Log: $dest\alerts.log"
