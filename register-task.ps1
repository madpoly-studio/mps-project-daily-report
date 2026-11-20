# Đăng ký Task Scheduler: chạy daily-report.ps1 -Project <KEY> lúc 7:30, thứ 2 – thứ 6. Mỗi project một task riêng.
# Chạy dưới user hiện tại, chỉ khi đã đăng nhập (cần nếu dùng token của glab auth login trong Windows Credential Manager;
# với GITLAB_TOKEN trong .env thì không bắt buộc).
# Nếu máy tắt/ngủ đúng giờ, task chạy bù ngay khi máy bật lại (StartWhenAvailable).
# Đăng ký: .\register-task.ps1 -Project DG   (task tên mặc định 'DG Daily Report')
# Gỡ: Unregister-ScheduledTask -TaskName '<KEY> Daily Report' -Confirm:$false   (vd 'DG Daily Report')

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$Project,
    [string]$At = '7:30AM',
    [string]$TaskName = "$Project Daily Report"
)

$ErrorActionPreference = 'Stop'
# Chuẩn hoá mã project giống daily-report.ps1 (-Project dg → task 'DG Daily Report').
$Project = $Project.ToUpperInvariant()
if (-not $PSBoundParameters.ContainsKey('TaskName')) { $TaskName = "$Project Daily Report" }
$script = Join-Path $PSScriptRoot 'daily-report.ps1'
$projectEnvPath = Join-Path (Join-Path $PSScriptRoot 'projects') "$Project.env"
if (-not (Test-Path -LiteralPath $projectEnvPath)) {
    throw "Không thấy file cấu hình của project '$Project': $projectEnvPath. Tạo file này trước (copy từ projects\example.env.sample)."
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Project $Project" `
    -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At $At
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description "Daily report Jira $Project + GitLab MR merged -> Teams" -Force | Out-Null

Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo |
    Select-Object TaskName, NextRunTime, LastRunTime, LastTaskResult | Format-List
