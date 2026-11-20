# dev-site-crawler / install-task.ps1
# Register Windows scheduled task: daily 02:00 crawl.ps1
# PowerShell 5 compatible (ASCII-only, no backtick continuations)
#
# Logon type: S4U = "run whether user is logged on or not", no password stored.
# S4U registration needs admin rights, so the script self-elevates via UAC.
#
# Key settings (prevent missed crawls like 2026-11-14/15):
#   StartWhenAvailable       - run ASAP after a missed 02:00 start (machine was off/asleep)
#   WakeToRun                - wake the computer at trigger time
#   AllowStartIfOnBatteries  - start even on battery power (laptop)
#   DontStopIfGoingOnBatteries - do not interrupt when switching to battery

param(
    [string]$TaskName = "DevSiteCrawler-Daily",
    [string]$ExecuteTime = "02:00"
)

# ---------- Self-elevation: S4U registration requires admin ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $logFile = Join-Path $PSScriptRoot "install-task-elevated.log"
    if (Test-Path $logFile) { Remove-Item $logFile -Force }
    Write-Output "Not elevated. Relaunching as Administrator (click Yes on the UAC prompt)..."
    $inner = "& '$PSCommandPath' *>&1 | Out-File -FilePath '$logFile' -Encoding UTF8"
    $argLine = "-NoProfile -ExecutionPolicy Bypass -Command `"$inner`""
    try {
        Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList $argLine
    }
    catch {
        Write-Error "Elevation was declined or failed: $($_.Exception.Message)"
        Write-Error "Run this script from an elevated PowerShell instead."
        exit 1
    }
    if (Test-Path $logFile) {
        Write-Output "----- elevated output -----"
        Get-Content $logFile
        Write-Output "----- end elevated output -----"
    }
    exit 0
}

# ---------- Elevated path: register the task ----------
$crawlScript = Join-Path $PSScriptRoot "crawl.ps1"
if (-not (Test-Path $crawlScript)) {
    Write-Error "crawl.ps1 not found at $crawlScript"
    exit 1
}

# Remove existing task with the same name (ignore if absent)
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Output "Removing existing task '$TaskName'..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$actionArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$crawlScript`""
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $actionArgs
$trigger = New-ScheduledTaskTrigger -Daily -At $ExecuteTime

# Preferred: wake + battery allowed
$settingsFullParams = @{
    StartWhenAvailable         = $true
    WakeToRun                  = $true
    AllowStartIfOnBatteries    = $true
    DontStopIfGoingOnBatteries = $true
    ExecutionTimeLimit         = (New-TimeSpan -Hours 2)
}
$settingsFull = New-ScheduledTaskSettingsSet @settingsFullParams

# Fallback: no wake
$settingsBasicParams = @{
    StartWhenAvailable         = $true
    AllowStartIfOnBatteries    = $true
    DontStopIfGoingOnBatteries = $true
    ExecutionTimeLimit         = (New-TimeSpan -Hours 2)
}
$settingsBasic = New-ScheduledTaskSettingsSet @settingsBasicParams

Write-Output "Registering task '$TaskName' to run daily at $ExecuteTime..."
Write-Output "  Script:  $crawlScript"
Write-Output "  Logon:   S4U (run whether user is logged on or not, no password stored)"
Write-Output "  Options: StartWhenAvailable + WakeToRun + battery allowed"

# S4U principal: runs headless in session 0, no desktop access needed
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited

$registerParams = @{
    TaskName    = $TaskName
    Action      = $action
    Trigger     = $trigger
    Principal   = $principal
    ErrorAction = 'Stop'
}

$registered = $null
try {
    $registerParams.Settings = $settingsFull
    $registered = Register-ScheduledTask @registerParams
}
catch {
    Write-Output "S4U + full settings failed ($($_.Exception.Message)). Retrying without WakeToRun..."
    try {
        $registerParams.Settings = $settingsBasic
        $registered = Register-ScheduledTask @registerParams
    }
    catch {
        Write-Output "S4U failed ($($_.Exception.Message)). Falling back to Interactive logon..."
        $registerParams.Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        $registerParams.Settings = $settingsFull
        try {
            $registered = Register-ScheduledTask @registerParams
        }
        catch {
            Write-Error "Failed to register task: $($_.Exception.Message)"
            exit 1
        }
    }
}

if ($registered) {
    Write-Output ""
    Write-Output "OK. Task registered successfully."
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($info) { Write-Output "Next run: $($info.NextRunTime)" }
    $task = Get-ScheduledTask -TaskName $TaskName
    Write-Output "LogonType: $($task.Principal.LogonType)"
    Write-Output ""
    Write-Output "Verify with:"
    Write-Output "  schtasks /query /tn `"$TaskName`" /v /fo list"
    Write-Output ""
    Write-Output "Run now to test:"
    Write-Output "  schtasks /run /tn `"$TaskName`""
    Write-Output ""
    Write-Output "Uninstall with:"
    Write-Output "  powershell -File `"$PSScriptRoot\uninstall-task.ps1`""
}
