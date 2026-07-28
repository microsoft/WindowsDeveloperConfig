// Copyright (c) Microsoft Corporation
// The Microsoft Corporation licenses this file to you under the MIT license.
// See the LICENSE file in the project root for more information.

using Microsoft.CommandPalette.Extensions;
using Microsoft.CommandPalette.Extensions.Toolkit;
using QuickWingetSetup.Models;
using QuickWingetSetup.Services;
using System;
using System.Collections.Generic;
using System.Linq;

namespace QuickWingetSetup;

internal sealed partial class QuickWingetSetupPage : ListPage
{
    private readonly ScriptFetchService _fetchService = new();

    public QuickWingetSetupPage()
    {
        Icon = IconHelpers.FromRelativePath("Assets\\StoreLogo.png");
        Title = "Quick Setup for developer flows";
        Name = "Open";
    }

    public void RefreshItems()
    {
        var items = GetItems();
        RaiseItemsChanged(items.Length);
    }

    public override IListItem[] GetItems()
    {
        try
        {
            var manifest = _fetchService.GetManifestAsync(false).GetAwaiter().GetResult();
            if (manifest == null || manifest.Flows.Length == 0)
            {
                return [
                    new ListItem(new NoOpCommand()) { Title = "❌ No flows found", Subtitle = "Check config — is localPath correct?" }
                ];
            }

            // Re-check winget configure health every time the list renders,
            // so the banner auto-clears after the user runs the remediation.
            var health = WingetConfigureHealthService.RefreshStatus();

            var items = new List<IListItem>();
            // DSC workloads need `winget configure`; direct PowerShell
            // installers such as Calm OS can still run without it.
            if (health != WingetConfigureStatus.Available)
            {
                items.Add(new ListItem(new EnableWingetConfigureCommand(_fetchService, this))
                {
                    Title = "⚠️ DSC workloads are unavailable",
                    Subtitle = WingetConfigureHealthService.DescribeStatus(health)
                        + "  ·  Select to fix (elevates).",
                    Tags = [new Tag("blocker")],
                });
            }

            items.AddRange(manifest.Flows
                // CmdPal is Windows-only today. Hide flows without either a
                // DSC configuration or a direct PowerShell installer.
                .Where(s => s.WindowsLaunchPath is not null)
                .OrderBy(s => CategoryRank(s.Category))
                .ThenBy(s => s.Category)
                .ThenBy(s => s.Name)
                .Select(s => (IListItem)new ListItem(new ScriptDetailPage(s, _fetchService))
                {
                    Title = s.Name,
                    Icon = new IconInfo(s.Icon),
                    Subtitle = BuildSubtitle(s),
                    Tags = [new Tag(s.Category)],
                }));

            items.Add(new ListItem(new RefreshCacheCommand(_fetchService, this))
            {
                Title = "🔄 Refresh Cache",
                Subtitle = "Clear cache and reload scripts from source",
                Tags = [new Tag("tools")],
            });

            return items.ToArray();
        }
        catch (Exception ex)
        {
            return [
                new ListItem(new NoOpCommand()) { Title = "❌ Error loading scripts", Subtitle = ex.Message }
            ];
        }
    }

    /// <summary>
    /// Sort priority for the list view. Lower comes first. The categories
    /// match the recommended set documented in <c>manifest.yml</c>'s
    /// schema header. Anything not in the explicit set falls into the
    /// generic middle bucket. <c>user-experience</c> and the legacy
    /// <c>shell</c> alias sink to the bottom because they are not dev
    /// toolchains and the goal of the list is dev onboarding.
    /// </summary>
    private static int CategoryRank(string category) => category switch
    {
        "essentials" => 0,
        "languages" => 1,
        "desktop" => 2,
        "user-experience" => 4,
        "shell" => 4,
        _ => 3,
    };

    /// <summary>
    /// Builds the subtitle for a flow's list entry. Today: the
    /// description plus, if any, a "Requires: a, b" suffix derived from
    /// <c>dependsOn</c>. Future: this is the seam to add other inline
    /// hints (e.g. estimated install time) without touching the sort.
    /// </summary>
    private static string BuildSubtitle(ScriptEntry s)
    {
        if (s.DependsOn is { Length: > 0 } deps)
        {
            return $"{s.Description}  ·  Requires: {string.Join(", ", deps)}";
        }
        return s.Description;
    }
}

/// <summary>
/// Launches the `enable-winget-configure.ps1` remediation script and then
/// asks the host page to refresh so the banner clears on success.
/// </summary>
internal sealed partial class EnableWingetConfigureCommand : InvokableCommand
{
    private const string FixItRelativePath = "scripts/windows/_common/enable-winget-configure.ps1";

    private readonly ScriptFetchService _fetchService;
    private readonly QuickWingetSetupPage _page;

    public EnableWingetConfigureCommand(ScriptFetchService fetchService, QuickWingetSetupPage page)
    {
        _fetchService = fetchService;
        _page = page;
        Name = "Fix";
    }

    public override ICommandResult Invoke()
    {
        try
        {
            var scriptPath = _fetchService.GetScriptPathAsync(FixItRelativePath).GetAwaiter().GetResult();
            if (string.IsNullOrEmpty(scriptPath))
            {
                return CommandResult.KeepOpen();
            }

            ScriptRunnerService.RunEnableWingetConfigure(scriptPath);
        }
        catch
        {
            // Surfacing a toast would be nicer; for now, swallow so the
            // list stays interactive. Users can re-run the command.
        }

        // Don't force-refresh immediately — the elevated script is still
        // running in another window. Next time the user navigates into
        // the list, GetItems() re-runs RefreshStatus and the banner
        // clears automatically.
        return CommandResult.KeepOpen();
    }
}

internal sealed partial class NoOpCommand : InvokableCommand
{
    public override ICommandResult Invoke() => CommandResult.KeepOpen();
}
