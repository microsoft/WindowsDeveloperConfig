# Windows Developer Config: Slipstream Preview

Slipstream turns a fresh Windows 11 machine into a developer workstation with
one command, one UAC prompt, and automatic resume after required restarts.

This preview intentionally does **not** use `winget configure` or DSC. PowerShell
owns elevation, prerequisite repair, restart checkpoints, package installation,
settings convergence, and final verification directly.

## Run the signed build

Download and extract the artifact produced by the repository's OneBranch sign
pipeline, then run:

```powershell
.\src\windows-dev-config\install.ps1
```

The artifact scripts are Authenticode-signed. Slipstream rejects unsigned or
unexpectedly signed scripts before privileged configuration begins.

What to expect:

1. One UAC prompt.
2. A prerequisite pass that repairs WinGet when necessary.
3. An automatic restart when WSL or pending Windows servicing requires it.
4. Setup resumes elevated after sign-in without another UAC prompt.
5. Ubuntu, developer tools, Windows settings, fonts, Terminal, and shell tooling
   are configured and independently verified.

Save open work before starting. The normal clean-machine path restarts once.

## Source-tree validation

The unsigned `src` tree is for development only:

```powershell
# Does not elevate, install, register a task, or restart.
.\src\windows-dev-config\install.ps1 -Action Validate -AllowUnsigned

# Disposable VM only: run the unsigned source end-to-end.
.\src\windows-dev-config\install.ps1 -AllowUnsigned
```

Use `-NoRestart` to stop at a restart checkpoint and reboot manually:

```powershell
.\src\windows-dev-config\install.ps1 -AllowUnsigned -NoRestart
```

## Status and recovery

```powershell
.\src\windows-dev-config\install.ps1 -Action Status
```

Durable state and logs live at:

```text
C:\ProgramData\Microsoft\WindowsDeveloperConfig\
  payloads\<run-id>\
  runs\<run-id>\
    state.json
    logs\setup.log
```

The pinned payload and resume task are scoped to a unique run ID. A failed run
removes its elevated task but retains state and logs for diagnosis.

To explicitly remove a failed run's pinned payload, open an elevated PowerShell:

```powershell
.\src\windows-dev-config\install.ps1 -Action Cleanup -RunId <run-id>
```

## What gets configured

- Windows Terminal and PowerShell 7
- Git, GitHub CLI, GitHub Copilot CLI, and VS Code
- .NET 10, Python 3.14, uv, Node.js LTS, and NVM for Windows
- Coreutils for Windows, Oh My Posh, Windows Application CLI, and PowerToys
- WSL platform plus Ubuntu
- Dark theme, Developer Mode, long paths, Explorer/taskbar/search cleanup,
  Edge policies, Windows Sudo, Remote Desktop, and notification settings
- Cascadia Code and Cascadia Mono Nerd Fonts
- Windows Terminal defaults and a GitHub Copilot profile
- WinUI .NET templates and the WinUI Copilot plugin

Ubuntu is installed with `--no-launch`. Open it after setup to create the Linux
username and password.

## Payload layout

```text
windows-dev-config\
  install.ps1                 # sole public entry point and UAC handoff
  bootstrap\
    controller.ps1            # checkpointed phase runner
    common.ps1                # state, logs, hashes, native process handling
    platform.ps1              # WinGet repair, pending reboot, WSL and Ubuntu
    resume.ps1                # elevated interactive-user task and restart
    configure.ps1             # packages, registry, fonts, Terminal and plugins
    user.ps1                  # limited-token Copilot plugin configuration
    verify.ps1                # independent end-state verification
  config\
    packages.json             # declarative package inventory
    registry.json             # declarative registry inventory
```

All PowerShell files are signed by the existing pipeline. Hashes for the two JSON
manifests are embedded in signed `bootstrap\common.ps1`.

## Restart and elevation model

The initial elevated process registers a Task Scheduler entry with:

- the initiating user's SID;
- `TASK_LOGON_INTERACTIVE_TOKEN`;
- `TASK_RUNLEVEL_HIGHEST`;
- an at-logon trigger for that same user;
- an action pointing to the pinned, administrator-owned payload.

This preserves the user's HKCU, profile, network access, and interactive desktop
while resuming elevated without a second consent dialog. The task is deleted
after success or terminal failure.

The one-UAC behavior requires the signed-in account to be a local administrator
with a UAC split token. Supplying credentials for a different administrator is
rejected because silently resuming that other token would require credential
storage.

## Signing the preview

Queue `.pipelines\OneBranch.SignAndPackage.yml` against the Slipstream branch.
For branch testing, switch the pipeline to the documented non-official OneBranch
template. Test the resulting artifact, not raw branch scripts.

Only edit `src\windows-dev-config`. The top-level `windows-dev-config` folder is
the generated signed release copy and must not be edited by hand.
