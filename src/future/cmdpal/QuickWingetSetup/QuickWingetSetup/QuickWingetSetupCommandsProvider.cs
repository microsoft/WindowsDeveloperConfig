// Copyright (c) Microsoft Corporation
// The Microsoft Corporation licenses this file to you under the MIT license.
// See the LICENSE file in the project root for more information.

using Microsoft.CommandPalette.Extensions;
using Microsoft.CommandPalette.Extensions.Toolkit;
using QuickWingetSetup.Models;
using QuickWingetSetup.Services;
using System;
using System.Linq;

namespace QuickWingetSetup;

public partial class QuickWingetSetupCommandsProvider : CommandProvider
{
    private readonly ScriptFetchService _fetchService = new();

    public QuickWingetSetupCommandsProvider()
    {
        DisplayName = "Quick Setup for developer flows";
        Icon = IconHelpers.FromRelativePath("Assets\\StoreLogo.png");

        // Warm the WSL status cache so the first render already shows correct badges
        _ = WslDetectionService.Status;
    }

    public override ICommandItem[] TopLevelCommands()
    {
        return [
            new CommandItem(new QuickWingetSetupPage()) { Title = "Quick Setup: Browse Scripts", Subtitle = "Browse and run WinGet setup scripts" },
        ];
    }

    public override IFallbackCommandItem[]? FallbackCommands()
    {
        return [
            new QuickSetupFallbackItem(_fetchService),
        ];
    }
}

internal sealed partial class QuickSetupFallbackItem : FallbackCommandItem
{
    private readonly ScriptFetchService _fetchService;
    private ScriptEntry[]? _allScripts;

    public QuickSetupFallbackItem(ScriptFetchService fetchService)
        : base("Quick Setup", "quicksetup-fallback")
    {
        _fetchService = fetchService;
        Icon = IconHelpers.FromRelativePath("Assets\\StoreLogo.png");
    }

    public override void UpdateQuery(string query)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            Title = string.Empty;
            Command = null;
            return;
        }

        try
        {
            _allScripts ??= _fetchService.GetManifestAsync(false).GetAwaiter().GetResult()?.Flows;
            if (_allScripts == null)
            {
                Title = string.Empty;
                Command = null;
                return;
            }

            var match = _allScripts
                .Where(s => s.WindowsConfigurationPath is not null ||
                    (_fetchService.CanRunPowerShellNativeFlows && s.WindowsInstallPath is not null))
                .FirstOrDefault(s =>
                    s.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                    s.Description.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                    s.Id.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                    s.Tags.Any(t => t.Contains(query, StringComparison.OrdinalIgnoreCase)));

            if (match != null)
            {
                Title = $"Quick Setup: {match.Name}";
                Subtitle = match.Description;
                Icon = new IconInfo(match.Icon);
                Command = new ScriptDetailPage(match, _fetchService);
            }
            else
            {
                Title = string.Empty;
                Command = null;
            }
        }
        catch
        {
            Title = string.Empty;
            Command = null;
        }
    }
}
