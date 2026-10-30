#Requires -Version 5.1
<#
.SYNOPSIS
    Install, update or uninstall the WSUS OS descriptions event task.
.DESCRIPTION
    Downloads a ZIP of the fork, compares files by SHA-256, and installs or
    updates changed files only. Files or directories starting with a dot are
    ignored. Registers an event-driven SYSTEM task in Task Scheduler.
    Files are staged as .new before replacement; no old-version backups.
.EXAMPLE
    .\Install-WSUSComputerOperatingSystems.ps1
.EXAMPLE
    .\Install-WSUSComputerOperatingSystems.ps1 -InstallPath 'D:\Scripts\WSUS'
.EXAMPLE
    .\Install-WSUSComputerOperatingSystems.ps1 -InstallPath 'D:\Scripts\WSUS' -TaskPath '\MP\'
.EXAMPLE
    .\Install-WSUSComputerOperatingSystems.ps1 -Uninstall
.EXAMPLE
    .\Install-WSUSComputerOperatingSystems.ps1 -Uninstall -TaskPath '\MP\'
.EXAMPLE
    .\Install-WSUSComputerOperatingSystems.ps1 -LogDirectory '\\server\share\_Logs'
.EXAMPLE
    .\Install-WSUSComputerOperatingSystems.ps1 -SkipFileUpdate -LogDirectory 'C:\WSUSLogs'
.NOTES
    New tasks and existing legacy tasks without -LogDirectory prompt for a log
    directory. Existing tasks with -LogDirectory reuse it without prompting.
    Override at any time with -LogDirectory or edit Task Scheduler > Actions.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$InstallPath,
    [Parameter()][string]$TaskPath,
    [Parameter()][string]$LogDirectory,
    [Parameter()][switch]$Uninstall,
    [Parameter()][string]$SQLServerInstance = '\\.\pipe\MICROSOFT##WID\tsql\query',
    [Parameter()][ValidateSet('Optional','Mandatory','True','False')][string]$Encrypt = 'Optional',
    [Parameter()][string]$MainScriptUrl,
    [Parameter()][string]$RepositoryZipUrl = 'https://github.com/avmaksimov/Update-WSUSComputerOperatingSystems/archive/refs/heads/main.zip',
    [Parameter()][switch]$SkipFileUpdate
)

$ErrorActionPreference = 'Stop'
$MainScriptName = 'Update-WSUSComputerOperatingSystems.ps1'
$TaskName = 'Update-WSUSComputerOperatingSystems'
# Default source is the full repository ZIP from the fork's main branch.
# -MainScriptUrl remains supported for legacy single-file overrides.

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

function Get-InstallationDirectory {
    param([string]$ExplicitPath)
    # Resolve the default installation directory from this installer, not the caller's $PWD.
    $installerDirectory = $PSScriptRoot
    $mainNextToInstaller = Join-Path $installerDirectory $MainScriptName
    if (-not $PSBoundParameters.ContainsKey('ExplicitPath')) { $ExplicitPath = '' }
    $needPrompt = [string]::IsNullOrWhiteSpace($ExplicitPath) -and
        (-not (Test-Path -LiteralPath $mainNextToInstaller -PathType Leaf) -or (Test-TemporaryDirectory $installerDirectory))
    if (-not $needPrompt) {
        $chosen = if ($ExplicitPath) { Get-FullInstallPath $ExplicitPath } else { Get-FullInstallPath $installerDirectory }
        if (-not (Test-TemporaryDirectory $chosen)) { return $chosen }
        Write-Warning "Temporary directories cannot be used as permanent install locations: $chosen"
    }
    $default = if (Test-TemporaryDirectory $installerDirectory) { $null } else { $installerDirectory }
    while ($true) {
        if ($default) {
            $answer = Read-Host "Installation directory [$default]"
            if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $default }
        } else {
            $answer = Read-Host 'Installation directory (required; temporary folders are not allowed)'
            if ([string]::IsNullOrWhiteSpace($answer)) {
                Write-Warning 'Please specify a permanent installation directory.'
                continue
            }
        }
        try { $chosen = Get-FullInstallPath $answer }
        catch { Write-Warning $_.Exception.Message; continue }
        if (Test-TemporaryDirectory $chosen) {
            Write-Warning 'That directory is temporary. Please choose another location.'
            continue
        }
        return $chosen
    }
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

function Resolve-TaskPath {
    param(
        [string]$RequestedPath,
        [bool]$TaskPathSpecified,
        [bool]$ForUninstall = $false
    )

    if ($TaskPathSpecified) { return Normalize-TaskPath $RequestedPath }

    # Search all Task Scheduler folders; never select an ambiguous or unrelated task.
    $tasks = @(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    $projectTasks = @($tasks | Where-Object { Test-OurScheduledTask $_ })

    if ($projectTasks.Count -gt 1) {
        $paths = ($projectTasks | ForEach-Object { $_.TaskPath + $_.TaskName }) -join ', '
        throw "Multiple project tasks found: $paths. Specify -TaskPath explicitly."
    }
    if ($projectTasks.Count -eq 1) {
        $foundPath = Normalize-TaskPath $projectTasks[0].TaskPath
        Write-Host "Found existing project task: $foundPath$TaskName"
        return $foundPath
    }
    if ($tasks.Count -gt 0) {
        $paths = ($tasks | ForEach-Object { $_.TaskPath + $_.TaskName }) -join ', '
        throw "Task name '$TaskName' is already used by unrelated task(s): $paths. Specify -TaskPath explicitly."
    }

    if ($ForUninstall) { return $null }
    Write-Host 'No existing project task found. Using Task Scheduler root folder.'
    return '\'
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

function Get-TaskLogDirectory {
    param($Task, [string]$DefaultDirectory)
    $actionArguments = [string](@($Task.Actions)[0].Arguments)
    # Preserve the configured path. For a legacy task with no -LogDirectory,
    # return $null so the installer can ask once during migration.
    $match = [regex]::Match($actionArguments, '(?i)(?:^|\s)-LogDirectory\s+"([^"]*)"')
    if ($match.Success) { return Resolve-LogDirectory -RequestedPath $match.Groups[1].Value -DefaultDirectory $DefaultDirectory }
    if ($actionArguments -match '(?i)(?:^|\s)-LogDirectory(?:\s|$)') {
        throw 'Existing task has an unreadable -LogDirectory argument. Specify -LogDirectory explicitly.'
    }
    return $null
}

# Scheduled-task uninstall does not download files or delete installed files.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run the installer from an elevated Windows PowerShell 5.1 session.'
}
if ($SQLServerInstance -match '["\r\n]' -or $Encrypt -match '["\r\n]') { throw 'Invalid SQL connection parameter.' }

if ($Uninstall) {
    $TaskPath = Resolve-TaskPath -RequestedPath $TaskPath -TaskPathSpecified ($PSBoundParameters.ContainsKey('TaskPath')) -ForUninstall $true
    if ($null -eq $TaskPath) { Write-Host "Task not found: $TaskName"; return }
    $existing = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) { Write-Host "Task not found: $TaskPath$TaskName"; return }
    if (-not (Test-OurScheduledTask $existing)) {
        throw "Task $TaskPath$TaskName does not appear to belong to this project. Refusing to remove it."
    }
    if (Read-YesNo "Remove task $TaskPath$TaskName?" -DefaultYes $false) {
        Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false
        Write-Host 'Task removed. Installed files and logs were left untouched.'
    } else { Write-Host 'Cancelled.' }
    return
}

if ($SkipFileUpdate -and $PSBoundParameters.ContainsKey('MainScriptUrl')) {
    throw '-SkipFileUpdate cannot be combined with -MainScriptUrl.'
}

$directory = Get-InstallationDirectory -ExplicitPath $InstallPath
$destination = Join-Path $directory $MainScriptName
$TaskPath = Resolve-TaskPath -RequestedPath $TaskPath -TaskPathSpecified ($PSBoundParameters.ContainsKey('TaskPath'))
$existing = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing -and -not (Test-OurScheduledTask $existing)) {
    throw "Task $TaskPath$TaskName exists but is not recognized as this project's task."
}

# Preserve existing log configuration; ask only on first install or for a legacy task.
if ($PSBoundParameters.ContainsKey('LogDirectory')) {
    $LogDirectory = Resolve-LogDirectory -RequestedPath $LogDirectory -DefaultDirectory $directory
} elseif ($existing) {
    $configuredLogDirectory = Get-TaskLogDirectory -Task $existing -DefaultDirectory $directory
    if ($null -ne $configuredLogDirectory) {
        $LogDirectory = $configuredLogDirectory
        Write-Host "Reusing log directory from existing task: $LogDirectory"
    } else {
        Write-Host 'Existing task has no -LogDirectory option (legacy installation).'
        $LogDirectory = Resolve-LogDirectory -RequestedPath (Read-Host "Log directory [$directory]") -DefaultDirectory $directory
    }
} else {
    Write-Host 'New installation: choose a log directory (UNC paths are supported).'
    $LogDirectory = Resolve-LogDirectory -RequestedPath (Read-Host "Log directory [$directory]") -DefaultDirectory $directory
}
if ($LogDirectory.StartsWith('\\')) {
    Write-Host 'Network log selected: grant share and NTFS write access to the server computer account (e.g. BS\SERVER1$).'
    Write-Host 'Mapped drive letters (e.g. M:) are not available to the SYSTEM task; use a UNC path.'
}

# Detect multiple same-name tasks in other folders but never change them.
$elsewhere = @(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskPath -ne $TaskPath })
foreach ($item in $elsewhere) {
    Write-Warning "A task with the same name also exists at $($item.TaskPath). It will not be modified."
}

$work = Join-Path $env:TEMP ('WSUS-OS-Install-' + [guid]::NewGuid().ToString('N'))
$zip = Join-Path $work 'source.zip'
$extract = Join-Path $work 'unpacked'
$stagedFiles = New-Object 'System.Collections.Generic.List[string]'
$replacedCount = 0
$taskRegistered = $false
$wasRunning = $false

try {
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $changes = New-Object 'System.Collections.Generic.List[object]'
    New-Item -ItemType Directory -Path $work -Force -ErrorAction Stop | Out-Null

    if ($SkipFileUpdate) {
        Write-Host 'File download and replacement skipped (-SkipFileUpdate).'
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            throw "Main script not found: $destination. Cannot use -SkipFileUpdate."
        }
        Test-ScriptSyntax $destination
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $sources = @()
        if ($PSBoundParameters.ContainsKey('MainScriptUrl')) {
            # Backwards-compatible override: fetch ONLY the main script, not the ZIP.
            if ($MainScriptUrl -notmatch '^https://') { throw '-MainScriptUrl must use HTTPS.' }
            $sourceFile = Join-Path $work $MainScriptName
            Write-Host "Downloading main script: $MainScriptUrl"
            Invoke-WebRequest -Uri $MainScriptUrl -OutFile $sourceFile -UseBasicParsing -ErrorAction Stop
            $sources = @([pscustomobject]@{ Name = $MainScriptName; Source = $sourceFile })
        } else {
            if ($RepositoryZipUrl -notmatch '^https://') { throw '-RepositoryZipUrl must use HTTPS.' }
            $urlSeparator = if ($RepositoryZipUrl.Contains('?')) { '&' } else { '?' }
            $downloadUrl = $RepositoryZipUrl + $urlSeparator + 'cacheBust=' + [guid]::NewGuid().ToString('N')
            $headers = @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }
            Write-Host "Downloading repository ZIP: $RepositoryZipUrl"
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
    }

    # Show every file and a single task+file confirmation, without separate download prompts.
    $installCount = @($changes | Where-Object { $_.State -eq 'INSTALL' }).Count
    $replaceCount = @($changes | Where-Object { $_.State -eq 'REPLACE' }).Count
    $sameCount = @($entries | Where-Object { $_.State -eq 'UNCHANGED' }).Count
    Write-Host ''
    Write-Host '=== INSTALL / UPDATE SUMMARY ===' -ForegroundColor Cyan
    Write-Host "Installation directory: $directory"
    Write-Host "Source: $(if ($SkipFileUpdate) { 'Local files (no download)' } elseif ($PSBoundParameters.ContainsKey('MainScriptUrl')) { $MainScriptUrl } else { $RepositoryZipUrl })"
    Write-Host ("Files: {0} to install, {1} to replace, {2} unchanged (skipped)." -f $installCount, $replaceCount, $sameCount)
    foreach ($entry in $entries) {
        $color = switch ($entry.State) { 'INSTALL' { 'Green' }; 'REPLACE' { 'Yellow' }; default { 'DarkGray' } }
        Write-Host ('  {0,-10} {1}' -f $entry.State, $entry.Name) -ForegroundColor $color
    }
    Write-Host "Task: $TaskPath$TaskName $(if ($existing) { '(update)' } else { '(new)' })"
    Write-Host 'Account: SYSTEM; trigger: startup + 1 minute; mode: -AsService'
    Write-Host "Log directory: $LogDirectory"
    Write-Host ('Log file: ' + (Join-Path $LogDirectory 'Update-WSUSComputerOperatingSystems.log'))
    Write-Host ('Local error log: ' + (Join-Path $directory 'Update-WSUSComputerOperatingSystems_errors.log'))
    Write-Host 'Dot-prefixed files/folders are not copied; other local files are retained.'
    Write-Host 'No old-version backups are created. Changed files are staged as .new before replacement.'
    if (-not (Read-YesNo 'Apply file changes and register/update the scheduled task?' -DefaultYes $false)) {
        Write-Host 'Cancelled. No files or tasks were changed.'
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

    $wasRunning = ($null -ne $existing -and $existing.State -eq 'Running')
    if ($wasRunning) {
        Write-Host 'Stopping the existing WSUS OS monitor task...'
        Stop-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
        $until = (Get-Date).AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 500
            $state = (Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName).State
        } while ($state -eq 'Running' -and (Get-Date) -lt $until)
        if ($state -eq 'Running') { throw 'The previous task instance did not stop. No installed files were replaced.' }
    }

    # A full multi-file update is NOT transactional, but every individual
    # replacement is atomic on the same volume. No backup files are created.
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
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -InputObject $task -Force -ErrorAction Stop | Out-Null
    $taskRegistered = $true

    Write-Host ''
    Write-Host "Installed task: $TaskPath$TaskName"
    Write-Host 'Task runs as SYSTEM on startup with a 1-minute delay and no time limit.'
    try {
        Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
        Write-Host 'Task start requested. Check the log for SQL access and write permissions under SYSTEM.'
    } catch {
        Write-Warning ('Task installed, but failed to start: ' + $_.Exception.Message)
    }
    Write-Host ('Log file: ' + (Join-Path $LogDirectory 'Update-WSUSComputerOperatingSystems.log'))
} catch {
    if ($replacedCount -gt 0 -and -not $taskRegistered) {
        Write-Warning ("{0} file(s) were changed before an installation error. No automatic rollback (no backups)." -f $replacedCount)
    }
    if ($wasRunning -and -not $taskRegistered) {
        try {
            Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
        } catch {
            Write-Warning 'Could not restart the previously running task after an installation error.'
        }
    }
    throw
} finally {
    foreach ($path in $stagedFiles) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
