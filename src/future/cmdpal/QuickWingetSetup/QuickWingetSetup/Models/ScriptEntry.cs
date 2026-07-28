using System.Text.Json.Serialization;

namespace QuickWingetSetup.Models;

public class ScriptEntry
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = string.Empty;

    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("description")]
    public string Description { get; set; } = string.Empty;

    [JsonPropertyName("category")]
    public string Category { get; set; } = string.Empty;

    [JsonPropertyName("tags")]
    public string[] Tags { get; set; } = [];

    [JsonPropertyName("os")]
    public string[]? Os { get; set; }

    [JsonPropertyName("windows")]
    public WindowsTarget? Windows { get; set; }

    [JsonPropertyName("linux")]
    public LinuxTarget? Linux { get; set; }

    [JsonPropertyName("icon")]
    public string Icon { get; set; } = "📦";

    [JsonPropertyName("includes")]
    public string[]? Includes { get; set; }

    [JsonPropertyName("onboardingUrl")]
    public string? OnboardingUrl { get; set; }

    /// <summary>
    /// Optional list of flow ids this flow logically depends on. Surfaced
    /// in the list view as a "Requires: &lt;id&gt;" suffix on the entry's
    /// subtitle. Not consumed at runtime today; the extension still
    /// launches each flow independently. Every id should resolve to
    /// another flow's id in the same manifest — no schema validator.
    /// </summary>
    [JsonPropertyName("dependsOn")]
    public string[]? DependsOn { get; set; }

    /// <summary>
    /// When <c>true</c>, this flow depends on WSL being installed with at
    /// least one distro, even if it has no <c>linux</c> block. Set this on
    /// Windows-only flows whose real work happens inside a WSL distro
    /// (e.g. a manual post-install step or a WSL-targeted hello-world).
    /// CmdPal surfaces the same ⚠️ WSL status tag on the Windows item that
    /// it surfaces on Linux items, and diverts the click to
    /// <c>wsl --install</c> when WSL is missing.
    /// </summary>
    [JsonPropertyName("requiresWsl")]
    public bool RequiresWsl { get; set; }

    /// <summary>
    /// Path to the WinGet DSC configuration the extension applies via
    /// <c>winget configure</c>. Falls back to a sibling
    /// <c>configuration.winget</c> next to <c>install</c> when not set.
    /// </summary>
    public string? WindowsConfigurationPath
    {
        get
        {
            if (Windows == null)
            {
                return null;
            }
            if (!string.IsNullOrEmpty(Windows.Configuration))
            {
                return Windows.Configuration;
            }
            if (!string.IsNullOrEmpty(Windows.Install))
            {
                var dir = System.IO.Path.GetDirectoryName(Windows.Install)?.Replace('\\', '/');
                if (!string.IsNullOrEmpty(dir))
                {
                    return $"{dir}/configuration.winget";
                }
            }
            return null;
        }
    }

    public bool UsesPowerShellInstaller =>
        string.Equals(Windows?.Execution, "powershell", System.StringComparison.OrdinalIgnoreCase);

    public string? WindowsLaunchPath =>
        UsesPowerShellInstaller ? Windows?.Install : WindowsConfigurationPath;

    /// <summary>WSL/Linux install script path, e.g. <c>scripts/linux/php/install.sh</c>.</summary>
    public string? LinuxInstallPath => Linux?.Install;
}

public class WindowsTarget
{
    [JsonPropertyName("install")]
    public string? Install { get; set; }

    [JsonPropertyName("execution")]
    public string? Execution { get; set; }

    [JsonPropertyName("payloadFiles")]
    public string[]? PayloadFiles { get; set; }

    [JsonPropertyName("configuration")]
    public string? Configuration { get; set; }

    [JsonPropertyName("build")]
    public string? Build { get; set; }

    [JsonPropertyName("run")]
    public string? Run { get; set; }

    [JsonPropertyName("expected")]
    public string? Expected { get; set; }

    [JsonPropertyName("version")]
    public string? Version { get; set; }

    /// <summary>
    /// Optional PowerShell step that runs in the same Windows Terminal tab
    /// after <c>winget configure</c> succeeds. Use when a flow's DSC
    /// installs the machine-side prerequisites but the real setup is an
    /// interactive script (e.g. <c>mac-my-wsl.ps1 -Interactive</c>). The
    /// script path is repo-relative; args are appended verbatim.
    /// </summary>
    [JsonPropertyName("postConfigure")]
    public PostConfigureStep? PostConfigure { get; set; }
}

public class PostConfigureStep
{
    /// <summary>Repo-relative path to a .ps1 to invoke after the configure succeeds.</summary>
    [JsonPropertyName("script")]
    public string? Script { get; set; }

    /// <summary>Arguments appended after the script path (e.g. <c>-Interactive</c>).</summary>
    [JsonPropertyName("args")]
    public string? Args { get; set; }
}

public class LinuxTarget
{
    [JsonPropertyName("install")]
    public string? Install { get; set; }

    [JsonPropertyName("build")]
    public string? Build { get; set; }

    [JsonPropertyName("run")]
    public string? Run { get; set; }

    [JsonPropertyName("expected")]
    public string? Expected { get; set; }

    [JsonPropertyName("version")]
    public string? Version { get; set; }
}
