# QuickWingetSetup — Command Palette extension

A [PowerToys Command Palette](https://learn.microsoft.com/windows/powertoys/command-palette/overview)
extension that surfaces the developer flows defined in this repo's
[`manifest.yml`](../../manifest.yml). Pick a flow, hit Enter, and the extension
launches `winget configure` (Windows) or `wsl bash` (Linux) in a new Windows
Terminal tab — no need to remember which `.winget` file goes with which
toolchain.

## Prerequisite: `winget configure` must be enabled

This extension launches flows exclusively through `winget configure`. If
that subcommand is not wired up on the host, no Windows flow surfaced by
CmdPal can succeed. See the developer guide's
[`Prerequisites (Windows)`](../../docs/development.md#prerequisites-windows)
section for the three conditions that must hold (current App Installer, the
`configuration` feature enabled, and no blocking ADMX policy) and the
one-line smoke test. The shared preflight
[`Workloads/_common/assert-winget-configure.ps1`](../../Workloads/_common/assert-winget-configure.ps1)
enforces this at runtime with an actionable error message.

## Source of truth

The extension reads the same `manifest.yml` that drives CI. Each flow's UX
metadata (`name`, `description`, `category`, `tags`, `icon`, `onboardingUrl`,
`dependsOn`) plus its `windows.configuration` / `linux.install` paths come
straight from that file — adding a flow there makes it appear in CmdPal
automatically.

## Categories and ordering

The list view groups by `category`, with this priority order:

| Rank | Category          | Notes                                                 |
| ---- | ----------------- | ----------------------------------------------------- |
| 0    | `essentials`      | Reserved for "you almost certainly want this" flows.  |
| 1    | `languages`       | Language toolchains (typescript, python, dotnet, ...).|
| 2    | `desktop`         | Desktop frameworks on top of a language (winforms, winui). |
| 3    | (other / default) | Any unrecognized category sorts here.                 |
| 4    | `user-experience` | OS-feel flows (windows-dev-config, comfort-shell). |
| 4    | `shell`           | Legacy alias for `user-experience`. New flows should pick `user-experience`. |

Within a rank, flows sort alphabetically by category then by name.

## `dependsOn`

If a flow declares `dependsOn: [<id>, ...]` in `manifest.yml`, the list
entry's subtitle gets a `· Requires: <id>` suffix. This is purely an
informational hint today — the extension still launches the chosen flow
independently. (Future: we may chain installs in the same Terminal tab.)

## Configuration

The extension keeps an optional config at
`%LocalAppData%\QuickWingetSetup\config.json`. Defaults are sane for a local
clone of this repo:

```jsonc
{
  // "local" reads from disk, "github" fetches via raw.githubusercontent.com.
  "source": "local",
  "localPath": "C:\\Users\\crutkas\\WindowsDevSetupScripts",
  "githubRepo": "crutkas/WindowsDevSetupScripts",
  "githubBranch": "master",
  "manifestFile": "manifest.yml",
  "cacheTTLDays": 7
}
```

While `WindowsDevSetupScripts` is private, keep `source: "local"`. Once the
repo is public, switch to `"github"` to pull straight from
`raw.githubusercontent.com` with no clone required.

## Building

```powershell
cd cmdpal/QuickWingetSetup
dotnet restore .\QuickWingetSetup\QuickWingetSetup.csproj -r win-x64
dotnet build   .\QuickWingetSetup\QuickWingetSetup.csproj -c Debug -r win-x64
```

For a self-contained MSIX-ready Release build:

```powershell
dotnet publish .\QuickWingetSetup\QuickWingetSetup.csproj -c Release -r win-x64 -p:Platform=x64
```

The project targets `net9.0-windows10.0.26100.0` and is AOT/trim friendly.

## How execution maps to the manifest

| Manifest field                      | What the extension does                                     |
| ----------------------------------- | ----------------------------------------------------------- |
| `windows.configuration`             | `winget configure <path>` in a new Windows Terminal tab, after a confirmation dialog |
| `onboardingUrl`                     | Opens in the default browser via `📖 Official Docs` action  |
| `icon`, `name`, `description`, ...  | Rendered on the list/detail pages                           |

If `windows.configuration` is omitted in `manifest.yml`, the extension falls
back to `<dir of windows.install>/configuration.winget` — i.e. the
WindowsDevSetupScripts convention.

## Confirmation dialog

`winget configure` against a real DSC config can install packages, change
registry values, disable services, and so on — not the kind of thing we
want to launch on a stray Enter key. So `🪟 Run Windows Setup` is a
[`ConfirmableCommand`](https://learn.microsoft.com/windows/powertoys/command-palette/overview):
selecting it pops a confirmation dialog with the script path and a short
note that the flows are idempotent. Confirm to launch the wt.exe tab;
cancel to back out.

## Windows-only scope

This extension is Windows-only today. Flows whose `manifest.yml` entry
omits a `windows.*` block (e.g. a hypothetical Linux-only flow) are
filtered out of the list. The `linux.install` field is parsed and stored
on `ScriptEntry.Linux` for future use, but no `🐧 Run WSL Setup` action is
rendered.
