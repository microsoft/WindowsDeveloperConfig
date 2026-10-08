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
    }
    $InstallRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallRoot)
    if ($InstallRoot -notmatch '^[A-Za-z]:\\[^:]+$') {
        throw '-InstallRoot must be a local directory, not a drive root or network path.'
    }
    if ($ReportRoot) {
        $ReportRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportRoot)
    }

    foreach ($scope in @('MachinePolicy', 'UserPolicy')) {
        $policy = Get-ExecutionPolicy -Scope $scope
        if ($policy -ne 'Undefined') {
            if ($policy -eq 'Restricted') {
                throw "Organization policy ($scope) requires $policy. Script execution is disabled; contact your administrator."
            }
            break
        }
    }

    $shell = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    if ($Action -ne 'Uninstall') {
        $pwsh = Get-DevConfigPwshExe
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
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
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

    Write-Host ''
    if ($Scenario) {
        Write-Host "Windows Developer Config: $Scenario scenario" -ForegroundColor Cyan
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

    $work = New-DevConfigProtectedDirectory -Path (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ("CalmOS-download-" + [guid]::NewGuid().ToString('N')))
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
        Assert-DevConfigProtectedTree -Directory $setupDir
        if ($AllowUnsigned) {
            Write-Host '  Using the unsigned source copy because -AllowUnsigned was passed.' -ForegroundColor Yellow
        } else {
            Write-Host '  Using the signed release copy.' -ForegroundColor DarkGray
            Assert-DevConfigMicrosoftSigned -Directory $setupDir
        }

        $InstallRoot = New-DevConfigProtectedDirectory -Path $InstallRoot

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
        Assert-DevConfigProtectedTree -Directory $InstallRoot
        if (-not $AllowUnsigned) {
            Assert-DevConfigMicrosoftSigned -Directory $InstallRoot
        }
        Get-ChildItem -LiteralPath $InstallRoot -Recurse -Filter '*.ps1' -File | Unblock-File

        # Clean up before setup can reboot.
        Remove-Item -LiteralPath $work -Recurse -Force
        $target = Join-Path $InstallRoot 'dev-config.ps1'
        Write-Host "  Ready in $InstallRoot" -ForegroundColor DarkGray

        if ($NoLaunch) {
            $escapedTarget = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($target)
            $command = "& '$escapedShell' $($arguments -join ' ') -File '$escapedTarget' -Action $Action$workloadSuffix"
            if ($AllowUnsigned) { $command += ' -AllowUnsigned' }
            Write-Host "Run when ready: $command" -ForegroundColor Cyan
            return
        }

        $arguments += '-File', "`"$target`"", '-Action', $Action
        if ($Workload -ne 'devconfig') { $arguments += '-Workload', $Workload }
        if ($AllowUnsigned) { $arguments += '-AllowUnsigned' }
        $start = @{ FilePath = $shell; ArgumentList = $arguments; Wait = $true; PassThru = $true }
        if ($Action -ne 'Uninstall') { $start.NoNewWindow = $true }
        $proc = Start-Process @start

        # Throw to avoid closing the caller's console.
        if ($proc.ExitCode -ne 0) {
            throw "Setup finished with exit code $($proc.ExitCode). The log is in $InstallRoot."
        }
    } finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force
        }
    }
}

Invoke-CalmOsBootstrap @PSBoundParameters

# SIG # Begin signature block
# MIInUAYJKoZIhvcNAQcCoIInQTCCJz0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBNGnTzymxGPSMD
# EnEb6FTlVD/jdwCPGerVDkW0U7p35aCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
# xZvoL37EAAAAAAIcMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQxWhcNMjcwNDE1MTg1
# OTQxWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDVsZfgOKmM31HPfoWOoNEiw0SlCiIxUMC0I9NMWbucKOw/e9lP
# oAoehQVu6SG65V4EPzrYsnBnFPNoi4/HoOdjhz1qkrEt4I6tEcxXU6oOeY9zGveC
# /3iBeuhLYxM3M/PkcUoebF+Nednm8OkdSPoDu8imViHPQq/8CQUu0WRR4rE+dMRf
# rpVqfmNi2qWCX94T4MsepijGVkwE//tJg0ryAiYdHT34LSnlG/RSBZmQRGWZ5g8j
# qnKjRParSqMft1gvjuUTVgtWNZfgcLFSK5Wa0myrq8OPcgTGGsRgun+tnSS+IxDT
# xVsAPH1OzvPjwomguByhUe/OcvUN0D5Wmp7xAgMBAAGjggGqMIIBpjAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFNoH7a2YDjOSwpkp6DHcmUS7J+0yMFQGA1UdEQRNMEukSTBHMS0wKwYDVQQL
# EyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxFjAUBgNVBAUT
# DTIzMDAxMis1MDc1NjkwHwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEw
# YAYDVR0fBFkwVzBVoFOgUYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# bDBtBggrBgEFBQcBAQRhMF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmcl
# MjBQQ0ElMjAyMDI0LmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IC
# AQAUnEqhaRXe0T3hIJjvdQErEkrA/7bByjn6t5IArODkkRjzkYwtKMc2yYj2quaN
# rLutWw2YZcngKPy1b71YyDJQTy4NDRwaSh9Tw5thrk3NmcPrAHia5vtcBJ1CgtKK
# 7mQbIcQ22d/N3813ayCDDFewu1+jsZmX+r/aTEqaOM4TVxVtRSkuCy8nAXKuChOK
# Li/zA4XuH8iEYqIsj2YoNaeSxVmeGiERXpKdo3dDmYi0kO5w2D8VS4c3+9h6gElY
# BaAAg/dYErBg27qT3vv0zRDJhJufvCNylA8S7/+8H5E/PV5cng6na9VV/w9OV3qu
# uND6zdGa2EX38Glp50F9AIQk3p2xXmcvorDeM4XJ7UlWYBi6g80J1SSOQnInCYFE
# msfUNn3+1AaTJKSJL83quKArTac2pKhu0Yzzzrzo6HrsRiQKzpnRBb1/dMa6P3hz
# 75XbMRBctNsFhZC07WCmjExdLg2eHW5uV0TY8D5+6wozJf7vF3+WHkYPO85Z+BC6
# U4FkNbYNycZ9cE4j1tXRdyDCfml6c0HWPHjNVDObrv9lKt3qUqFpX38VCqVCyNOO
# 1UcXfQiVjJw32U2WUKZjt/neJKHEBsm9kFsLuWzkQ53+qcaSaytmsCnk2gOglrlD
# 5d3kKyvvAw+rzm0lT8K38P6PLxfZQHhu4W8dV7Av8N2ZmDCCBr0wggSloAMCAQIC
# EzMAAAA5O7Y3Gb8GHWcAAAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoX
# DTM2MDMyMjIyMTMwNFowVzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQ
# Q0EgMjAyNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeq
# lRYHNa265v4IY9fH8TKhemHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo
# 0dtS/EW6I/yEL/bLSY8hKpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATv
# QVL4tcf03aTycsz8QeCdM0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a
# 1uv1zerOYMnsneRRwCbpyW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1
# FyQfK0fVkaya8SmVHQ/tOf23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfO
# GSWHIIV4YrTJTT6PNty5REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7
# ttOu1bVnXfHaqPYl2rPs20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJ
# uz2MXMCt7iw7lFPG9LXKGjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxS
# CwyoGIq0PhaA7Y+VPct5pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOm
# VQop36wUVUYklUy++vDWeEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3
# SkE/xIkgpfl22MM1itkZ35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8E
# BAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPX
# LQaUEggxMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMB
# Af8wHwYDVR0jBBgwFoAUci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBP
# oE2gS4ZJaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAw
# TgYIKwYBBQUHMAKGQmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOC
# AgEAFJQfOChP7onn6fLIMKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D
# 5W4wMwYeLystcEqfkjz4NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBY
# nbu0+THSuVHTe0VTTPVhily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSI
# vgn0JksVBVMYVI5QFu/qhnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6
# aR9y34aiM1qmxaxBi6OUnyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4w
# PKC5OmHm1DQIt/MNokbbH3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7
# RTX8AdBPo0I6OEojf39zuFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK
# /fg8B2qjW88MT/WF5V5uvZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSK
# YBv0VisCzfxgeU+dquXW9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkw
# YTu/9dLeH2pDqeJZAABVDWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVT
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghndMIIZ2QIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIHsU3k+bycRklbEAxPDAyJflbttn
# uk3dBowAm3UeQry4MEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAtwaT1ETXSZD57jib0p6OanrZM0cInc2y4LsnIUCbCO7a1kBXJb1qj2Pfdtgw
# 7qR6Aho/3Z+vx3r3nWh74eGeSW5e3cE8XGAHAKtyxyM3GvNx7LmcKqHuvpfYfuJu
# 7HRmELptyoZtVgobYJtjyyGslLfL5Cm7P3vZBLuczuMe1269bZ5Yo+DlngL/A+KE
# IqyLKJAH4ps0R8kLUbh4dqFByLClR88V3zzCCu+mTHA7M6C4ynWpYPyfHBE/ncpo
# Ybsfw+4bB8A6tKVKPnPwfGnzZYmKDx1EBhyIxqe7HYayGTEYgOr4MVtyxqXhvgtn
# b0Ht6gMTpph9cJXSeX+E6eGiiqGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UG
# CSqGSIb3DQEHAqCCF4YwgheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCArdgKbJz7jQqFBgFlmcfirEChCfBT4DzOUiLzBSicm7AIGaq6wwDJQGBMy
# MDI2MTAwODAzMDIwNS4yMTZaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0
# MzFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEfswggcoMIIFEKADAgECAhMzAAACHUvAkoc4hX45AAEAAAIdMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgx
# NDE4NDgzM1oXDTI2MTExMzE4NDgzM1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjQzMUEtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAorSgaAA8oOl4ph574zw29egU
# N8DDepRHLX8FM1zHNJmXG6KrSqUKwzcKafopuYdPTETTCvb9aJfESuAU0iGNUFI/
# D6R0kvdfpe2oPX+E3sbTQvGi4JPH5qdIYUaJ45V/4bqe8eNvbWzpC+ZKjH193Dei
# I1XAI918JoQmBhlEXo/Ton1721luZJgincsf5LjMY3jX84WyXUSX3dsS7h/7xVI+
# w1yjg7pa+0y3o/me2Tsv6UJUdSTQap5ORGSfCnclnP1z3IiiWIWr3Vo7aIPWsgJz
# q3m5GxpxUHCQk8qzUhk50y/uB+LGE3WIK2C77iy9iFsSfSLUnyMEzGRDW9mXHT4P
# H7Ozz6CHqQEiNvwcHqlvlCh1pHQh1NXQSAqOoVBs5mi6easf6yxWTfe5DrR79503
# r8pU6VqC2Y9XMRU4wH9QbYXYsIUZ33Jmndy22W1LBDAbxBPQHCBlncGDU3BgdhVU
# VLe80mggFO98FdkWho67w4kPdCTRkvdvkY8PrQYE/nQjHXCa0g7LcMttZb6ejMHf
# Q+tUWXv6+nZ4Ynkr2OkaxclFCw4RIYNMWD26AWbQj/WEdzga18fKtw66L5gzXPza
# 6jFBfPJeKE3H8QAuwpirmH4ms+5nUjNNQOmNgqJn0U1+3Yn7ClswD79YN0r3fdbY
# BMDApBZJpNlK7q7HXRsCAwEAAaOCAUkwggFFMB0GA1UdDgQWBBSEWfBxNEamZtXm
# 8gl92Yq80jfxXTAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAkdweB4yxvLspLKq0
# D+miyD4Q0EcxVFpNZuJxiR54gWRkeTDDuymNeB03JhlsBpbwSYJ5uZSgDBCvwHED
# 2VL8lJpFlOprJzxsXWC2NTfA+O+PO5Fk5jw6LHh6jeBADDEdQAx3Hqi7Zm0JwvQ9
# 3z5f6dtxkm29WqOcHYXRXfAQwy1hSrLXyfeblqR66jpP/9n0fCkWU4ggsUjQpQ2N
# gj1DV09J4Y3y7p9Nd81+Xs6qYo++7RKm8qiB/5NDeigOLjlAeFgiEXIRUJW+mJyq
# pQw+OORlaqcFjR8Hu0G+/7bMdek68YX+kPpDBk7Ue+I/xgiYJ1xcDRBn/vczLtN7
# 2+RIlD4UgXYLuBSCk//pDEPX5z39Cr+rkc6E4Y28FPk4BhloAyvp628P4xfElQY8
# TcxraUbZShypocE6ny95D1K1BkltZmrHVKCxmglnuOlM15NKIrXFlXCzdqpCtIwQ
# 417wNAVF/QDPvzzbumPdTi6fb0tLbScYobV6zvbBsMsKEME4Tj1b9oIXC8dybJq4
# nbboEXYpRwi1QAbpSNrn+PxGW9uf1q63FnMJu4gm3Oh63njW/iVf723quzyHrSij
# WMgY0HiRiHQi0Jyu0h8MdhRUp7mxbmLQckPiOFwAlIaUN/k725y/aLWpkRU6fqmL
# lEOyH5WpyLd23AYy9r8v+Qoba6swggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
# AAAAAAAVMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVa
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEA5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1
# V/YBf2xK4OK9uT4XYDP/XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9
# alKDRLemjkZrBxTzxXb1hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmv
# Haus9ja+NSZk2pg7uhp7M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928
# jaTjkY+yOSxRnOlwaQ3KNi1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3t
# pK56KTesy+uDRedGbsoy1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEe
# HT39IM9zfUGaRnXNxF803RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26o
# ElHovwUDo9Fzpk03dJQcNIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4C
# vEJoLhDqhFFG4tG9ahhaYQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ug
# poMhXV8wdJGUlNi5UPkLiWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXps
# xREdcu+N+VLEhReTwDwV2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0C
# AwEAAaOCAd0wggHZMBIGCSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYE
# FCqnUv5kxJq+gpE8RjUpzxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtT
# NRnpcjBcBgNVHSAEVTBTMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5o
# dG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBD
# AEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZW
# y4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5t
# aWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAt
# MDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0y
# My5jcnQwDQYJKoZIhvcNAQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pc
# FLY+TkdkeLEGk5c9MTO1OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpT
# Td2YurYeeNg2LpypglYAA7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0j
# VOR4U3UkV7ndn/OOPcbzaN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3
# +SmJw7wXsFSFQrP8DJ6LGYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmR
# sqlb30mjdAy87JGA0j3mSj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSw
# ethQ/gpY3UA8x1RtnWN0SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5b
# RAGOWhmRaw2fpCjcZxkoJLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmx
# aQFEfnyhYWxz/gq77EFmPWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsX
# HRWJjXD+57XQKBqJC4822rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0
# W2rRnj7tfqAxM328y+l7vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0
# HVUzWLOhcGbyoYIDVjCCAj4CAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0
# MzFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAuoO+BKbfXzqyfi9GLEdWHkCLeT+ggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO5w6DUwIhgPMjAyNjEwMDcxNTQ4MDVaGA8yMDI2MTAwODE1NDgwNVowdDA6Bgor
# BgEEAYRZCgQBMSwwKjAKAgUA7nDoNQIBADAHAgEAAgIfKzAHAgEAAgITkTAKAgUA
# 7nI5tQIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAID
# B6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQBKU/4Baajfs1Y6o+S6
# EzL8rxtparrNjt1WPeqrzGFUf89Hw1vXXn0piPfMUxDM3nsXmtz2t0pm2BSAJyCa
# lEu3jIrZCFTUy28gZ/OHZWGNteXsqjWW1I9XNRE9sTPegM889P9ODMCkKhAkfJ61
# I8f255I/s4CWKP1RztiGmpM2N5BrGf5EcwDyAkhB1adCpiCf62vN/90Y5GTYyGY/
# 6LKbapa+98UKAzC37zWsDkwkBVwFumCReK5XRTv7WAlEPfuQ2HzozTEpeLV0liA1
# vddfWNx2AmZcgIJO4mLcrnQzK6RJudA5/71man4+di1iIZDDCB6xMYNil+d3px+W
# TJKKMYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIdS8CShziFfjkAAQAAAh0wDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3
# DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQg/nWOcY7/SpZ9t/a2
# ZQOWYY2sV90KwCLAP/WSojAX5NowgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9
# BCCxtpXMXEiLJzrqM77ep4rTNwrMOj6gpWN9hZvpj5QFUTCBmDCBgKR+MHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACHUvAkoc4hX45AAEAAAIdMCIE
# INmGHPK8W2FpABTc1nIxUgrgTrLY1rsvKA/JebTBO/XzMA0GCSqGSIb3DQEBCwUA
# BIICACKzkkmfWPoUidrn/3Yun4w8ZRJefZgBO2pSZt9BGIZP7VeU64fiAbqAb6vi
# kKGw+9y716A0fAN5GqRvuVner43HHjMXdsIPFstt4jZaVuc37Crk5l2s6xLFF2xc
# YQxo0U2m2Tas3Mshd4HhKPGwQ7zd/ROroHSR/+EKTfaf0ueYJM29aqgHtLjQkPCD
# pHH9GvsqIzWvQZ+RMRT+yfHt1mdH2sJxktPenChWz2Q1kE6jAEGKFvgyACNNFaHU
# g265dzjuasREErzSwCd49LvIZRBty6K6EpKGCji9NSFh7nLi22uDkT6mmHH2eVC5
# CrZazCHEfpgfDvB+KhcqD2mv8Hd+i1YRbEoK1YtsxZZgBpkKv5sm41hxjzzzMrzf
# mtcfD6aehJ99+Y81giCqc3kneJLQlEPmlEHqaiOEOVKKmJFZyGxnY2CssoNZpnog
# 1QR1aHcrJz1qSk2crbqEmYRMukhgSfg3bFEsG9iVcNqG9LW7Kzb6T6P06YJsss6S
# Bhuk5JIKjBXM3wUmkPFWTZ78b62gGvvpgUbwMeSXNqhV0aOTJOhDb8yFChuDc2rT
# c0LwCLyhcF9tdUFbEFPW0JICPJyfcgFdUuyzoQ5N9XvgJ7MMFxTbU3BPPESAbdRb
# 7KLfmO3+WlaQjruJDRV8RFif2zLH+jg76ja8pJz9Fl4xdh20
# SIG # End signature block
