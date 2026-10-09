# Workloads

Don't need the whole dev box? Workloads set up one toolchain at a time. They're idempotent, so re-running is safe.

← Back to [Windows Dev Config](../src/windows-dev-config/README.md) · Looking for AI? See [AI tooling workloads](./ai-workloads.md).

## One-liners

Run from any PowerShell window. Each one elevates, verifies signatures, and installs — nothing to clone first.

| Workload | Installs | Run |
| --- | --- | --- |
| WinUI 3 | Developer Mode, PowerShell 7, .NET SDK 10, Windows App CLI, Visual Studio Community 2026 with the .NET desktop and WinUI workloads, and the WinUI `dotnet new` templates | `irm https://aka.ms/devconfig/winui/setup.ps1 \| iex` |
| WinForms | Developer Mode, PowerShell 7, .NET SDK 10, and Visual Studio Community 2026 with the .NET desktop workload | `irm https://aka.ms/devconfig/winforms/setup.ps1 \| iex` |
| WinAppCLI | Developer Mode, PowerShell 7, .NET SDK 10, and the Windows App Development CLI | `irm https://aka.ms/devconfig/winappcli/setup.ps1 \| iex` |
| .NET | Developer Mode, PowerShell 7, and .NET SDK 10 | `irm https://aka.ms/devconfig/dotnet/setup.ps1 \| iex` |
| Go | PowerShell 7 and Go | `irm https://aka.ms/devconfig/go/setup.ps1 \| iex` |
| Rust | PowerShell 7, rustup, the stable toolchain, and Visual Studio Community 2026 C++ workload (for the MSVC linker) | `irm https://aka.ms/devconfig/rust/setup.ps1 \| iex` |
| PHP | PowerShell 7 and PHP | `irm https://aka.ms/devconfig/php/setup.ps1 \| iex` |

These use the same engine as [Windows Dev Config](../src/windows-dev-config/README.md#single-workloads): same elevation, signature checks, logging, and summary. Close Visual Studio before running WinUI, WinForms, or Rust — if the VS Installer wants a restart, the summary will say so.

## From a clone

These run with [`winget configure`](https://learn.microsoft.com/windows/package-manager/winget/configure) from the repo root:

| Workload | Installs |
| --- | --- |
| TypeScript | Node.js LTS + global `typescript` |
| Java | Microsoft Build of OpenJDK 25 LTS |
| Python | Python 3.14 + uv |
| SQL | SQL Server + sqlcmd + VS Code extension |
| PowerShell | PowerShell 7 + VS Code PowerShell extension + PSScriptAnalyzer settings |

```powershell
winget configure -f .\Workloads\<name>\configuration.winget --accept-configuration-agreements --disable-interactivity
```

Swap `<name>` for `typescript`, `java`, `python`, `sql`, or `powershell`.

If `winget configure` isn't recognized, see [Troubleshooting](../README.md#-troubleshooting).

## AI tooling

Local AI dev setup, PyTorch, CUDA, ROCm, Intel AI, llama.cpp, Ollama, and Foundry Local all have their own page: [AI tooling workloads](./ai-workloads.md).
