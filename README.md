# Update-WSUSComputerOperatingSystems — event-driven fork

This project is based on [Borgquite/Update-WSUSComputerOperatingSystems](https://github.com/Borgquite/Update-WSUSComputerOperatingSystems) and preserves its operating-system/build/edition mappings. It adds an optional event-driven mode that repairs Windows Server Update Services (WSUS) `OSDescription` values after clients overwrite them.

The event listener is based on a tested `Watch-WSUSOS-AutoFix-v1.1.ps1` prototype. **No `SqlServer` PowerShell module, NuGet provider, or other third-party runtime dependency is required.** The code uses `System.Data.SqlClient` from the .NET Framework available to Windows PowerShell 5.1.

> **Warning:** This utility directly updates the WSUS `SUSDB` database, which is not an officially supported Microsoft WSUS management API. Make a verified backup before deployment. Run and validate on a noncritical environment first. Provided without warranty under GPL-3.0.

## Requirements

- Windows Server 2019 Core or newer; Windows PowerShell 5.1 (Desktop edition).
- WSUS with Windows Internal Database (WID) or Microsoft SQL Server.
- SQL login with read access to `dbo.tbComputerTarget` and `dbo.tbComputerTargetDetail` and update access to `OSDescription`.
- For `-AsService`: a working Service Broker in `SUSDB` and permission for SQL Query Notifications / `SqlDependency`. Confirm that the task account (`SYSTEM` by default) can establish the required SQL subscriptions.
- No additional PowerShell modules need to be downloaded.

## Manual runs

Run from an elevated Windows PowerShell 5.1 session on the WSUS server:

```powershell
# Check all computer records once; fix incorrect descriptions; exit.
.\Update-WSUSComputerOperatingSystems.ps1

# Check existing records and then watch for changes indefinitely.
.\Update-WSUSComputerOperatingSystems.ps1 -AsService

# Watch for 60 minutes and then exit.
.\Update-WSUSComputerOperatingSystems.ps1 -AsService -DurationMinutes 60
```

By default, `-SQLServerInstance` is the local WID named pipe `\\.\pipe\MICROSOFT##WID\tsql\query`. For an external SQL Server:

```powershell
.\Update-WSUSComputerOperatingSystems.ps1 -SQLServerInstance 'SQLSERVER\INSTANCE' -AsService
```

`-Encrypt Optional` is the default (ADO.NET `Encrypt=False`); `-Encrypt Mandatory` enables ADO.NET `Encrypt=True` and requires a trusted server certificate. `True` and `False` are also accepted. `-DurationMinutes` is only valid with `-AsService`; zero means no time limit. All known client and server OS editions are processed. Unknown builds/SKUs are left untouched.

## Installation (scheduled task)

Run the installer **on the WSUS server**, from an elevated **Windows PowerShell 5.1** session. The resulting task runs the main script **in the installation directory**; there is no copy into `Program Files`. When `-InstallPath` is omitted, the installer looks for the main PS1 **next to its own file** (`$PSScriptRoot`), not in the caller's PowerShell working directory (`$PWD`). The installer is the only setup file you need. When the main script is missing it downloads it; when already present it asks `Download the latest version? [Y/n]` (default **Yes**).

> **GitHub source:** The installer and quick-install commands are configured to download from [`avmaksimov/Update-WSUSComputerOperatingSystems`](https://github.com/avmaksimov/Update-WSUSComputerOperatingSystems), branch `main`. **Publish the fork with this repository name and branch before using the download commands**; until it is published the URLs may return HTTP 404. Do **not** switch these URLs to the original Borgquite repository because it does not contain the fork's event-driven script. You can still use an already available main script by declining an update, or provide an alternative URL using `-MainScriptUrl`.

### Quick installation (download and run Install)

These one-liners download **only the installer** into a uniquely named file in `%TEMP%`, execute it, and delete the temporary copy. The installer then downloads/updates the main script into the chosen *permanent* location and registers the scheduled task. The commands do not overwrite an existing main script without the update prompt. Review the downloaded installer before running code obtained from the internet.

**A. Install in the current directory.** First navigate to the desired permanent folder (`Set-Location` or `cd`), then run. The one-liner explicitly passes that folder via `-InstallPath`, because the downloaded installer itself lives in `%TEMP%`:

```powershell
$f=Join-Path $env:TEMP ("WSUS-Install-$([guid]::NewGuid().ToString('N')).ps1"); try { Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/avmaksimov/Update-WSUSComputerOperatingSystems/main/Install-WSUSComputerOperatingSystems.ps1' -OutFile $f -ErrorAction Stop; & $f -InstallPath (Get-Location).ProviderPath } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
```

**B. Install in an explicitly chosen directory.** Change `C:\Scripts\WSUS` to the desired permanent location; you do not need to `cd` first:

```powershell
$f=Join-Path $env:TEMP ("WSUS-Install-$([guid]::NewGuid().ToString('N')).ps1"); try { Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/avmaksimov/Update-WSUSComputerOperatingSystems/main/Install-WSUSComputerOperatingSystems.ps1' -OutFile $f -ErrorAction Stop; & $f -InstallPath 'C:\Scripts\WSUS' } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
```

The URL remains stable as long as the repository uses that branch and file path. If a branch or file is renamed, the URL must be updated. The commands fetch the current branch version, not a pinned release; for repeatable installations use an immutable release tag or commit in the URL.

### Manual installation (two alternatives)

Download `Install-WSUSComputerOperatingSystems.ps1` from the fork (or extract this repository ZIP). If the installer is in the intended permanent folder, you can simply run it from anywhere: it locates the main script beside itself. When the installer is in a temporary folder, you must supply a permanent destination (interactively or via `-InstallPath`). The caller's current directory has no influence unless you explicitly pass it with `-InstallPath`.

**A. Install next to the installer (default):**

```powershell
# Run the installer from its permanent folder; the caller's current folder does not matter.
& 'C:\Scripts\WSUS\Install-WSUSComputerOperatingSystems.ps1'
```

If the main script already exists **next to the installer**, the installation-directory question is skipped. If it is missing, the installer offers its own directory as the default; press Enter to accept (unless the installer itself is in a temporary directory).

**B. Install into a directory supplied explicitly:**

```powershell
& 'C:\Temp\WSUS\Install-WSUSComputerOperatingSystems.ps1' -InstallPath 'D:\Scripts\WSUS'
```

`-InstallPath` bypasses the directory question when it is a valid permanent path. `C:\Temp\WSUS` is only an **example location for the downloaded installer**, not the destination of the long-running script.

### Installer prompts and task configuration

- If no main PS1 exists in the target directory, download it automatically. Otherwise offer to download the latest version, **Yes** by default; answering **No** keeps the current file.
- If no `-InstallPath` is passed, look for the main PS1 next to the installer (`$PSScriptRoot`). If missing, ask for a destination, offering the **installer's directory** as the default.
- If a temporary location is selected (`%TEMP%`, `%TMP%`, `C:\Temp`, etc.), require a different, permanent destination. An empty response is not accepted while the default is temporary. A temporary copy of **Install** itself is allowed.
- Automatically find the existing project task across all Task Scheduler folders. With one match, reuse its folder; with no matching tasks, install in the root (`\`). If more than one project task is found, specify `-TaskPath` explicitly. Unrelated same-name tasks are never modified.
- Show installation summary and ask for confirmation. An existing task is updated only after explicit confirmation. If no project task matches but an unrelated task has the same name, stop and require an explicit `-TaskPath`. Other same-name tasks are reported but not modified.
- Only the project task **`Update-WSUSComputerOperatingSystems`** is created or updated. It does not replace your preexisting `WSUS Update Operating Systems` task.
- Download the main script to a temporary stage, check PowerShell syntax and `-AsService` support, and replace it only after confirmation. A task that is currently running is stopped before reconfiguration and **restarted afterwards**. A newly created task is **started immediately** after registration (in addition to its startup trigger).
- Register the task under `SYSTEM`, startup trigger delayed by one minute, unlimited execution time and restart-on-failure. The task action runs `Update-WSUSComputerOperatingSystems.ps1 -AsService` from the chosen permanent directory.
- The installer does not copy itself into the installation directory. Uninstall removes **only the scheduled task**, leaving all files and logs untouched.

To specify a different Task Scheduler folder or SQL settings without extra prompts:

```powershell
.\Install-WSUSComputerOperatingSystems.ps1 -InstallPath 'C:\Scripts\WSUS' -TaskPath '\MP'
.\Install-WSUSComputerOperatingSystems.ps1 -InstallPath 'C:\Scripts\WSUS' -TaskPath '\MP' -SQLServerInstance 'SQLSERVER\INSTANCE' -Encrypt Mandatory
```

The installer requests a task start immediately after successful registration. Check the log for startup and SQL access under `SYSTEM`. To start the task again manually:

```powershell
Start-ScheduledTask -TaskPath '\MP' -TaskName 'Update-WSUSComputerOperatingSystems'
```

To remove the task (leave script files untouched), its Task Scheduler folder is detected automatically if there is exactly one matching project task:

```powershell
.\Install-WSUSComputerOperatingSystems.ps1 -Uninstall
```

Specify `-TaskPath '\MP'` only if multiple project tasks exist or you want to target a particular folder.

**Security:** The installer must run elevated because it registers a SYSTEM task. Restrict write access to the permanent installation directory: anybody who can replace the main PS1 can control code executed as SYSTEM. Review remote code and validate its source. No scripts are downloaded when you decline an update and already have the main PS1.

## How the listener works

1. Load the OS catalog (the catalog's current OS/build/SKU combinations).
2. In one-shot mode, read all `tbComputerTargetDetail` rows and update only incorrectly labelled entries.
3. In `-AsService` mode, register `SqlDependency` **before** initial reconciliation to avoid missing concurrent WSUS writes.
4. On SQL notification, register the next notification before processing changes. Compare the previous and current snapshots by numeric `TargetID`, and check OS/build/SKU fields before writing.
5. Own SQL `UPDATE` statements may also fire notifications. The next pass performs **no UPDATE** if the description already matches the catalog.
6. On an SQL error, stop the current listener, wait 15 seconds, reconnect and recheck the entire table.

No triggers are added to SUSDB, and the tool never manually cleans up SqlDependency's Service Broker objects. No mutex is used. Keep a single active event listener through the Task Scheduler setting `MultipleInstances=IgnoreNew`; if you also have the older periodic task, disable it to avoid unnecessary concurrent updates.

## Logging

The log is stored **next to the main script** as `Update-WSUSComputerOperatingSystems.log`, independently of the Task Scheduler folder. For example, when installed in `C:\Scripts\Update-WSUSComputerOperatingSystems`, the log is `C:\Scripts\Update-WSUSComputerOperatingSystems\Update-WSUSComputerOperatingSystems.log`. The installer prints the actual path after registration.

Each line uses the local server's time in the format `dd.MM.yyyy HH:mm:ss.fff [LEVEL] Message` with `INFO`, `WARNING`, or `ERROR` levels. Example:

```text
24.10.2026 21:57:34.345 [INFO] Catalog loaded: 1094 combinations. Mode=SERVICE.
24.10.2026 21:57:34.678 [ERROR] SQL/listener error: ...; reconnecting in 15 seconds.
```

The main script **appends only**: it never rotates, truncates or removes the log. Arrange retention or rotation externally if needed. Persistent connection failures can produce log lines every 15 seconds. Messages include catalog load, actual fixes, SQL errors and reconnects; no-op notifications are not logged. The log is created when the main script runs, not by Install. The script runs as `SYSTEM` under Task Scheduler and needs write access to its directory.

To follow the log (adjust the path to your installation directory):

```powershell
Get-Content 'C:\Scripts\Update-WSUSComputerOperatingSystems\Update-WSUSComputerOperatingSystems.log' -Tail 30 -Wait
```

## Validation before production

Use a current backup of SUSDB. On your target server, verify these steps:

1. Run without `-AsService`; inspect the log and WSUS console. Run it a second time: it should make zero updates.
2. Start `-AsService -DurationMinutes 60`; wait for the WSUS client reporting cycle, and check that overwritten OS names are repaired.
3. Check the automatically started task under `SYSTEM` after installation (including access to WID and `SqlDependency`).
4. Restart the WID service during a maintenance window and confirm that the listener reconnects and checks all rows again.
5. Test Ctrl+C and a forced shutdown followed by an immediate restart.
6. Confirm the preexisting task `WSUS Update Operating Systems`, if any, remains unchanged, and disable it separately when appropriate.

## Attribution and license

Original mappings and purpose: [Borgquite/Update-WSUSComputerOperatingSystems](https://github.com/Borgquite/Update-WSUSComputerOperatingSystems). Event-based behavior: `Watch-WSUSOS-AutoFix-v1.1.ps1` prototype. Distributed under the **GNU General Public License version 3**; see `LICENSE`.

This folder contains replacement files to copy into a *real GitHub fork* of the original repository; it is not itself a Git repository with upstream history. Preserve the original repository history when publishing, and do not push without the repository owner's authorization.

### Offline catalog check

Before using the main script against SUSDB, you can run:

```powershell
.\tests\Test-WSUSCatalog.ps1
```

This parses the script and evaluates **only** the built-in catalog definitions and functions; it performs no SQL reads or writes. It reports the current catalog size (without hardcoding 1094), validates representative Windows 10/11/Server/Azure Stack HCI mappings, and uses stubbed SQL/logging functions to test initial reconciliation, unchanged notifications, correction after WSUS overwrites, build changes and concurrent UPDATE skips. It also checks for critical SQL guards. **The main script is not executed.** The test does not need WSUS or a connection to SUSDB.

## Additional production checks

- **The main script retains the last tested structured OS catalog and SQL event/update logic; only its logging has changed in this package.** The old draft ZIP contains a different catalog layout; do not replace the script with that older draft.
- Validate the installer/task **under SYSTEM**, not just from an elevated interactive shell. Check `Update-WSUSComputerOperatingSystems.log` in the main script directory after manual task start.
- Use only one ongoing `-AsService` task. `Get-ScheduledTask -TaskName 'WSUS*'` helps locate older scheduled tasks, but inspect them before disabling anything.
- A 60-minute `-AsService` test confirms startup and idle waiting; also verify that an actual client OSDescription overwrite is corrected.
- Check that the WID Service Broker notification feature remains enabled in SUSDB. The script assumes it, rather than enabling it automatically.
- The current listener retries an SQL connection failure every 15 seconds; persistent failures are logged and not reported through Task Scheduler because the service process remains running.
- The SQL updates are direct SUSDB changes, not a supported WSUS management API. Keep a verified backup and check operation after WSUS upgrades.
