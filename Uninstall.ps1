#Requires -Version 5.1
<#
.SYNOPSIS
    Remove the WSUS OS description monitor scheduled task.
.DESCRIPTION
    Locates the single Update-WSUSComputerOperatingSystems scheduled task,
    verifies that it belongs to this project, and removes it after confirmation.
    The installed scripts, log files and Task Scheduler folder are preserved.
.EXAMPLE
    .\Uninstall.ps1
.NOTES
    Run from elevated Windows PowerShell 5.1 on the WSUS server.
    No command-line parameters are required or accepted.
#>

$ErrorActionPreference = 'Stop'
$TaskName = 'Update-WSUSComputerOperatingSystems'

function Test-OurScheduledTask {
    param($Task)
    if ($null -eq $Task) { return $false }
    $actions = @($Task.Actions)
    return ($actions.Count -eq 1 -and
        $actions[0].Execute -match '(?i)(^|[\\/])powershell\.exe$' -and
        ($actions[0].Arguments -match '(?i)Update-WSUSComputerOperatingSystems(-Event)?\.ps1'))
}

function Read-YesNo {
    param([string]$Question)
    while ($true) {
        $answer = (Read-Host "$Question [y/N]").Trim()
        if (-not $answer -or $answer -match '^(?i:n|no)$') { return $false }
        if ($answer -match '^(?i:y|yes)$') { return $true }
        Write-Warning 'Please enter Y or N.'
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run Uninstall.ps1 from an elevated Windows PowerShell 5.1 session.'
}

$tasks = @(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
if ($tasks.Count -eq 0) {
    Write-Host "Task '$TaskName' not found. Nothing to uninstall."
    return
}
if ($tasks.Count -ne 1) {
    $names = ($tasks | ForEach-Object { $_.TaskPath + $_.TaskName }) -join ', '
    throw "Multiple tasks named '$TaskName' found: $names. Review them manually in Task Scheduler; nothing was removed."
}

$task = $tasks[0]
if (-not (Test-OurScheduledTask $task)) {
    throw "Task $($task.TaskPath)$($task.TaskName) does not match this project's PowerShell action. Nothing was removed."
}

$taskPath = [string]$task.TaskPath
Write-Host "Scheduled task: $taskPath$TaskName" -ForegroundColor Cyan
Write-Host "Current state: $($task.State)"
Write-Host 'Only the scheduled task will be removed. Scripts, logs and the task folder will remain.'
if (-not (Read-YesNo 'Remove this scheduled task?')) {
    Write-Host 'Cancelled. Nothing was removed.'
    return
}

if ($task.State -eq 'Running') {
    Write-Host 'Stopping the running monitor task...'
    Stop-ScheduledTask -TaskPath $taskPath -TaskName $TaskName -ErrorAction Stop
    $until = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $state = (Get-ScheduledTask -TaskPath $taskPath -TaskName $TaskName -ErrorAction Stop).State
    } while ($state -eq 'Running' -and (Get-Date) -lt $until)
    if ($state -eq 'Running') {
        throw 'The task did not stop within 30 seconds. Uninstallation cancelled; the task was not deleted.'
    }
}

Unregister-ScheduledTask -TaskPath $taskPath -TaskName $TaskName -Confirm:$false -ErrorAction Stop
Write-Host "Removed scheduled task: $taskPath$TaskName" -ForegroundColor Green
Write-Host 'Installed scripts and log files were not deleted. Run Update.ps1 to install the task again.'
