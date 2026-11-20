# dev-site-crawler / uninstall-task.ps1
# 卸载 Windows 任务计划：DevSiteCrawler-Daily
# PowerShell 5 兼容

param(
    [string]$TaskName = "DevSiteCrawler-Daily"
)

Write-Output "Removing task '$TaskName'..."
schtasks /delete /tn $TaskName /f

if ($LASTEXITCODE -eq 0) {
    Write-Output "OK. Task removed."
} else {
    Write-Error "Failed to remove task (exit code $LASTEXITCODE). Task may not exist."
}
