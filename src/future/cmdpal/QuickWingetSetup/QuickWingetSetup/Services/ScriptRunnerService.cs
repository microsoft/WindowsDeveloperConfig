using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace QuickWingetSetup.Services;

public static class ScriptRunnerService
{
    public static void RunPowerShellInstaller(string scriptPath)
    {
        if (!File.Exists(scriptPath))
        {
            throw new FileNotFoundException("PowerShell installer not found.", scriptPath);
        }

        var signatureCommand = "$signature=Get-AuthenticodeSignature -LiteralPath '"
            + EscapeSingleQuotes(scriptPath)
            + "'; if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation'){"
            + "throw \"Invalid Microsoft signature: $($signature.Status) $($signature.SignerCertificate.Subject)\"}; ";
        var sanitizedPath = scriptPath.Replace("\"", "");
        var command = "$ErrorActionPreference='Stop'; "
            + signatureCommand
            + "& '"
            + EscapeSingleQuotes(sanitizedPath)
            + "'";
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(command));
        var shell = ResolveShell();
        var psi = new ProcessStartInfo
        {
            FileName = "wt.exe",
            Arguments = $"new-tab -- \"{shell}\" -NoExit -NoProfile -ExecutionPolicy AllSigned -EncodedCommand {encoded}",
            UseShellExecute = true,
        };
        var process = Process.Start(psi);
        if (process == null)
        {
            throw new InvalidOperationException("Failed to launch Windows Terminal. Ensure wt.exe is available.");
        }
    }

    public static void RunWinGetConfig(string scriptPath)
    {
        RunWinGetConfig(scriptPath, postConfigureScriptPath: null, postConfigureArgs: null);
    }

    /// <summary>
    /// Runs <c>winget configure</c> in a new Windows Terminal tab, then —
    /// if the configure succeeds and <paramref name="postConfigureScriptPath"/>
    /// is set — chains into the given PowerShell script in the same tab
    /// so the user sees one continuous output stream and can interact
    /// with the follow-up script if it prompts.
    /// </summary>
    public static void RunWinGetConfig(string scriptPath, string? postConfigureScriptPath, string? postConfigureArgs)
    {
        var sanitizedPath = scriptPath.Replace("\"", "");

        // Single-quote the configure path for pwsh; safe because we stripped
        // embedded double-quotes, and path single-quotes are escaped below.
        var sbCmd = new StringBuilder();
        sbCmd.Append("$ErrorActionPreference='Continue'; ");
        sbCmd.Append("winget configure --file '").Append(EscapeSingleQuotes(sanitizedPath))
             .Append("' --accept-configuration-agreements --disable-interactivity; ");

        if (!string.IsNullOrEmpty(postConfigureScriptPath) && File.Exists(postConfigureScriptPath))
        {
            var postSanitized = postConfigureScriptPath.Replace("\"", "");
            var postDir = Path.GetDirectoryName(postSanitized) ?? string.Empty;
            var argsLiteral = string.IsNullOrWhiteSpace(postConfigureArgs) ? string.Empty : " " + postConfigureArgs;

            sbCmd.Append("if ($LASTEXITCODE -ne 0) { ")
                 .Append("Write-Host ''; ")
                 .Append("Write-Host 'winget configure failed (exit ' $LASTEXITCODE '); skipping post-configure step.' -ForegroundColor Red; ")
                 .Append("return }; ");
            sbCmd.Append("Write-Host ''; ")
                 .Append("Write-Host '--- winget configure succeeded. Running post-configure step... ---' -ForegroundColor Cyan; ")
                 .Append("Write-Host ''; ");
            sbCmd.Append("Push-Location '").Append(EscapeSingleQuotes(postDir)).Append("'; ");
            sbCmd.Append("try { & '").Append(EscapeSingleQuotes(postSanitized)).Append('\'')
                 .Append(argsLiteral)
                 .Append(" } finally { Pop-Location }");
        }

        // -EncodedCommand sidesteps wt.exe's own command-line parsing of
        // semicolons (which it would otherwise split into panes) and any
        // ambiguity around quoting. Base64 is UTF-16LE per pwsh contract.
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(sbCmd.ToString()));
        var shell = ResolveShell();
        var noExit = !string.IsNullOrEmpty(postConfigureScriptPath) ? "-NoExit " : string.Empty;

        var psi = new ProcessStartInfo
        {
            FileName = "wt.exe",
            Arguments = $"new-tab -- {shell} {noExit}-NoProfile -ExecutionPolicy Bypass -EncodedCommand {encoded}",
            UseShellExecute = true,
        };
        var process = Process.Start(psi);
        if (process == null)
        {
            throw new InvalidOperationException("Failed to launch Windows Terminal. Ensure wt.exe is available.");
        }
    }

    private static string EscapeSingleQuotes(string value) => value.Replace("'", "''");

    public static void RunWslScript(string scriptPath)
    {
        var sanitizedPath = scriptPath.Replace("\"", "");
        var psi = new ProcessStartInfo
        {
            FileName = "wt.exe",
            Arguments = $"new-tab -- wsl.exe -e bash \"{sanitizedPath}\"",
            UseShellExecute = true,
        };
        var process = Process.Start(psi);
        if (process == null)
        {
            throw new InvalidOperationException("Failed to launch Windows Terminal. Ensure wt.exe is available.");
        }
    }

    /// <summary>
    /// Launches <c>wsl --install</c> in a new Windows Terminal tab so the
    /// user can follow the interactive installation progress.
    /// </summary>
    public static void RunWslInstall()
    {
        var psi = new ProcessStartInfo
        {
            FileName = "wt.exe",
            Arguments = "new-tab -- wsl --install",
            UseShellExecute = true,
        };
        var process = Process.Start(psi);
        if (process == null)
        {
            throw new InvalidOperationException("Failed to launch Windows Terminal. Ensure wt.exe is available.");
        }
    }

    /// <summary>
    /// Launches the remediation script (<c>enable-winget-configure.ps1</c>)
    /// in an elevated PowerShell window. Runs `winget configure --enable`,
    /// installs the VCRedist dependency, and re-verifies before exiting.
    /// All remediation logic lives in the PS1 so any future change — e.g.
    /// dropping VCRedist — happens in one place and is picked up by CmdPal
    /// automatically.
    ///
    /// Goes straight to UAC-elevated pwsh (not via <c>wt.exe</c>) so the
    /// user sees exactly one UAC prompt and one window.
    /// </summary>
    /// <param name="fixItScriptPath">Absolute path to
    /// <c>scripts\windows\_common\enable-winget-configure.ps1</c>.</param>
    public static void RunEnableWingetConfigure(string fixItScriptPath)
    {
        if (!File.Exists(fixItScriptPath))
        {
            throw new FileNotFoundException(
                $"Remediation script not found: {fixItScriptPath}. " +
                "Check cmdpal config.json `localPath` points at your WindowsDevSetupScripts clone.",
                fixItScriptPath);
        }

        var sanitizedPath = fixItScriptPath.Replace("\"", "");
        var shell = ResolveShell();

        // -NoElevate tells the script not to self-elevate — we've already
        // handled elevation via Verb=runas below, so a re-elevation loop
        // would just churn UAC.
        //
        // -FromRelaunch tells the script this is a fresh window (UAC
        // spawned its own console), so it should pause at the end to let
        // the user read the output before the window disappears.
        var psi = new ProcessStartInfo
        {
            FileName = shell,
            Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{sanitizedPath}\" -NoElevate -FromRelaunch",
            UseShellExecute = true,
            Verb = "runas",
        };

        try
        {
            var process = Process.Start(psi);
            if (process == null)
            {
                throw new InvalidOperationException("Failed to launch remediation script.");
            }
        }
        catch (System.ComponentModel.Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            // User declined the UAC prompt. Not an error — they chose not
            // to proceed. Swallow so the caller can keep the UI open.
        }
    }

    /// <summary>
    /// Returns the path (or plain name) of the PowerShell we should launch.
    /// Prefers the winget-installed pwsh 7 MSI at
    /// <c>C:\Program Files\PowerShell\7\pwsh.exe</c>, then the x86 variant,
    /// and falls back to <c>powershell.exe</c> (Windows PowerShell 5.1).
    ///
    /// We deliberately do NOT use <c>where.exe pwsh.exe</c> / bare
    /// <c>pwsh.exe</c> because the Windows App Execution Alias stub at
    /// <c>%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe</c> is a 0-byte
    /// reparse point that usually wins PATH resolution and may not launch
    /// the winget-installed runtime at all.
    /// </summary>
    private static string ResolveShell()
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        foreach (var root in new[] { programFiles, programFilesX86 })
        {
            if (string.IsNullOrEmpty(root)) continue;
            var candidate = Path.Combine(root, "PowerShell", "7", "pwsh.exe");
            if (File.Exists(candidate)) return candidate;
        }
        return "powershell.exe";
    }

}
