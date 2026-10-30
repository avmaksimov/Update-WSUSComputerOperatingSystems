#Requires -Version 5.1
<#
.SYNOPSIS
    Install or update the WSUS OS description monitor without script parameters.
.DESCRIPTION
    Downloads the fixed repository ZIP, compares SHA-256 hashes, stages .new
    files and replaces only changed files. Dot-prefixed files and directories
    are excluded. Existing WSUS scheduled-task settings and installation path
    are reused automatically. Interactive configuration is performed only
    when no project task exists.
.EXAMPLE
    .\Update.ps1
.NOTES
    Requires elevated Windows PowerShell 5.1 on the WSUS server.
    To change an existing task's SQL settings, log directory or task folder,
    edit or move it in Windows Task Scheduler; routine updates preserve it.
#>

$ErrorActionPreference = 'Stop'
$owner = 'avmaksimov'
$repository = 'Update-WSUSComputerOperatingSystems'
$branch = 'main'
$MainScriptName = 'Update-WSUSComputerOperatingSystems.ps1'
$TaskName = 'Update-WSUSComputerOperatingSystems'
$RepositoryZipUrl = "https://github.com/$owner/$repository/archive/refs/heads/$branch.zip"
$DefaultSqlServer = '\\.\pipe\MICROSOFT##WID\tsql\query'

function Read-YesNo {
    param([string]$Question, [bool]$DefaultYes = $false)
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "$Question $suffix").Trim()
        if (-not $answer) { return $DefaultYes }
        if ($answer -match '^(?i:y|yes)$') { return $true }
        if ($answer -match '^(?i:n|no)$') { return $false }
        Write-Warning 'Please enter Y or N.'
    }
}

function Get-FullInstallPath {
    param([string]$Path)
    $Path = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An installation directory is required.' }
    return [IO.Path]::GetFullPath($Path)
}

function Test-TemporaryDirectory {
    param([string]$Path)
    $full = (Get-FullInstallPath $Path) -replace '[\\/]+$', ''
    foreach ($temp in @($env:TEMP, $env:TMP, (Join-Path $env:SystemRoot 'Temp'))) {
        if ([string]::IsNullOrWhiteSpace($temp)) { continue }
        $tempFull = (Get-FullInstallPath $temp) -replace '[\\/]+$', ''
        if ($full.Equals($tempFull, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($tempFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    # Also catch conventional custom temporary directories (e.g. C:\Temp, D:\Work\tmp).
    return ($full -match '(?i)[\\/](temp|tmp)([\\/]|$)')
}

function Normalize-TaskPath {
    param([string]$Folder)
    $Folder = $Folder.Trim().Replace('/', '\')
    if ($Folder -match '[<>:"|?*]') { throw 'Invalid Task Scheduler folder.' }
    if ($Folder -eq '' -or $Folder -eq '\') { return '\' }
    $parts = @($Folder.Trim('\') -split '\\' | Where-Object { $_ -ne '' })
    if ($parts.Count -eq 0) { return '\' }
    return '\' + ($parts -join '\') + '\'
}

function Ensure-TaskFolder {
    param([string]$Path)
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $folder = $service.GetFolder('\')
    foreach ($part in ($Path.Trim('\') -split '\\')) {
        if (-not $part) { continue }
        try { $folder = $folder.GetFolder($part) }
        catch { $folder = $folder.CreateFolder($part) }
    }
}

function Test-ScriptSyntax {
    param([string]$Path)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "Script parse error: $($parseErrors[0].Message)" }
    $parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    if ($parameters -notcontains 'AsService') {
        throw 'The selected main script does not support -AsService; refusing to schedule it.'
    }
    if ($parameters -notcontains 'LogDirectory') {
        throw 'The selected main script does not support -LogDirectory; refusing to schedule it.'
    }
}

function Test-OurScheduledTask {
    param($Task)
    if ($null -eq $Task) { return $false }
    $actions = @($Task.Actions)
    return ($actions.Count -eq 1 -and
        $actions[0].Execute -match '(?i)(^|[\\/])powershell\.exe$' -and
        ($actions[0].Arguments -match '(?i)Update-WSUSComputerOperatingSystems(-Event)?\.ps1'))
}

function Resolve-LogDirectory {
    param([string]$RequestedPath, [string]$DefaultDirectory)
    if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        Write-Host "Empty log directory: using script directory ($DefaultDirectory)."
        return $DefaultDirectory
    }
    $path = [Environment]::ExpandEnvironmentVariables($RequestedPath.Trim().Trim('"'))
    if (-not [IO.Path]::IsPathRooted($path)) {
        throw 'Log directory must be an absolute path (local drive or UNC share).'
    }
    if ($path -match '["`\r\n]') { throw 'Invalid log directory path.' }
    $path = [IO.Path]::GetFullPath($path)
    if ($path -match '^[A-Za-z]:\\') {
        $drive = Get-PSDrive -PSProvider FileSystem -Name $path.Substring(0, 1) -ErrorAction SilentlyContinue
        if ($drive -and $drive.DisplayRoot -match '^\\\\') {
            throw 'Mapped drives are unavailable to the SYSTEM task. Use a UNC path instead.'
        }
    }
    return $path
}

function Get-TaskMainScriptPath {
    param($Task)
    $args = [string](@($Task.Actions)[0].Arguments)
    $match = [regex]::Match($args, '(?i)(?:^|\s)-File\s+"([^"]+)"')
    if (-not $match.Success) {
        throw "The existing task's -File argument is not a quoted path. Review it manually in Task Scheduler."
    }
    $path = [Environment]::ExpandEnvironmentVariables($match.Groups[1].Value)
    if (-not [IO.Path]::IsPathRooted($path) -or $path -match '^[\\]{2}') {
        throw "The task's main script path must be a local absolute path: $path"
    }
    $path = [IO.Path]::GetFullPath($path)
    if (-not [IO.Path]::GetFileName($path).Equals($MainScriptName, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unexpected main script name in Task Scheduler: $path"
    }
    return $path
}

function Get-TaskLogDirectory {
    param($Task,[string]$DefaultDirectory)
    $args = [string](@($Task.Actions)[0].Arguments)
    $match = [regex]::Match($args, '(?i)(?:^|\s)-LogDirectory\s+"([^"]*)"')
    if ($match.Success) {
        return Resolve-LogDirectory -RequestedPath $match.Groups[1].Value -DefaultDirectory $DefaultDirectory
    }
    # A legacy task with no parameter logs locally. Never change it silently.
    if ($args -match '(?i)(?:^|\s)-LogDirectory(?:\s|$)') {
        throw 'The existing task contains an unreadable -LogDirectory option; inspect it in Task Scheduler.'
    }
    return $DefaultDirectory
}

# Only an administrator can modify SYSTEM tasks and machine-wide scripts.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run Update.ps1 from an elevated Windows PowerShell 5.1 session.'
}

# Locate the existing project task in any Scheduler folder; an update uses its
# current -File location even if Update.ps1 was downloaded into %TEMP%.
$allTasks = @(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
$projectTasks = @($allTasks | Where-Object { Test-OurScheduledTask $_ })
if ($projectTasks.Count -gt 1) {
    $list = ($projectTasks | ForEach-Object { $_.TaskPath + $_.TaskName }) -join ', '
    throw "Multiple project tasks found: $list. Resolve the ambiguity in Task Scheduler before updating."
}
if ($projectTasks.Count -eq 0 -and $allTasks.Count -gt 0) {
    $list = ($allTasks | ForEach-Object { $_.TaskPath + $_.TaskName }) -join ', '
    throw "Unrelated task(s) already use the name '$TaskName': $list. Nothing was modified."
}

$existing = if ($projectTasks.Count -eq 1) { $projectTasks[0] } else { $null }
$firstInstall = ($null -eq $existing)
if ($firstInstall) {
    Write-Host 'No existing WSUS OS monitor task found. First-time setup:' -ForegroundColor Cyan
    $defaultDirectory = (Get-Location).ProviderPath
    if (Test-TemporaryDirectory $defaultDirectory) {
        # Do not propose a TEMP directory as a permanent installation location.
        $defaultDirectory = $null
    }
    while ($true) {
        $answer = if ($defaultDirectory) {
            Read-Host "Installation directory [$defaultDirectory]"
        } else { Read-Host 'Permanent installation directory (required)' }
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $defaultDirectory }
        if ([string]::IsNullOrWhiteSpace($answer)) { continue }
        try { $directory = Get-FullInstallPath $answer } catch { Write-Warning $_.Exception.Message; continue }
        if (Test-TemporaryDirectory $directory) { Write-Warning 'Temporary folders are not supported.'; continue }
        if (-not [IO.Path]::IsPathRooted($directory) -or $directory -match '^\\') {
            Write-Warning 'The installation directory must be a local absolute path.'; continue
        }
        break
    }
    while ($true) {
        $folder = Read-Host 'Task Scheduler folder [\] (example: \MP\)'
        try { $TaskPath = Normalize-TaskPath $folder; break }
        catch { Write-Warning $_.Exception.Message }
    }
    $logAnswer = Read-Host "Log directory [$directory] (UNC supported)"
    $LogDirectory = Resolve-LogDirectory -RequestedPath $logAnswer -DefaultDirectory $directory
    $sqlAnswer = Read-Host "SQL Server instance [$DefaultSqlServer]"
    $SQLServerInstance = if ([string]::IsNullOrWhiteSpace($sqlAnswer)) { $DefaultSqlServer } else { $sqlAnswer.Trim() }
    if ($SQLServerInstance -match '["\r\n]') { throw 'Invalid SQL instance name.' }
    $Encrypt = 'Optional'
    $destination = Join-Path $directory $MainScriptName
} else {
    $TaskPath = Normalize-TaskPath $existing.TaskPath
    $destination = Get-TaskMainScriptPath $existing
    $directory = Split-Path -Parent $destination
    if (Test-TemporaryDirectory $directory) { throw "Existing task points into a temporary folder: $directory" }
    $LogDirectory = Get-TaskLogDirectory -Task $existing -DefaultDirectory $directory
    Write-Host "Existing task: $TaskPath$TaskName" -ForegroundColor Cyan
    Write-Host "Installed directory: $directory"
    Write-Host "Log directory: $LogDirectory"
    Write-Host 'Task configuration will be preserved; no setup questions are needed.'
}
if ($LogDirectory.StartsWith('\\')) {
    Write-Host 'Network log: SYSTEM requires share and NTFS write permissions for the server computer account.'
}

$work = Join-Path $env:TEMP ('WSUS-OS-Update-' + [guid]::NewGuid().ToString('N'))
$zip = Join-Path $work 'source.zip'
$extract = Join-Path $work 'unpacked'
$stagedFiles = New-Object 'System.Collections.Generic.List[string]'
$replacedCount = 0
$taskRegistered = $false
$wasRunning = $false
$stoppedForUpdate = $false

try {
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $changes = New-Object 'System.Collections.Generic.List[object]'
    New-Item -ItemType Directory -Path $work -Force -ErrorAction Stop | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $downloadUrl = $RepositoryZipUrl + '?cacheBust=' + [guid]::NewGuid().ToString('N')
    $headers = @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }
    Write-Host "Source: $RepositoryZipUrl"
    Write-Host "Downloading repository ZIP with Invoke-WebRequest..."
    Invoke-WebRequest -Uri $downloadUrl -Headers $headers -OutFile $zip -UseBasicParsing -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw 'Downloaded ZIP not found.' }
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force -ErrorAction Stop
    $roots = @(Get-ChildItem -LiteralPath $extract -Directory -ErrorAction Stop)
    if ($roots.Count -ne 1) { throw 'Unexpected repository ZIP structure: expected exactly one root directory.' }
    $sourceRoot = $roots[0].FullName.TrimEnd('\')

    # ZIP is unpacked into TEMP. Dot-prefixed entries may exist there, but
    # are never copied into the permanent installation directory.
    $sourceFiles = @(
        Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force -ErrorAction Stop |
            Where-Object {
                $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart('\')
                $relative -notmatch '(?:^|[\\/])\.'
            } |
            Sort-Object { $_.FullName.Substring($sourceRoot.Length).TrimStart('\') }
    )
    if ($sourceFiles.Count -eq 0) { throw 'No installable files found in repository ZIP.' }
    $sources = @($sourceFiles | ForEach-Object {
        if (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Unsupported reparse point in ZIP: $($_.FullName)"
        }
        $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart('\')
        [pscustomobject]@{ Name = $relative; Source = $_.FullName }
    })
    if (@($sources | Where-Object { $_.Name -ieq $MainScriptName }).Count -ne 1) {
        throw "Main script $MainScriptName not found at repository root."
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($source in $sources) {
        if (-not $seen.Add($source.Name)) { throw "Duplicate file path in repository: $($source.Name)" }
        $to = Join-Path $directory $source.Name
        if (Test-Path -LiteralPath $to -PathType Container) { throw "Destination is a directory: $to" }
        $newHash = (Get-FileHash -LiteralPath $source.Source -Algorithm SHA256 -ErrorAction Stop).Hash
        $state = if (-not (Test-Path -LiteralPath $to -PathType Leaf)) {
            'INSTALL'
        } elseif ((Get-FileHash -LiteralPath $to -Algorithm SHA256 -ErrorAction Stop).Hash -ine $newHash) {
            'REPLACE'
        } else {
            'UNCHANGED'
        }
        $entry = [pscustomobject]@{
            Name=$source.Name; Source=$source.Source; Target=$to; Hash=$newHash; State=$state
        }
        [void]$entries.Add($entry)
        if ($state -ne 'UNCHANGED') { [void]$changes.Add($entry) }
    }
    $main = @($entries | Where-Object { $_.Name -ieq $MainScriptName })[0]
    Test-ScriptSyntax $main.Source
    if ($main.State -eq 'UNCHANGED') { Test-ScriptSyntax $destination }

    # The updater must exist in the chosen repository version. This protects
    # against unintentionally running against a pre-rename or wrong ZIP.
    if (@($entries | Where-Object { $_.Name -ieq 'Update.ps1' }).Count -ne 1) {
        throw 'Repository ZIP does not contain Update.ps1. Publish the rename to main before running this updater.'
    }
    $changedMain = @($changes | Where-Object { $_.Name -ieq $MainScriptName }).Count -gt 0

    $installCount = @($changes | Where-Object { $_.State -eq 'INSTALL' }).Count
    $replaceCount = @($changes | Where-Object { $_.State -eq 'REPLACE' }).Count
    $sameCount = @($entries | Where-Object { $_.State -eq 'UNCHANGED' }).Count
    Write-Host ''
    Write-Host '=== INSTALL / UPDATE SUMMARY ===' -ForegroundColor Cyan
    Write-Host "Source: $RepositoryZipUrl"
    Write-Host "Destination: $directory"
    Write-Host "Task: $TaskPath$TaskName $(if ($firstInstall) { '(new)' } else { '(existing; settings retained)' })"
    Write-Host "Logs: $LogDirectory"
    Write-Host ('Changes: {0} install, {1} replace, {2} unchanged.' -f $installCount, $replaceCount, $sameCount)
    foreach ($item in $entries) {
        $color = switch ($item.State) { 'INSTALL' { 'Green' }; 'REPLACE' { 'Yellow' }; default { 'DarkGray' } }
        Write-Host ('  {0,-10} {1}' -f $item.State, $item.Name) -ForegroundColor $color
    }
    Write-Host 'Dot-prefixed paths are excluded; unrelated local files are retained.'
    Write-Host 'Files are staged as .new before replacement. No backups or log files from updater.'

    if ($changes.Count -eq 0 -and -not $firstInstall) {
        Write-Host 'Everything is up to date. Existing task was left unchanged.' -ForegroundColor Green
        return
    }
    Write-Host ''
    if (-not (Read-YesNo 'Apply these changes?' -DefaultYes $false)) {
        Write-Host 'Cancelled. No files or scheduled tasks were changed.'
        return
    }

    # Stage ALL changed files alongside their destinations and verify hashes
    # before stopping the running task or replacing a single original.
    foreach ($item in $changes) {
        $parentDir = Split-Path -Path $item.Target -Parent
        if (-not (Test-Path -LiteralPath $parentDir -PathType Container)) {
            New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction Stop | Out-Null
        }
        $newFile = $item.Target + '.new'
        if (Test-Path -LiteralPath $newFile) { throw "Staging file already exists: $newFile" }
        Copy-Item -LiteralPath $item.Source -Destination $newFile -ErrorAction Stop
        [void]$stagedFiles.Add($newFile)
        if ((Get-FileHash -LiteralPath $newFile -Algorithm SHA256 -ErrorAction Stop).Hash -ine $item.Hash) {
            throw "SHA-256 mismatch for staged file: $newFile; installed files were not modified."
        }
    }

    # An existing task is never re-registered or reconfigured on an update.
    # Stop/restart it only if the *running main script* needs replacing.
    $wasRunning = ($null -ne $existing -and $existing.State -eq 'Running')
    if ($wasRunning -and $changedMain) {
        Write-Host 'Stopping the running WSUS OS monitor to update its main script...'
        Stop-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
        $stoppedForUpdate = $true
        $until = (Get-Date).AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 500
            $state = (Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName).State
        } while ($state -eq 'Running' -and (Get-Date) -lt $until)
        if ($state -eq 'Running') { throw 'Existing task did not stop; no installed files were replaced.' }
    }

    # Each replacement is atomic on the same volume. Multi-file updates are
    # not atomic as a group, and cannot be rolled back without backups.
    foreach ($item in $changes) {
        $newFile = $item.Target + '.new'
        if ($item.State -eq 'REPLACE') {
            [System.IO.File]::Replace($newFile, $item.Target, $null)
        } else {
            [System.IO.File]::Move($newFile, $item.Target)
        }
        $replacedCount++
        Write-Host ("{0}: {1}" -f $(if ($item.State -eq 'INSTALL') { 'Installed' } else { 'Replaced' }), $item.Name) -ForegroundColor Green
    }

    if ($firstInstall) {
        Ensure-TaskFolder $TaskPath
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -AsService -SQLServerInstance "{1}" -Encrypt {2} -LogDirectory "{3}"' -f $destination, $SQLServerInstance, $Encrypt, $LogDirectory
        $action = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments -WorkingDirectory $directory
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $trigger.Delay = 'PT1M'
        $runAs = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
            -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $runAs -Settings $settings
        Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -InputObject $task -ErrorAction Stop | Out-Null
        $taskRegistered = $true

        Write-Host "Installed task: $TaskPath$TaskName"
        try {
            Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
            Write-Host 'Task start requested. Check logs and SQL access under SYSTEM.'
        } catch { Write-Warning ('Task installed, but failed to start: ' + $_.Exception.Message) }
    } else {
        Write-Host 'Existing Task Scheduler configuration preserved.'
        if ($stoppedForUpdate) {
            Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
            $stoppedForUpdate = $false
            Write-Host 'Existing monitor task restarted.'
        }
    }
    Write-Host 'Update completed.' -ForegroundColor Green
} catch {
    if ($replacedCount -gt 0) {
        Write-Warning "$replacedCount file(s) were changed before the error; no automatic rollback is available."
    }
    if ($stoppedForUpdate) {
        try {
            Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
            Write-Host 'Previously running task restarted after error.'
        } catch {
            Write-Warning ('Could not restart the previously running task: ' + $_.Exception.Message)
        }
    }
    throw
} finally {
    foreach ($path in $stagedFiles) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
