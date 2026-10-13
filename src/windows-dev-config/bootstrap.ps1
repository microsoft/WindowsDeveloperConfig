<#
.SYNOPSIS
  Fetches the Calm OS developer workstation setup and starts it.

.DESCRIPTION
  Run from the web:

      irm https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1 | iex

  Elevates, verifies Microsoft signatures, and installs the repository-root release
  under %ProgramData%\CalmOS with Administrator/SYSTEM write access.
  Files stay on disk for helper loading and reboot resume.
  Production requests process-scoped RemoteSigned. -AllowUnsigned uses src/ without
  signature checks or execution-policy changes.

  To select a branch, tag, or full 40-character commit SHA:

      & ([scriptblock]::Create((irm <url>))) -Ref 'v1.2.3'

  To apply one workload from workloads\ instead of the full Windows Dev Config setup:

      & ([scriptblock]::Create((irm <url>))) -Workload winui

  To run only the machine part (as SYSTEM or an administrator) or only the user part (as the
  signed-in user, never elevated) of the standard setup, for example from Windows Setup and
  first sign-in:

      & ([scriptblock]::Create((irm <url>))) -Action Partial -Scope Machine
      & ([scriptblock]::Create((irm <url>))) -Action Partial -Scope User

  To run a standalone AI installer with its verified dependencies:

      & ([scriptblock]::Create((irm <url>))) -Scenario cuda
#>

[CmdletBinding()]
param(
    [string] $Ref = 'main',
    [string] $InstallRoot,
    [switch] $AllowUnsigned,
    [switch] $NoLaunch,
    [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
    [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig',
    [ValidateSet('All', 'Machine', 'User')] [string] $Scope = 'All',
    [ValidateSet('', 'local-ai', 'pytorch', 'cuda', 'rocm', 'intel-ai', 'llama.cpp', 'ollama', 'foundry')] [string] $Scenario = '',
    [ValidateSet('Auto', 'CPU', 'CUDA', 'ROCm', 'XPU')] [string] $AiBackend = 'Auto',
    [ValidateSet('None', 'LlamaCpp', 'Ollama', 'Foundry')] [string] $AiRuntime = 'None',
    [switch] $RequireTriton,
    [switch] $PlanOnly,
    [string] $ReportRoot
)

function Invoke-CalmOsBootstrap {
    [CmdletBinding()]
    param(
        [string] $Ref = 'main',
        [string] $InstallRoot,
        [switch] $AllowUnsigned,
        [switch] $NoLaunch,
        [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
        [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig',
        [ValidateSet('All', 'Machine', 'User')] [string] $Scope = 'All',
        [ValidateSet('', 'local-ai', 'pytorch', 'cuda', 'rocm', 'intel-ai', 'llama.cpp', 'ollama', 'foundry')] [string] $Scenario = '',
        [ValidateSet('Auto', 'CPU', 'CUDA', 'ROCm', 'XPU')] [string] $AiBackend = 'Auto',
        [ValidateSet('None', 'LlamaCpp', 'Ollama', 'Foundry')] [string] $AiRuntime = 'None',
        [switch] $RequireTriton,
        [switch] $PlanOnly,
        [string] $ReportRoot
    )

    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    # A child shell can inherit incompatible built-in modules from another PowerShell edition.
    $env:PSModulePath = "$PSHOME\Modules;$env:PSModulePath"

    # Keep this helper identical to steps/_retry.ps1; bootstrap must work on its own.
    function Invoke-DevConfigWebRequest {
        param(
            [Parameter(Mandatory)] [hashtable] $Parameters
        )

        $waited = 0.0
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            try {
                return Invoke-WebRequest @Parameters -UseBasicParsing -ErrorAction Stop
            } catch {
                $response = $null
                $networkFailure = $false
                for ($exception = $_.Exception; $null -ne $exception; $exception = $exception.InnerException) {
                    if ($exception -is [Security.Authentication.AuthenticationException]) { throw }
                    if ($exception.PSObject.Properties['Response'] -and $null -ne $exception.Response) {
                        $response = $exception.Response
                    }
                    if ($exception -is [Net.WebException]) {
                        $networkFailure = $exception.Status.ToString() -in @(
                            'Timeout', 'ConnectFailure', 'ConnectionClosed', 'KeepAliveFailure',
                            'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ReceiveFailure', 'SendFailure'
                        )
                    } elseif ($exception.GetType().FullName -in @(
                        'System.Net.Http.HttpRequestException', 'System.Net.Http.HttpIOException',
                        'System.Threading.Tasks.TaskCanceledException', 'System.TimeoutException'
                    )) {
                        $networkFailure = $true
                    }
                }
                $status = if ($null -ne $response) { [int]$response.StatusCode } else { 0 }
                if ($attempt -eq 4 -or
                    ($status -ne 0 -and $status -notin @(408, 429, 500, 502, 503, 504)) -or
                    ($status -eq 0 -and -not $networkFailure)) {
                    throw
                }

                $retryAfter = $null
                if ($null -ne $response) {
                    if ($response.Headers -is [Net.WebHeaderCollection]) {
                        $retryAfter = $response.Headers['Retry-After']
                    } elseif ($response.Headers.Contains('Retry-After')) {
                        $retryAfter = @($response.Headers.GetValues('Retry-After'))[0]
                    }
                }
                $serverDelay = 0.0
                $date = [DateTimeOffset]::MinValue
                if ($retryAfter -match '^\d+$') {
                    if (-not [double]::TryParse($retryAfter, [Globalization.NumberStyles]::None,
                            [Globalization.CultureInfo]::InvariantCulture, [ref]$serverDelay)) { throw }
                } elseif ($retryAfter -and [DateTimeOffset]::TryParse($retryAfter,
                        [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)) {
                    $serverDelay = [Math]::Max(0, [Math]::Ceiling(($date - [DateTimeOffset]::UtcNow).TotalSeconds))
                } elseif ($retryAfter) {
                    Write-Verbose 'Ignoring an invalid Retry-After header.'
                }

                $backoff = 5 * [Math]::Pow(2, $attempt - 1)
                $delay = [Math]::Max($backoff, $serverDelay)
                $remaining = 120 - $waited
                if ($delay -gt $remaining) {
                    Write-Host '  Download retry wait exceeds the remaining two-minute budget.' -ForegroundColor DarkYellow
                    throw
                }
                $jitterMilliseconds = [int][Math]::Floor([Math]::Min($backoff, $remaining - $delay) * 1000)
                $milliseconds = [int]($delay * 1000) + (Get-Random -Minimum 0 -Maximum ($jitterMilliseconds + 1))
                Write-Host "  Download attempt $attempt failed; retrying in $([Math]::Round($milliseconds / 1000, 1))s." -ForegroundColor DarkYellow
                Start-Sleep -Milliseconds $milliseconds
                $waited += $milliseconds / 1000
            }
        }
    }

    # Keep this helper identical to steps/_pwsh-bootstrap.ps1; bootstrap must work on its own.
    function Get-DevConfigPwshExe {
        if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion.Major -ge 7) {
            $candidate = Join-Path $PSHOME 'pwsh.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }

        foreach ($root in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if (-not $root) { continue }
            $candidate = Join-Path $root 'PowerShell\7\pwsh.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }

        foreach ($command in @(Get-Command 'pwsh.exe' -CommandType Application -All -ErrorAction SilentlyContinue)) {
            # App execution aliases have no executable version; resolve their package below.
            if ($command.Version -and $command.Version.Major -ge 7 -and
                (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
                return $command.Source
            }
        }

        if (Get-Command 'Get-AppxPackage' -ErrorAction SilentlyContinue) {
            foreach ($package in @(Get-AppxPackage -Name Microsoft.PowerShell -ErrorAction Stop |
                Sort-Object { [version]$_.Version } -Descending)) {
                if (-not $package.InstallLocation -or ([version]$package.Version).Major -lt 7) { continue }
                $candidate = Join-Path $package.InstallLocation 'pwsh.exe'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
            }
        }

        return $null
    }

    $repo = 'microsoft/WindowsDeveloperConfig'
    $microsoftSignerSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    $Workload = $Workload.ToLowerInvariant()
    # The default workload is omitted from command lines so refs that predate workloads still accept them.
    $workloadSuffix = if ($Workload -ne 'devconfig') { " -Workload $Workload" } else { '' }

    $scenarioOptionNames = @('AiBackend', 'AiRuntime', 'RequireTriton', 'PlanOnly', 'ReportRoot')
    if (-not $Scenario -and @($scenarioOptionNames | Where-Object { $PSBoundParameters.ContainsKey($_) }).Count -gt 0) {
        throw 'AI backend/runtime/report options require -Scenario with a supported AI workload.'
    }
    if ($Scenario -and $PSBoundParameters.ContainsKey('Action')) {
        throw '-Action configures the full workstation and cannot be combined with -Scenario.'
    }
    if ($Scenario -and $Workload -ne 'devconfig') {
        throw '-Workload cannot be combined with -Scenario.'
    }
    if ($Scenario -and $Scenario -ne 'local-ai' -and $AiRuntime -ne 'None') {
        throw '-AiRuntime requires -Scenario local-ai.'
    }
    if ($Scenario -and $Scenario -notin @('local-ai', 'pytorch') -and ($AiBackend -ne 'Auto' -or $RequireTriton)) {
        throw '-AiBackend and -RequireTriton require -Scenario local-ai or pytorch.'
    }
    if ($Scope -ne 'All' -and ($Scenario -or $Workload -ne 'devconfig' -or $Action -ne 'Partial')) {
        throw '-Scope Machine and -Scope User apply only to the standard Windows Dev Config setup (-Action Partial).'
    }

    # Reject refs that could escape the repository path.
    if ($Ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $Ref.Contains('..')) {
        throw "'$Ref' is not a valid branch, tag or commit name. Use letters, digits, and . _ - / only."
    }

    if (-not $InstallRoot) {
        $defaultInstallDirectory = if ($Scenario -and $AllowUnsigned) {
            'CalmOS-Development'
        } else {
            'CalmOS'
        }
        $InstallRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) $defaultInstallDirectory
        if ($Scope -eq 'User') {
            # The user part never elevates, so it installs where the signed-in user can write.
            $InstallRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CalmOS\devconfig-user'
        }
    }
    $InstallRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallRoot)
    if ($InstallRoot -notmatch '^[A-Za-z]:\\[^:]+$') {
        throw '-InstallRoot must be a local directory, not a drive root or network path.'
    }
    if ($ReportRoot) {
        $ReportRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportRoot)
    }

    foreach ($policyScope in @('MachinePolicy', 'UserPolicy')) {
        $policy = Get-ExecutionPolicy -Scope $policyScope
        if ($policy -ne 'Undefined') {
            if ($policy -eq 'Restricted') {
                throw "Organization policy ($policyScope) requires $policy. Script execution is disabled; contact your administrator."
            }
            break
        }
    }

    $shell = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    if ($Action -ne 'Uninstall') {
        $pwsh = $null
        try {
            $pwsh = Get-DevConfigPwshExe
        } catch {
            # SYSTEM can lack an AppX profile; the machine part then starts in Windows PowerShell.
            if ($Scope -eq 'All') { throw }
            Write-Verbose "Could not look for PowerShell 7: $($_.Exception.Message)"
        }
        if ($pwsh) { $shell = $pwsh }
    }
    $escapedShell = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($shell)
    $arguments = @('-NoProfile')
    if (-not $AllowUnsigned) { $arguments += '-ExecutionPolicy', 'RemoteSigned' }

    function Get-CalmOsElevationCommand {
        param(
            [Parameter(Mandatory)] [string] $Ref,
            [Parameter(Mandatory)] [string] $InstallRoot,
            [switch] $AllowUnsigned,
            [switch] $NoLaunch,
            [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
            [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig',
            [ValidateSet('', 'local-ai', 'pytorch', 'cuda', 'rocm', 'intel-ai', 'llama.cpp', 'ollama', 'foundry')] [string] $Scenario = '',
            [ValidateSet('Auto', 'CPU', 'CUDA', 'ROCm', 'XPU')] [string] $AiBackend = 'Auto',
            [ValidateSet('None', 'LlamaCpp', 'Ollama', 'Foundry')] [string] $AiRuntime = 'None',
            [switch] $RequireTriton,
            [switch] $PlanOnly,
            [string] $ReportRoot,
            [string] $ElevationErrorPath
        )

        $launcher = {
            param(
                [string] $Ref,
                [string] $InstallRoot,
                [switch] $AllowUnsigned,
                [switch] $NoLaunch,
                [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
                [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig',
                [ValidateSet('', 'local-ai', 'pytorch', 'cuda', 'rocm', 'intel-ai', 'llama.cpp', 'ollama', 'foundry')] [string] $Scenario = '',
                [ValidateSet('Auto', 'CPU', 'CUDA', 'ROCm', 'XPU')] [string] $AiBackend = 'Auto',
                [ValidateSet('None', 'LlamaCpp', 'Ollama', 'Foundry')] [string] $AiRuntime = 'None',
                [switch] $RequireTriton,
                [switch] $PlanOnly,
                [string] $ReportRoot,
                [string] $ElevationErrorPath
            )

            $ErrorActionPreference = 'Stop'
            Set-StrictMode -Version Latest
            # A child shell can inherit incompatible built-in modules from another PowerShell edition.
            $env:PSModulePath = "$PSHOME\Modules;$env:PSModulePath"
            trap {
                if (-not $Scenario) { break }
                try {
                    [IO.File]::WriteAllText(
                        $ElevationErrorPath,
                        ($_ | Out-String),
                        [Text.UTF8Encoding]::new($false))
                } catch {
                    Write-Warning "Could not save scenario diagnostics: $($_.Exception.Message)"
                }
                exit 1
            }
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $flow = if ($AllowUnsigned) { 'src/windows-dev-config' } else { 'windows-dev-config' }
            $baseUri = "https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/$Ref/$flow"
            $securityCode = (Invoke-DevConfigWebRequest -Parameters @{
                Uri = "$baseUri/steps/_security.ps1"; TimeoutSec = 60
            }).Content.TrimStart([char]0xFEFF)
            if (-not $AllowUnsigned) {
                $signature = Get-AuthenticodeSignature -Content ([Text.Encoding]::Unicode.GetBytes($securityCode)) -SourcePathOrExtension '.ps1'
                if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
                    $signature.SignerCertificate.Subject -ne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') {
                    throw 'The setup security helper failed Microsoft signature verification. Setup was not started.'
                }
            }
            . ([scriptblock]::Create($securityCode))

            $work = New-DevConfigProtectedDirectory -Path (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ("CalmOS-bootstrap-" + [guid]::NewGuid().ToString('N')))
            try {
                $bootstrap = Join-Path $work 'bootstrap.ps1'
                Invoke-DevConfigWebRequest -Parameters @{
                    Uri = "$baseUri/bootstrap.ps1"; OutFile = $bootstrap; TimeoutSec = 60
                }
                Assert-DevConfigProtectedTree -Directory $work
                if (-not $AllowUnsigned) {
                    Assert-DevConfigMicrosoftSigned -Directory $work
                }
                $InstallRoot = New-DevConfigProtectedDirectory -Path $InstallRoot
                $target = Join-Path $InstallRoot 'bootstrap.ps1'
                Copy-Item -LiteralPath $bootstrap -Destination $target -Force
                Assert-DevConfigProtectedTree -Directory $InstallRoot
                if ((Get-FileHash -LiteralPath $bootstrap).Hash -ne (Get-FileHash -LiteralPath $target).Hash) {
                    throw 'The installed bootstrap does not match the verified download. Setup was not started.'
                }
                Unblock-File -LiteralPath $target
            } finally {
                if (Test-Path -LiteralPath $work) {
                    Remove-Item -LiteralPath $work -Recurse -Force
                }
            }

            $shellName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
            $arguments = @('-NoProfile')
            if (-not $AllowUnsigned) { $arguments += '-ExecutionPolicy', 'RemoteSigned' }
            $arguments += '-File', $target, '-Ref', $Ref, '-InstallRoot', $InstallRoot
            if ($Scenario) {
                $arguments += '-Scenario', $Scenario, '-AiBackend', $AiBackend, '-AiRuntime', $AiRuntime
                if ($RequireTriton) { $arguments += '-RequireTriton' }
                if ($PlanOnly) { $arguments += '-PlanOnly' }
                if ($ReportRoot) { $arguments += '-ReportRoot', $ReportRoot }
            } else {
                $arguments += '-Action', $Action
                if ($Workload -ne 'devconfig') { $arguments += '-Workload', $Workload }
            }
            if ($AllowUnsigned) { $arguments += '-AllowUnsigned' }
            if ($NoLaunch) { $arguments += '-NoLaunch' }
            & (Join-Path $PSHOME $shellName) @arguments
            if ($LASTEXITCODE -ne 0) {
                throw "Bootstrap finished with exit code $LASTEXITCODE."
            }
        }

        # PowerShell also recognizes smart quotes as string delimiters.
        $escapedRef = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Ref)
        $escapedRoot = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($InstallRoot)
        $command = "function Invoke-DevConfigWebRequest {`n${function:Invoke-DevConfigWebRequest}`n}`n" +
            "& {`n$launcher`n} -Ref '$escapedRef' -InstallRoot '$escapedRoot'"
        if ($Scenario) {
            $escapedErrorPath = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($ElevationErrorPath)
            $command += " -Scenario '$Scenario' -AiBackend '$AiBackend' -AiRuntime '$AiRuntime'"
            $command += " -ElevationErrorPath '$escapedErrorPath'"
            if ($RequireTriton) { $command += ' -RequireTriton' }
            if ($PlanOnly) { $command += ' -PlanOnly' }
            if ($ReportRoot) {
                $escapedReportRoot = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($ReportRoot)
                $command += " -ReportRoot '$escapedReportRoot'"
            }
        } else {
            $command += " -Action '$Action'"
            if ($Workload -ne 'devconfig') { $command += " -Workload '$Workload'" }
        }
        if ($AllowUnsigned) { $command += ' -AllowUnsigned' }
        if ($NoLaunch) { $command += ' -NoLaunch' }
        # Start-Process joins arguments; Windows quoting keeps the command intact.
        return '"' + [regex]::Replace($command, '(\\*)"', '$1$1\"') + '"'
    }

    # Windows PowerShell 5.1 still defaults to protocols GitHub no longer accepts.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Verbose "Could not raise the TLS version: $($_.Exception.Message)"
    }

    function Resolve-CalmOsRef {
        param(
            [Parameter(Mandatory)] [string] $Ref
        )

        if ($Ref -match '^[a-fA-F0-9]{40}$') {
            return $Ref
        }

        try {
            $response = Invoke-DevConfigWebRequest -Parameters @{
                Uri = "https://github.com/$repo.git/info/refs?service=git-upload-pack"
                Headers = @{ 'Git-Protocol' = 'version=0' }; TimeoutSec = 60
            }
        } catch {
            throw "Could not resolve '$Ref' from $repo ($($_.Exception.Message)). Check your internet connection or proxy settings, then run this again."
        }
        $advertisement = if ($response.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($response.Content)
        } else {
            [string]$response.Content
        }
        if (-not $advertisement.StartsWith("001e# service=git-upload-pack`n0000")) {
            throw "GitHub did not return Git refs for $repo. Setup was not started."
        }

        $names = if ($Ref.StartsWith('refs/') -or $Ref -ceq 'HEAD') {
            @($Ref)
        } else {
            @("refs/tags/$Ref", "refs/heads/$Ref")
        }
        foreach ($name in $names) {
            # Annotated tags advertise the target commit with a ^{} suffix.
            foreach ($candidate in @("$name^{}", $name)) {
                $pattern = '(?m)^(?:0000)?[a-fA-F0-9]{4}([a-fA-F0-9]{40}) ' +
                    [regex]::Escape($candidate) + '(?:\x00[^\n]*)?\r?$'
                $match = [regex]::Match($advertisement, $pattern)
                if ($match.Success) {
                    return $match.Groups[1].Value
                }
            }
        }
        throw "$repo has no advertised branch or tag called '$Ref'. Check the name, or use a full 40-character commit SHA."
    }

    $refName = $Ref
    $Ref = Resolve-CalmOsRef -Ref $Ref
    $flow = if ($AllowUnsigned) { 'src/windows-dev-config' } else { 'windows-dev-config' }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($Scope -eq 'User' -and $identity.User.Value -eq 'S-1-5-18') {
        throw 'The user part configures the signed-in user. Run it as that user, not as SYSTEM.'
    }
    $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($Scope -eq 'Machine' -and -not $isAdministrator) {
        throw 'The machine part needs administrator rights. Run it as SYSTEM or from an elevated PowerShell.'
    }
    # Only the full setup elevates: the machine part already runs elevated and the user part never elevates.
    if ($Scope -eq 'All' -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        # The elevated window closes on errors, so a ref without the workload is reported here, before UAC.
        if (-not $Scenario -and $Workload -ne 'devconfig') {
            try {
                $null = Invoke-DevConfigWebRequest -Parameters @{
                    Uri = "https://raw.githubusercontent.com/$repo/$Ref/$flow/workloads/$Workload.ps1"
                    Method = 'Head'; TimeoutSec = 60
                }
            } catch {
                $failure = $_
                $status = $null
                try { $status = [int]$failure.Exception.Response.StatusCode } catch { }
                if ($status -ne 404) { throw $failure }
                throw "'$refName' doesn't contain the '$Workload' workload under $flow. Check the workload name, or pick a newer -Ref."
            }
        }
        $elevationErrorPath = if ($Scenario) {
            Join-Path $env:TEMP "CalmOS-bootstrap-error-$([guid]::NewGuid().ToString('N')).txt"
        } else { '' }
        $command = Get-CalmOsElevationCommand -Ref $Ref -InstallRoot $InstallRoot -AllowUnsigned:$AllowUnsigned -NoLaunch:$NoLaunch `
            -Action $Action -Workload $Workload -Scenario $Scenario -AiBackend $AiBackend -AiRuntime $AiRuntime `
            -RequireTriton:$RequireTriton -PlanOnly:$PlanOnly -ReportRoot $ReportRoot `
            -ElevationErrorPath $elevationErrorPath
        Write-Host 'Setup needs Administrator rights (a UAC prompt will appear)...' -ForegroundColor Yellow
        # AI runtimes can outlive setup; workstation actions still wait for the process tree.
        $proc = Start-Process -FilePath $shell -ArgumentList ($arguments + @('-Command', $command)) -Verb RunAs -Wait:(-not $Scenario) -PassThru
        if ($Scenario) { $proc.WaitForExit() }
        if ($proc.ExitCode -ne 0) {
            if (-not $Scenario) {
                throw "Elevated setup exited with code $($proc.ExitCode). No further setup was started."
            }
            $detail = if (Test-Path -LiteralPath $elevationErrorPath) {
                (Get-Content -LiteralPath $elevationErrorPath -Raw).Trim()
            } else {
                'The elevated process did not return diagnostic output.'
            }
            Remove-Item -LiteralPath $elevationErrorPath -Force -ErrorAction SilentlyContinue
            throw "Elevated setup exited with code $($proc.ExitCode). No further setup was started.`n$detail"
        }
        if ($Scenario) {
            Remove-Item -LiteralPath $elevationErrorPath -Force -ErrorAction SilentlyContinue
        }
        if ($NoLaunch) {
            if ($Scenario) {
                $scenarioTarget = Join-Path $InstallRoot "Scenarios\$Scenario\Workloads\$Scenario\install.ps1"
                Write-Host "Scenario files are ready at $scenarioTarget." -ForegroundColor Cyan
            } else {
                $escapedTarget = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent((Join-Path $InstallRoot 'dev-config.ps1'))
                Write-Host "Run when ready: & '$escapedShell' $($arguments -join ' ') -File '$escapedTarget' -Action $Action$workloadSuffix$(if ($AllowUnsigned) { ' -AllowUnsigned' })"
            }
        }
        return
    }

    function Save-CalmOsArchive {
        param(
            [Parameter(Mandatory)] [string] $Destination
        )

        try {
            Invoke-DevConfigWebRequest -Parameters @{
                Uri = "https://github.com/$repo/archive/$Ref.zip"; OutFile = $Destination; TimeoutSec = 300
            }
        } catch {
            throw "Could not download '$Ref' from $repo ($($_.Exception.Message)). Check your internet connection or proxy settings, then run this again."
        }
    }

    function Start-CalmOsSetupProcess {
        param(
            [Parameter(Mandatory)] [string] $FilePath,
            [Parameter(Mandatory)] [string[]] $ArgumentList,
            [string] $Action = 'Full',
            [string] $Scope = 'All'
        )

        $start = @{ FilePath = $FilePath; ArgumentList = $ArgumentList; PassThru = $true }
        if ($Action -ne 'Uninstall') { $start.NoNewWindow = $true }
        if ($Scope -eq 'All') {
            $start.Wait = $true
            return (Start-Process @start).ExitCode
        }

        # Hidden parts have nobody to answer a prompt; an empty stdin gives native prompts end-of-file.
        $stdin = [IO.Path]::GetTempFileName()
        try {
            $start.RedirectStandardInput = $stdin
            $proc = Start-Process @start
            # -Wait would also wait for apps an installer leaves running. Cache the handle so Windows PowerShell can report ExitCode.
            $null = $proc.Handle
            $proc.WaitForExit()
            return $proc.ExitCode
        } finally {
            Remove-Item -LiteralPath $stdin -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ''
    if ($Scenario) {
        Write-Host "Windows Developer Config: $Scenario scenario" -ForegroundColor Cyan
    } elseif ($Workload -eq 'devconfig' -and $Scope -ne 'All') {
        Write-Host "Calm OS setup: $($Scope.ToLowerInvariant()) part" -ForegroundColor Cyan
    } elseif ($Workload -eq 'devconfig') {
        Write-Host 'Calm OS setup' -ForegroundColor Cyan
    } else {
        Write-Host "Windows Developer Config: $Workload workload" -ForegroundColor Cyan
    }
    Write-Host "  Fetching '$Ref' from $repo..." -ForegroundColor DarkGray

    $securityCode = (Invoke-DevConfigWebRequest -Parameters @{
        Uri = "https://raw.githubusercontent.com/$repo/$Ref/$flow/steps/_security.ps1"; TimeoutSec = 60
    }).Content.TrimStart([char]0xFEFF)
    if (-not $AllowUnsigned) {
        # Windows PowerShell requires UTF-16LE for in-memory signature verification.
        $signature = Get-AuthenticodeSignature -Content ([Text.Encoding]::Unicode.GetBytes($securityCode)) -SourcePathOrExtension '.ps1'
        if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -ne $microsoftSignerSubject) {
            throw "The setup security helper failed Microsoft signature verification ($($signature.Status)). Setup was not started."
        }
    }
    . ([scriptblock]::Create($securityCode))

    $work = if ($Scope -eq 'User') {
        # A standard user can't make Administrators the owner, so the user part uses its own temp folder.
        (New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ("CalmOS-download-" + [guid]::NewGuid().ToString('N'))) -Force).FullName
    } else {
        New-DevConfigProtectedDirectory -Path (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ("CalmOS-download-" + [guid]::NewGuid().ToString('N')))
    }
    try {
        $zip = Join-Path $work 'source.zip'
        Save-CalmOsArchive -Destination $zip
        $expanded = Join-Path $work 'expanded'
        Expand-Archive -LiteralPath $zip -DestinationPath $expanded -Force

        $top = Get-ChildItem -LiteralPath $expanded -Directory | Select-Object -First 1
        if (-not $top) {
            throw "The download from '$Ref' was empty. Check that the branch or tag name is right."
        }

        $signed = Join-Path $top.FullName 'windows-dev-config'
        $source = Join-Path (Join-Path $top.FullName 'src') 'windows-dev-config'
        $setupDir = if ($AllowUnsigned) { $source } else { $signed }
        if (-not ((Test-Path (Join-Path $setupDir 'bootstrap.ps1')) -and (Test-Path (Join-Path $setupDir 'dev-config.ps1')) -and (Test-Path (Join-Path $setupDir 'steps\_security.ps1')))) {
            throw "'$Ref' doesn't contain the requested setup under $flow. Use -AllowUnsigned only for the source copy."
        }
        # Refs that predate workloads have no workloads folder but still run the default setup.
        $workloadsDir = Join-Path $setupDir 'workloads'
        if ($Workload -ne 'devconfig' -and -not (Test-Path -LiteralPath (Join-Path $workloadsDir "$Workload.ps1") -PathType Leaf)) {
            throw "'$Ref' doesn't contain the '$Workload' workload under $flow. Check the workload name, or pick a newer -Ref."
        }
        # The user part runs from folders the signed-in user owns; it never elevates or registers tasks.
        if ($Scope -ne 'User') {
            Assert-DevConfigProtectedTree -Directory $setupDir
        }
        if ($AllowUnsigned) {
            Write-Host '  Using the unsigned source copy because -AllowUnsigned was passed.' -ForegroundColor Yellow
        } else {
            Write-Host '  Using the signed release copy.' -ForegroundColor DarkGray
            Assert-DevConfigMicrosoftSigned -Directory $setupDir
        }

        $InstallRoot = if ($Scope -eq 'User') {
            (New-Item -ItemType Directory -Path $InstallRoot -Force).FullName
        } else {
            New-DevConfigProtectedDirectory -Path $InstallRoot
        }

        if ($Scenario) {
            $workloadsDir = if ($AllowUnsigned) {
                Join-Path (Join-Path $top.FullName 'src') 'Workloads'
            } else {
                Join-Path $top.FullName 'Workloads'
            }
            if (-not ((Test-Path (Join-Path $workloadsDir "$Scenario\install.ps1")) -and
                    (Test-Path (Join-Path $workloadsDir '_common\content-hashes.ps1')))) {
                throw "'$Ref' does not contain the requested $Scenario workload under the selected signed/source tree."
            }
            Assert-DevConfigProtectedTree -Directory $workloadsDir
            if (-not $AllowUnsigned) {
                Assert-DevConfigMicrosoftSigned -Directory $workloadsDir
            }
            . (Join-Path $workloadsDir '_common\content-hashes.ps1')
            Assert-DevConfigWorkloadContent -WorkloadsRoot $workloadsDir

            $scenariosRoot = New-DevConfigProtectedDirectory -Path (Join-Path $InstallRoot 'Scenarios')
            $scenarioRoot = New-DevConfigProtectedDirectory -Path (Join-Path $scenariosRoot $Scenario)
            foreach ($existing in @('Workloads', 'windows-dev-config')) {
                $existingPath = Join-Path $scenarioRoot $existing
                if (Test-Path -LiteralPath $existingPath) {
                    Remove-Item -LiteralPath $existingPath -Recurse -Force
                }
            }
            Copy-Item -LiteralPath $workloadsDir -Destination $scenarioRoot -Recurse -Force
            $scenarioWindowsDevConfig = New-Item -ItemType Directory -Path (Join-Path $scenarioRoot 'windows-dev-config') -Force
            Copy-Item -LiteralPath (Join-Path $setupDir 'steps') -Destination $scenarioWindowsDevConfig.FullName -Recurse -Force
            Assert-DevConfigProtectedTree -Directory $scenarioRoot
            if (-not $AllowUnsigned) {
                Assert-DevConfigMicrosoftSigned -Directory $scenarioRoot
            }
            . (Join-Path $scenarioRoot 'Workloads\_common\content-hashes.ps1')
            Assert-DevConfigWorkloadContent -WorkloadsRoot (Join-Path $scenarioRoot 'Workloads')
            Get-ChildItem -LiteralPath $scenarioRoot -Recurse -Filter '*.ps1' -File | Unblock-File

            Remove-Item -LiteralPath $work -Recurse -Force
            $target = Join-Path $scenarioRoot "Workloads\$Scenario\install.ps1"
            Write-Host "  Scenario ready in $scenarioRoot" -ForegroundColor DarkGray
            $scenarioArguments = @('-NoProfile')
            if (-not $AllowUnsigned) { $scenarioArguments += '-ExecutionPolicy', 'RemoteSigned' }
            $scenarioArguments += '-File', $target
            if ($Scenario -in @('local-ai', 'pytorch')) { $scenarioArguments += '-Backend', $AiBackend }
            if ($Scenario -eq 'local-ai') { $scenarioArguments += '-Runtime', $AiRuntime }
            if ($RequireTriton) { $scenarioArguments += '-RequireTriton' }
            if ($PlanOnly) { $scenarioArguments += '-PlanOnly' }
            if ($ReportRoot) {
                if ($Scenario -eq 'local-ai') {
                    $scenarioArguments += '-ReportRoot', $ReportRoot
                } else {
                    $scenarioArguments += '-ReportPath', (Join-Path $ReportRoot "$Scenario.json")
                }
            }
            if ($NoLaunch) {
                $displayArguments = $scenarioArguments | ForEach-Object {
                    "'$([Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($_))'"
                }
                Write-Host "Run when ready: & '$escapedShell' $($displayArguments -join ' ')" -ForegroundColor Cyan
                return
            }
            & $shell @scenarioArguments
            $scenarioExitCode = $LASTEXITCODE
            if ($scenarioExitCode -ne 0) {
                throw "$Scenario scenario finished with exit code $scenarioExitCode."
            }
            return
        }

        # Keep logs and progress when replacing setup scripts.
        Copy-Item -LiteralPath (Join-Path $setupDir 'bootstrap.ps1'), (Join-Path $setupDir 'dev-config.ps1') -Destination $InstallRoot -Force
        Copy-Item -LiteralPath (Join-Path $setupDir 'steps') -Destination $InstallRoot -Recurse -Force
        if (Test-Path -LiteralPath $workloadsDir) {
            Copy-Item -LiteralPath $workloadsDir -Destination $InstallRoot -Recurse -Force
        }
        if ($Scope -ne 'User') {
            Assert-DevConfigProtectedTree -Directory $InstallRoot
        }
        if (-not $AllowUnsigned) {
            Assert-DevConfigMicrosoftSigned -Directory $InstallRoot
        }
        Get-ChildItem -LiteralPath $InstallRoot -Recurse -Filter '*.ps1' -File | Unblock-File

        # Clean up before setup can reboot.
        Remove-Item -LiteralPath $work -Recurse -Force
        $target = Join-Path $InstallRoot 'dev-config.ps1'
        Write-Host "  Ready in $InstallRoot" -ForegroundColor DarkGray

        # The machine and user parts run hidden, so a prompt must fail instead of waiting. Host options precede -File.
        if ($Scope -ne 'All') { $arguments += '-NonInteractive' }

        if ($NoLaunch) {
            $escapedTarget = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($target)
            $command = "& '$escapedShell' $($arguments -join ' ') -File '$escapedTarget' -Action $Action$workloadSuffix"
            if ($AllowUnsigned) { $command += ' -AllowUnsigned' }
            if ($Scope -ne 'All') { $command += " -Scope $Scope" }
            Write-Host "Run when ready: $command" -ForegroundColor Cyan
            return
        }

        $arguments += '-File', "`"$target`"", '-Action', $Action
        if ($Workload -ne 'devconfig') { $arguments += '-Workload', $Workload }
        if ($AllowUnsigned) { $arguments += '-AllowUnsigned' }
        if ($Scope -ne 'All') { $arguments += '-Scope', $Scope }
        $exitCode = Start-CalmOsSetupProcess -FilePath $shell -ArgumentList $arguments -Action $Action -Scope $Scope

        # Throw to avoid closing the caller's console.
        if ($exitCode -ne 0) {
            throw "Setup finished with exit code $exitCode. The log is in $InstallRoot."
        }
    } finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force
        }
    }
}

Invoke-CalmOsBootstrap @PSBoundParameters
