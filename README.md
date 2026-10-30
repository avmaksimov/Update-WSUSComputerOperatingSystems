# Update-WSUSComputerOperatingSystems — event-driven fork

**Language:** **English** | [Русский](README.ru.md)

This fork builds on [Borgquite/Update-WSUSComputerOperatingSystems](https://github.com/Borgquite/Update-WSUSComputerOperatingSystems) and retains its operating-system/build/edition mappings. **The event-driven monitoring and logging enhancements were developed in this fork.**

The fork adds continuous WSUS `OSDescription` monitoring through SQL Query Notifications (`SqlDependency`), automatic correction when WSUS clients overwrite OS names, SQL reconnection, a Task Scheduler installer and configurable local or UNC logging with local error diagnostics. The listener runs in `-AsService` mode; a one-time scan is also available.

**No `SqlServer` PowerShell module, NuGet provider, or other third-party runtime dependency is required.** The implementation uses `System.Data.SqlClient` from the .NET Framework available to Windows PowerShell 5.1.

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

`-Encrypt Optional` is the default (ADO.NET `Encrypt=False`); `-Encrypt Mandatory` enables ADO.NET `Encrypt=True` and requires a trusted server certificate. `True` and `False` are also accepted. `-DurationMinutes` is only valid with `-AsService`; zero means no time limit. Known client and server OS editions are processed except excluded LTSC editions. Unknown builds/SKUs are left untouched.

## Installation and updates (`Update.ps1`)

**`Update.ps1` takes no command-line parameters.** Run it from an elevated **Windows PowerShell 5.1** session on the WSUS server. It manages both first-time installation and later updates.

The update source is fixed in the updater itself:

```powershell
$owner = 'avmaksimov'
$repository = 'Update-WSUSComputerOperatingSystems'
$branch = 'main'
```

The updater downloads the corresponding GitHub repository ZIP over HTTPS (including `Uninstall.ps1`), compares SHA-256 hashes, and displays every `INSTALL`, `REPLACE`, and `UNCHANGED` file before one confirmation. It stages changed files as `.new` beside their destinations and verifies their hashes before replacing originals. Dot-prefixed files or directories (such as `.gitignore` and `.github`) are excluded; unrelated local files are **not removed**. There are no old-version backups or updater log files. A multi-file update is **not** transactional.

> **Source integrity:** SHA-256 here detects differences and verifies staged copies; it does **not** authenticate the software publisher. HTTPS protects data in transit, but a compromised repository or mutable `main` branch could distribute hostile code. Inspect the file list and review executable changes before approving, protect the local script directory with NTFS permissions, and use a trusted repository. The monitor runs as `SYSTEM`. For strict provenance, manually review a pinned release/commit; this updater does not validate signatures.

### First installation

The first time (when **no existing project task** is found), the updater asks for:

1. **Installation directory** (default: current PowerShell directory, provided it is not a temporary folder).
2. **Task Scheduler folder** (default: root `\`; for example, `\MP\`).
3. **Log directory** (default: installation directory; UNC paths such as `\\server3\share\_Logs` supported).
4. **SQL Server instance** (default: local WID named pipe).

After download and comparison, it asks **once** whether to apply the file changes and create the task. The created task runs `Update-WSUSComputerOperatingSystems.ps1 -AsService` as `SYSTEM` at system startup (one-minute delay), with the selected log folder. The task is started immediately after registration. If using a network share for logs, grant the computer account of the WSUS server write access at both SMB-share and NTFS levels; mapped drives are not available under `SYSTEM`.

### Subsequent updates

The updater automatically finds the single existing `Update-WSUSComputerOperatingSystems` project task, regardless of its Task Scheduler folder, and reads the **installation directory from the task's existing `-File` argument**. It does **not** ask again for installation, task, SQL or log settings and it **does not recreate or overwrite the existing task**.

If the main monitor `.ps1` changed and the task was running, it stops the task, replaces the changed files and starts the task again. If only documentation or updater files changed, the monitor continues running without interruption. If nothing changed, no confirmation is required. A previously stopped task remains stopped.

Legacy project tasks without `-LogDirectory` are left unchanged and continue using the main script's default local log directory. To change the log folder or SQL arguments later, use **Task Scheduler → task properties → Actions → Edit**, then restart that task. To relocate the task to another Scheduler folder, export and import it into the desired folder, verifying the task action and principal; the updater will discover the new location on the next run.

If several matching project tasks exist, or a different task reuses the same name, the updater stops instead of guessing which task to modify. The existing task may retain manually customized triggers and settings; routine updates preserve them. To uninstall, run `Uninstall.ps1` from an elevated PowerShell session. It removes only the project task after confirmation; installed scripts and logs remain.

### Uninstallation (`Uninstall.ps1`)

From an elevated Windows PowerShell 5.1 session on the WSUS server, run:

```powershell
.\Uninstall.ps1
```

The script has **no parameters**. It finds the project task in any Task Scheduler folder, checks that it launches this project's monitor and asks for one confirmation. If more than one matching task exists or a different task has the same name, it refuses to delete anything. A running task is stopped before removal. **Only the scheduled task is unregistered**; the task folder, scripts, documentation and logs are preserved. Running `Update.ps1` again will offer first-time task setup, reusing the files already present when their hashes match.

### Download and run

A short one-liner downloads the **updater only** into a unique file under `%TEMP%`, runs it without arguments, then deletes the temporary copy. On an existing installation, the destination is found from Task Scheduler, not from the location of the temporary file:

```powershell
$f=Join-Path $env:TEMP ("WSUS-Update-$([guid]::NewGuid().ToString('N')).ps1"); try { Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/avmaksimov/Update-WSUSComputerOperatingSystems/main/Update.ps1' -OutFile $f -ErrorAction Stop; & $f } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
```

Alternatively, run the installed updater directly:

```powershell
& 'C:\Scripts\WSUS\Update.ps1'
```

To use this updater for a different repository, change the `$owner`, `$repository`, and `$branch` constants in its source (there is no URL argument or external configuration file). Previously installed files with old names are not deleted automatically.

## How the listener works

1. Load the OS catalog (the catalog's current OS/build/SKU combinations).
2. In one-shot mode, read all `tbComputerTargetDetail` rows and update only incorrectly labelled entries.
3. In `-AsService` mode, register `SqlDependency` **before** initial reconciliation to avoid missing concurrent WSUS writes.
4. On SQL notification, register the next notification before processing changes. Compare the previous and current snapshots by numeric `TargetID`, and check OS/build/SKU fields before writing.
5. Own SQL `UPDATE` statements may also fire notifications. The next pass performs **no UPDATE** if the description already matches the catalog.
6. On an SQL error, stop the current listener, wait 15 seconds, reconnect and recheck the entire table.

No triggers are added to SUSDB, and the tool never manually cleans up SqlDependency's Service Broker objects. No mutex is used. Keep a single active event listener through the Task Scheduler setting `MultipleInstances=IgnoreNew`; if you also have the older periodic task, disable it to avoid unnecessary concurrent updates.

## Logging

The main script writes its regular log to the directory selected during **initial installation**, using the filename `Update-WSUSComputerOperatingSystems.log`. By default, this is the installation directory; UNC shares are also supported. The Task Scheduler folder (for example `\MP\`) is unrelated to the log path.

- **First installation:** `Update.ps1` asks for the log directory once. Press Enter to use the installation directory; the path is saved in the scheduled task action as `-LogDirectory`.
- **Subsequent updates:** `Update.ps1` reads the existing task configuration and **does not ask** for the log directory or overwrite the action. Legacy tasks without `-LogDirectory` also remain unchanged and continue using their local default.
- **Changing the path later:** edit the existing task in **Task Scheduler → Properties → Actions → Edit** and change the path within `-LogDirectory "..."` (keep the quotation marks). Stop and restart the task for the running monitor to use the new path. `Update.ps1` has no command-line parameters for changing task settings.

For a network location, use a **UNC path**, not a user-mapped drive such as `M:`. The task runs under `NT AUTHORITY\SYSTEM`; remote SMB access normally uses the domain machine account (for example, `BS\SERVER1$`). Grant this account the necessary share and NTFS permissions. The updater shows a reminder but does not change network permissions.

The main log contains ordinary `INFO`, `WARNING`, and `ERROR` messages **only at the selected destination**. If this differs from the script directory, warnings and errors are also written to a local diagnostic file beside the main script: `Update-WSUSComputerOperatingSystems_errors.log`. If writing to the selected destination fails (such as an unavailable SMB share), the error and the failed entry are written to this local diagnostic file. The listener continues running; later entries are retried at the selected destination, but failed entries are not automatically replayed. If the main log is already local and writing to it fails, the local error file is also used.

Each line uses the local server's time in the format `dd.MM.yyyy HH:mm:ss.fff [LEVEL] Message` with `INFO`, `WARNING`, or `ERROR` levels. Example:

```text
24.10.2026 21:57:34.345 [INFO] Catalog loaded: 979 combinations. Mode=SERVICE.
24.10.2026 21:57:34.678 [ERROR] SQL/listener error: ...; reconnecting in 15 seconds.
```

On startup and after SQL reconnection, a full reconciliation writes one `Reconciliation: checked=...; wrong=...; updated=...` summary instead of a separate `UPDATED INITIAL` line for each computer. During normal event monitoring, only actual changes (`UPDATED CHANGED ...`), warnings and errors are logged; there is no repeated `Affected=...` summary after individual notifications.

The main script **appends only**: it never rotates, truncates or removes either log. Arrange retention or rotation externally if needed. Persistent connection failures can produce log lines every 15 seconds. Messages include catalog load, actual fixes, SQL errors and reconnects; no-op notifications are not logged. Logs are created when the main script runs, not by Install.

To follow the main log (adjust the path to the directory currently configured in the scheduled task):

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

**Original project and OS catalog:** [Borgquite/Update-WSUSComputerOperatingSystems](https://github.com/Borgquite/Update-WSUSComputerOperatingSystems).

**Enhancements implemented in this fork:** event-driven SQL monitoring and OS-description correction, reconnection handling, automated Task Scheduler setup, and configurable logging (including local diagnostics for logging errors).

The project retains the original attribution and is distributed under the **GNU General Public License version 3**; see `LICENSE`.

### Offline catalog check

Before using the main script against SUSDB, you can run:

```powershell
.\tests\Test-WSUSCatalog.ps1
```

This parses the script and evaluates **only** the built-in catalog definitions and functions; it performs no SQL reads or writes. It reports the current catalog size (without hardcoding 1094), validates representative Windows 10/11/Server/Azure Stack HCI mappings, and uses stubbed SQL/logging functions to test initial reconciliation, unchanged notifications, correction after WSUS overwrites, build changes and concurrent UPDATE skips. It also checks for critical SQL guards. **The main script is not executed.** The test does not need WSUS or a connection to SUSDB.

## Additional production checks

- Validate the installer/task **under SYSTEM**, not just from an elevated interactive shell. Check `Update-WSUSComputerOperatingSystems.log` in the configured log directory after manual task start (and `Update-WSUSComputerOperatingSystems_errors.log` beside the script if a write failed).
- Use only one ongoing `-AsService` task. `Get-ScheduledTask -TaskName 'WSUS*'` helps locate older scheduled tasks, but inspect them before disabling anything.
- A 60-minute `-AsService` test confirms startup and idle waiting; also verify that an actual client OSDescription overwrite is corrected.
- Check that the WID Service Broker notification feature remains enabled in SUSDB. The script assumes it, rather than enabling it automatically.
- The current listener retries an SQL connection failure every 15 seconds; persistent failures are logged and not reported through Task Scheduler because the service process remains running.
- The SQL updates are direct SUSDB changes, not a supported WSUS management API. Keep a verified backup and check operation after WSUS upgrades.
