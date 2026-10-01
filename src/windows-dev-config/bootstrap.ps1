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

  To select a branch or tag:

      & ([scriptblock]::Create((irm <url>))) -Ref 'v1.2.3'

  To apply one workload from workloads\ instead of the full Windows Dev Config setup:

      & ([scriptblock]::Create((irm <url>))) -Workload winui
#>

[CmdletBinding()]
param(
    [string] $Ref = 'main',
    [string] $InstallRoot,
    [switch] $AllowUnsigned,
    [switch] $NoLaunch,
    [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
    [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig',
    [ValidateSet('', 'local-ai')] [string] $Scenario = '',
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
        [ValidateSet('', 'local-ai')] [string] $Scenario = '',
        [ValidateSet('Auto', 'CPU', 'CUDA', 'ROCm', 'XPU')] [string] $AiBackend = 'Auto',
        [ValidateSet('None', 'LlamaCpp', 'Ollama', 'Foundry')] [string] $AiRuntime = 'None',
        [switch] $RequireTriton,
        [switch] $PlanOnly,
        [string] $ReportRoot
    )

    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    $repo = 'microsoft/WindowsDeveloperConfig'
    $microsoftSignerSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    $Workload = $Workload.ToLowerInvariant()
    # The default workload is omitted from command lines so refs that predate workloads still accept them.
    $workloadSuffix = if ($Workload -ne 'devconfig') { " -Workload $Workload" } else { '' }

    $scenarioOptionNames = @('AiBackend', 'AiRuntime', 'RequireTriton', 'PlanOnly', 'ReportRoot')
    if (-not $Scenario -and @($scenarioOptionNames | Where-Object { $PSBoundParameters.ContainsKey($_) }).Count -gt 0) {
        throw 'AI backend/runtime/report options require -Scenario local-ai.'
    }
    if ($Scenario -and $PSBoundParameters.ContainsKey('Action')) {
        throw '-Action configures the full workstation and cannot be combined with -Scenario local-ai.'
    }
    if ($Scenario -and $Workload -ne 'devconfig') {
        throw '-Workload cannot be combined with -Scenario local-ai.'
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
    $pwsh = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell\7\pwsh.exe'
    if ($Action -ne 'Uninstall' -and (Test-Path -LiteralPath $pwsh)) { $shell = $pwsh }
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
            [ValidateSet('', 'local-ai')] [string] $Scenario = '',
            [ValidateSet('Auto', 'CPU', 'CUDA', 'ROCm', 'XPU')] [string] $AiBackend = 'Auto',
            [ValidateSet('None', 'LlamaCpp', 'Ollama', 'Foundry')] [string] $AiRuntime = 'None',
            [switch] $RequireTriton,
            [switch] $PlanOnly,
            [string] $ReportRoot,
            [Parameter(Mandatory)] [string] $ElevationErrorPath
        )

        $launcher = {
            param(
                [string] $Ref,
                [string] $InstallRoot,
                [switch] $AllowUnsigned,
                [switch] $NoLaunch,
                [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
                [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig',
                [ValidateSet('', 'local-ai')] [string] $Scenario = '',
                [ValidateSet('Auto', 'CPU', 'CUDA', 'ROCm', 'XPU')] [string] $AiBackend = 'Auto',
                [ValidateSet('None', 'LlamaCpp', 'Ollama', 'Foundry')] [string] $AiRuntime = 'None',
                [switch] $RequireTriton,
                [switch] $PlanOnly,
                [string] $ReportRoot,
                [Parameter(Mandatory)] [string] $ElevationErrorPath
            )

            $ErrorActionPreference = 'Stop'
            Set-StrictMode -Version Latest
            trap {
                try {
                    [IO.File]::WriteAllText(
                        $ElevationErrorPath,
                        ($_ | Out-String),
                        [Text.UTF8Encoding]::new($false))
                } catch { }
                exit 1
            }
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $flow = if ($AllowUnsigned) { 'src/windows-dev-config' } else { 'windows-dev-config' }
            $baseUri = "https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/$Ref/$flow"
            $securityCode = (Invoke-RestMethod -Uri "$baseUri/steps/_security.ps1" -UseBasicParsing -TimeoutSec 60).TrimStart([char]0xFEFF)
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
                Invoke-WebRequest -Uri "$baseUri/bootstrap.ps1" -OutFile $bootstrap -UseBasicParsing -TimeoutSec 60
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
            if ($Scenario) {
                & (Join-Path $PSHOME $shellName) @arguments
                $bootstrapOutput = ''
            } else {
                $bootstrapOutput = (& (Join-Path $PSHOME $shellName) @arguments 2>&1 | Out-String).Trim()
            }
            $bootstrapExitCode = $LASTEXITCODE
            if ($bootstrapOutput) { Write-Host $bootstrapOutput }
            if ($bootstrapExitCode -ne 0) {
                throw "Bootstrap finished with exit code $bootstrapExitCode.`n$bootstrapOutput"
            }
        }

        # PowerShell also recognizes smart quotes as string delimiters.
        $escapedRef = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Ref)
        $escapedRoot = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($InstallRoot)
        $escapedErrorPath = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($ElevationErrorPath)
        $command = "& {`n$launcher`n} -Ref '$escapedRef' -InstallRoot '$escapedRoot' -ElevationErrorPath '$escapedErrorPath'"
        if ($Scenario) {
            $command += " -Scenario '$Scenario' -AiBackend '$AiBackend' -AiRuntime '$AiRuntime'"
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

    $refName = $Ref
    if ($Ref -notmatch '^[a-fA-F0-9]{40}$') {
        $resolvedRef = (Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/commits/$([Uri]::EscapeDataString($Ref))" -UseBasicParsing -TimeoutSec 60).sha
        if ($resolvedRef -isnot [string] -or $resolvedRef -notmatch '^[a-fA-F0-9]{40}$') {
            throw "GitHub did not return a commit SHA for '$Ref'. Setup was not started."
        }
        $Ref = $resolvedRef
    }
    $flow = if ($AllowUnsigned) { 'src/windows-dev-config' } else { 'windows-dev-config' }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        # The elevated window closes on errors, so a ref without the workload is reported here, before UAC.
        if (-not $Scenario -and $Workload -ne 'devconfig') {
            try {
                $null = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$repo/$Ref/$flow/workloads/$Workload.ps1" -Method Head -UseBasicParsing -TimeoutSec 60
            } catch {
                $failure = $_
                $status = $null
                try { $status = [int]$failure.Exception.Response.StatusCode } catch { }
                if ($status -ne 404) { throw $failure }
                throw "'$refName' doesn't contain the '$Workload' workload under $flow. Check the workload name, or pick a newer -Ref."
            }
        }
        $elevationErrorPath = Join-Path $env:TEMP "CalmOS-bootstrap-error-$([guid]::NewGuid().ToString('N')).txt"
        $command = Get-CalmOsElevationCommand -Ref $Ref -InstallRoot $InstallRoot -AllowUnsigned:$AllowUnsigned -NoLaunch:$NoLaunch `
            -Action $Action -Workload $Workload -Scenario $Scenario -AiBackend $AiBackend -AiRuntime $AiRuntime `
            -RequireTriton:$RequireTriton -PlanOnly:$PlanOnly -ReportRoot $ReportRoot `
            -ElevationErrorPath $elevationErrorPath
        Write-Host 'Setup needs Administrator rights (a UAC prompt will appear)...' -ForegroundColor Yellow
        $proc = Start-Process -FilePath $shell -ArgumentList ($arguments + @('-Command', $command)) -Verb RunAs -PassThru
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            $detail = if (Test-Path -LiteralPath $elevationErrorPath) {
                (Get-Content -LiteralPath $elevationErrorPath -Raw).Trim()
            } else {
                'The elevated process did not return diagnostic output.'
            }
            Remove-Item -LiteralPath $elevationErrorPath -Force -ErrorAction SilentlyContinue
            throw "Elevated setup exited with code $($proc.ExitCode). No further setup was started.`n$detail"
        }
        Remove-Item -LiteralPath $elevationErrorPath -Force -ErrorAction SilentlyContinue
        if ($NoLaunch) {
            if ($Scenario) {
                $scenarioTarget = Join-Path $InstallRoot 'Scenarios\local-ai\Workloads\local-ai\install.ps1'
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

        $candidates = @(
            "https://github.com/$repo/archive/refs/heads/$Ref.zip"
            "https://github.com/$repo/archive/$Ref.zip"
        )

        $lastError = $null
        $everyAttemptWas404 = $true
        foreach ($url in $candidates) {
            foreach ($attempt in 1..3) {
                try {
                    Invoke-WebRequest -Uri $url -OutFile $Destination -UseBasicParsing -TimeoutSec 300
                    return
                } catch {
                    $lastError = $_
                    $status = $null
                    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
                    if ($status -eq 404) { break }
                    $everyAttemptWas404 = $false
                    if ($attempt -lt 3) {
                        Write-Host "  Download attempt $attempt didn't work -- trying again..." -ForegroundColor DarkGray
                        Start-Sleep -Seconds (5 * $attempt)
                    }
                }
            }
        }

        if ($everyAttemptWas404) {
            throw "$repo has no branch, tag or commit called '$Ref'. Check the name and run this again."
        }
        throw "Could not download '$Ref' from $repo ($($lastError.Exception.Message)). Check your internet connection or proxy settings, then run this again."
    }

    Write-Host ''
    if ($Scenario) {
        Write-Host 'Windows Developer Config: local AI scenario' -ForegroundColor Cyan
    } elseif ($Workload -eq 'devconfig') {
        Write-Host 'Calm OS setup' -ForegroundColor Cyan
    } else {
        Write-Host "Windows Developer Config: $Workload workload" -ForegroundColor Cyan
    }
    Write-Host "  Fetching '$Ref' from $repo..." -ForegroundColor DarkGray

    $securityCode = (Invoke-RestMethod -Uri "https://raw.githubusercontent.com/$repo/$Ref/$flow/steps/_security.ps1" -UseBasicParsing -TimeoutSec 60).TrimStart([char]0xFEFF)
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
            if (-not ((Test-Path (Join-Path $workloadsDir 'local-ai\install.ps1')) -and
                    (Test-Path (Join-Path $workloadsDir '_common\content-hashes.ps1')))) {
                throw "'$Ref' does not contain the requested local-ai workload under the selected signed/source tree."
            }
            Assert-DevConfigProtectedTree -Directory $workloadsDir
            if (-not $AllowUnsigned) {
                Assert-DevConfigMicrosoftSigned -Directory $workloadsDir
            }
            . (Join-Path $workloadsDir '_common\content-hashes.ps1')
            Assert-DevConfigWorkloadContent -WorkloadsRoot $workloadsDir

            $scenariosRoot = New-DevConfigProtectedDirectory -Path (Join-Path $InstallRoot 'Scenarios')
            $scenarioRoot = New-DevConfigProtectedDirectory -Path (Join-Path $scenariosRoot 'local-ai')
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
            $target = Join-Path $scenarioRoot 'Workloads\local-ai\install.ps1'
            Write-Host "  Scenario ready in $scenarioRoot" -ForegroundColor DarkGray
            $scenarioArguments = @('-NoProfile')
            if (-not $AllowUnsigned) { $scenarioArguments += '-ExecutionPolicy', 'RemoteSigned' }
            $scenarioArguments += '-File', "`"$target`"", '-Backend', $AiBackend, '-Runtime', $AiRuntime
            if ($RequireTriton) { $scenarioArguments += '-RequireTriton' }
            if ($PlanOnly) { $scenarioArguments += '-PlanOnly' }
            if ($ReportRoot) { $scenarioArguments += '-ReportRoot', "`"$ReportRoot`"" }
            if ($NoLaunch) {
                Write-Host "Run when ready: & '$escapedShell' $($scenarioArguments -join ' ')" -ForegroundColor Cyan
                return
            }
            & $shell @scenarioArguments
            $scenarioExitCode = $LASTEXITCODE
            if ($scenarioExitCode -ne 0) {
                throw "Local AI scenario finished with exit code $scenarioExitCode."
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
