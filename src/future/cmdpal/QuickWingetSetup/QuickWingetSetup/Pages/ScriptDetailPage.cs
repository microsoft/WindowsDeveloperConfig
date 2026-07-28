using Microsoft.CommandPalette.Extensions;
using Microsoft.CommandPalette.Extensions.Toolkit;
using QuickWingetSetup.Models;
using QuickWingetSetup.Services;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

namespace QuickWingetSetup;

internal sealed partial class ScriptDetailPage : ListPage
{
    private readonly ScriptEntry _script;
    private readonly ScriptFetchService _fetchService;

    public ScriptDetailPage(ScriptEntry script, ScriptFetchService fetchService)
    {
        _script = script;
        _fetchService = fetchService;
        Icon = new IconInfo(_script.Icon);
        Title = _script.Name;
        Name = _script.Name;
        ShowDetails = true;
    }

    public override IListItem[] GetItems()
    {
        var items = new List<IListItem>();

        if (_script.WindowsLaunchPath is { } winPath)
        {
            var localPath = (_script.UsesPowerShellInstaller
                ? _fetchService.GetPayloadEntryPathAsync(winPath, _script.Windows?.PayloadFiles)
                : _fetchService.GetScriptPathAsync(winPath)).GetAwaiter().GetResult();
            var winTags = new List<Tag> { new("Windows") };
            var winSubtitle = _script.UsesPowerShellInstaller
                ? $"PowerShell installer {winPath}"
                : $"winget configure {winPath}";

            // Flows that need WSL even though they register as Windows-only
            // (e.g. mac-comfort-shell installs a font via DSC but the
            // follow-up manual step runs inside a WSL distro). Surface the
            // same ⚠️ affordances we show on Linux items.
            if (_script.RequiresWsl)
            {
                var wslStatus = WslDetectionService.Status;
                if (wslStatus == WslStatus.NoWsl)
                {
                    winTags.Add(new Tag("⚠️ WSL not installed"));
                    winSubtitle = "WSL is not installed — select to install";
                }
                else if (wslStatus == WslStatus.NoDistro)
                {
                    winTags.Add(new Tag("⚠️ No WSL distro"));
                    winSubtitle = "WSL has no distro configured — select to install";
                }
                else
                {
                    winTags.Add(new Tag("Requires WSL"));
                }
            }

            items.Add(new ListItem(new RunWindowsSetupCommand(winPath, _fetchService, _script))
            {
                Title = "🪟 Run Windows Setup",
                Subtitle = winSubtitle,
                Tags = [.. winTags],
                Details = BuildScriptDetails(localPath),
                MoreCommands = BuildContextCommands(localPath),
            });
        }

        if (_script.Includes != null && _script.Includes.Length > 0)
        {
            items.Add(new ListItem(new NoOpCommand())
            {
                Title = "📦 Includes",
                Subtitle = string.Join(", ", _script.Includes),
            });
        }

        if (!string.IsNullOrEmpty(_script.OnboardingUrl))
        {
            items.Add(new ListItem(new OpenUrlCommand(_script.OnboardingUrl))
            {
                Title = "📖 Official Docs",
                Subtitle = _script.OnboardingUrl,
                Tags = [new Tag("Documentation")],
            });
        }

        return items.ToArray();
    }

    private Details? BuildScriptDetails(string? localPath)
    {
        if (localPath == null || !File.Exists(localPath))
        {
            return null;
        }

        var summary = ScriptSummaryService.Summarize(localPath);
        var details = new Details()
        {
            Title = _script.Name,
            Body = summary,
            Metadata = [
                new DetailsElement() { Key = "", Data = new DetailsCommands() { Commands = [new ViewFileCommand(localPath)] } },
            ],
        };
        return details;
    }

    private static IContextItem[] BuildContextCommands(string? localPath)
    {
        if (localPath == null || !File.Exists(localPath))
        {
            return [];
        }

        return [
            new CommandContextItem(new ViewFileCommand(localPath)) { Title = "View script file" },
        ];
    }
}

internal sealed partial class RunWindowsSetupCommand : InvokableCommand, IConfirmationArgs
{
    private const string FixItRelativePath = "scripts/windows/_common/enable-winget-configure.ps1";

    private readonly string _scriptPath;
    private readonly ScriptFetchService _fetchService;
    private readonly ScriptEntry _script;

    public RunWindowsSetupCommand(string scriptPath, ScriptFetchService fetchService, ScriptEntry script)
    {
        _scriptPath = scriptPath;
        _fetchService = fetchService;
        _script = script;
    }

    // IConfirmationArgs: CmdPal shows the dialog before invoking the
    // command. We always require confirmation because `winget configure`
    // on a real DSC config can install packages, change registry values,
    // disable services, etc. — not the kind of thing we want to launch on
    // a stray Enter key. The shared "winget configure …" subtitle on the
    // list page already telegraphs intent; the dialog is the seatbelt.
    public string Title => $"Run {_script.Name} setup?";
    public string Description =>
        (_script.UsesPowerShellInstaller
            ? $"This will run the PowerShell installer {_scriptPath} in a new Windows Terminal tab. "
            : $"This will run `winget configure` against {_scriptPath} in a new Windows Terminal tab. ")
        + "Some flows install packages, change Windows settings, or enable WSL. Re-running is safe (each flow is idempotent).";
    public Microsoft.CommandPalette.Extensions.ICommand? PrimaryCommand => this;
    public bool IsPrimaryCommandCritical => false;

    public override ICommandResult Invoke()
    {
        // For flows that declare RequiresWsl, re-check WSL at click time
        // and divert to `wsl --install` when it's missing — the winget
        // configure step would succeed but leave the user stranded with
        // no distro for the manual follow-up.
        if (_script.RequiresWsl && WslDetectionService.RefreshStatus() != WslStatus.Available)
        {
            ScriptRunnerService.RunWslInstall();
            return CommandResult.Dismiss();
        }

        // Re-check `winget configure` health at invocation time (covers
        // the case where the user fixed it in another window since the
        // page last rendered). If still broken, divert to the remediation
        // script instead of launching a wt.exe tab that would just fail
        // with an opaque winget error.
        var health = _script.UsesPowerShellInstaller
            ? WingetConfigureStatus.Available
            : WingetConfigureHealthService.RefreshStatus();
        if (!_script.UsesPowerShellInstaller && health != WingetConfigureStatus.Available)
        {
            try
            {
                var fixItPath = _fetchService.GetScriptPathAsync(FixItRelativePath).GetAwaiter().GetResult();
                if (!string.IsNullOrEmpty(fixItPath))
                {
                    ScriptRunnerService.RunEnableWingetConfigure(fixItPath);
                }
            }
            catch
            {
                // Can't even get the remediation script — fall through to
                // the regular path so the user at least sees the raw
                // winget error. This is a last-resort.
            }
            return CommandResult.Dismiss();
        }

        var localPath = (_script.UsesPowerShellInstaller
            ? _fetchService.GetPayloadEntryPathAsync(_scriptPath, _script.Windows?.PayloadFiles)
            : _fetchService.GetScriptPathAsync(_scriptPath)).GetAwaiter().GetResult();
        if (localPath == null)
        {
            return CommandResult.Dismiss();
        }

        if (_script.UsesPowerShellInstaller)
        {
            ScriptRunnerService.RunPowerShellInstaller(localPath);
            return CommandResult.Dismiss();
        }

        // Resolve an optional post-configure step (e.g. mac-my-wsl.ps1
        // -Interactive) and chain it in the same wt tab so the user gets
        // one continuous experience instead of a manual follow-up.
        string? postPath = null;
        string? postArgs = null;
        var post = _script.Windows?.PostConfigure;
        if (post != null && !string.IsNullOrEmpty(post.Script))
        {
            try
            {
                postPath = _fetchService.GetScriptPathAsync(post.Script).GetAwaiter().GetResult();
                postArgs = post.Args;
            }
            catch
            {
                // Couldn't fetch the post script — fall back to configure-only.
            }
        }

        ScriptRunnerService.RunWinGetConfig(localPath, postPath, postArgs);
        return CommandResult.Dismiss();
    }
}

internal sealed partial class OpenUrlCommand : InvokableCommand
{
    private readonly string _url;

    public OpenUrlCommand(string url)
    {
        _url = url;
    }

    public override ICommandResult Invoke()
    {
        var psi = new ProcessStartInfo
        {
            FileName = _url,
            UseShellExecute = true,
        };
        Process.Start(psi);
        return CommandResult.Dismiss();
    }
}

internal sealed partial class ViewFileCommand : InvokableCommand
{
    private readonly string _filePath;

    public ViewFileCommand(string filePath)
    {
        _filePath = filePath;
        Name = "View script";
        Icon = new IconInfo("\uE8A7");
    }

    public override ICommandResult Invoke()
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "code",
                Arguments = $"--goto \"{_filePath}\"",
                UseShellExecute = true,
            };
            Process.Start(psi);
        }
        catch
        {
            var psi = new ProcessStartInfo
            {
                FileName = "notepad.exe",
                Arguments = $"\"{_filePath}\"",
                UseShellExecute = false,
            };
            Process.Start(psi);
        }

        return CommandResult.Dismiss();
    }
}
