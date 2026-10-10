#Requires -RunAsAdministrator
foreach ($name in 'Watcher', 'Failed', 'FailedPin', 'Unlock', 'Wake') {
    Unregister-ScheduledTask -TaskName $name -TaskPath '\UnlockAlert\' -Confirm:$false -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*UnlockAlert\watcher.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-Item (Join-Path $env:ProgramData 'UnlockAlert') -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Unlock Alert removed. (Logon auditing was left on; it is the Windows default.)'
