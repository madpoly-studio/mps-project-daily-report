# Đăng ký Task Scheduler: chạy daily-report.ps1 lúc 7:30, thứ 2 – thứ 6.
# Chạy dưới user hiện tại, chỉ khi đã đăng nhập (cần nếu dùng token của glab auth login trong Windows Credential Manager;
# với GITLAB_TOKEN trong .env thì không bắt buộc).
# Nếu máy tắt/ngủ đúng giờ, task chạy bù ngay khi máy bật lại (StartWhenAvailable).
# Gỡ: Unregister-ScheduledTask -TaskName 'RDG Daily Report' -Confirm:$false

param(
    [string]$At = '7:30AM',
    [string]$TaskName = 'RDG Daily Report'
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'daily-report.ps1'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`"" `
    -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At $At
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description 'Daily report Jira RDG + GitLab MR merged -> Teams' -Force | Out-Null

Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo |
    Select-Object TaskName, NextRunTime, LastRunTime, LastTaskResult | Format-List
