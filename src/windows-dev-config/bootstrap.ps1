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
#>

[CmdletBinding()]
param(
    [string] $Ref = 'main',
    [string] $InstallRoot,
    [switch] $AllowUnsigned,
    [switch] $NoLaunch,
    [ValidateSet('', 'local-ai')] [string] $Scenario = '',
    [ValidateSet('Auto', 'CPU', 'CUDA', 'ROCm', 'XPU')] [string] $AiBackend = 'Auto',
    [ValidateSet('None', 'LlamaCpp', 'Ollama', 'Foundry')] [string] $AiRuntime = 'None',
    [switch] $AiRequireTriton,
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
        [ValidateSet('', 'local-ai')] [string] $Scenario = '',
        [ValidateSet('Auto', 'CPU', 'CUDA', 'ROCm', 'XPU')] [string] $AiBackend = 'Auto',
        [ValidateSet('None', 'LlamaCpp', 'Ollama', 'Foundry')] [string] $AiRuntime = 'None',
        [switch] $AiRequireTriton,
        [switch] $PlanOnly,
        [string] $ReportRoot
    )

    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    $repo = 'microsoft/WindowsDeveloperConfig'
    $microsoftSignerSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'

    # Reject refs that could escape the repository path.
    if ($Ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $Ref.Contains('..')) {
        throw "'$Ref' is not a valid branch, tag or commit name. Use letters, digits, and . _ - / only."
    }

    if (-not $Scenario -and
        ($AiBackend -ne 'Auto' -or $AiRuntime -ne 'None' -or $AiRequireTriton -or $PlanOnly -or $ReportRoot)) {
        throw 'AI backend/runtime/report options require -Scenario local-ai.'
    }

    if (-not $InstallRoot) {
        $InstallRoot = if ($Scenario -eq 'local-ai') {
            Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WindowsDeveloperConfig\Scenarios\local-ai'
        } else {
            Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'CalmOS'
        }
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
    if (Test-Path -LiteralPath $pwsh) { $shell = $pwsh }
    $escapedShell = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($shell)
    $arguments = @('-NoProfile')
    if (-not $AllowUnsigned) { $arguments += '-ExecutionPolicy', 'RemoteSigned' }

    function Get-CalmOsElevationCommand {
        param(
            [Parameter(Mandatory)] [scriptblock] $Bootstrap,
            [Parameter(Mandatory)] [string] $Ref,
            [Parameter(Mandatory)] [string] $InstallRoot,
            [switch] $AllowUnsigned,
            [switch] $NoLaunch,
            [string] $Scenario = '',
            [string] $AiBackend = 'Auto',
            [string] $AiRuntime = 'None',
            [switch] $AiRequireTriton,
            [switch] $PlanOnly,
            [string] $ReportRoot
        )

        # PowerShell also recognizes smart quotes as string delimiters.
        $escapedRef = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Ref)
        $escapedRoot = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($InstallRoot)
        $invocation = "& {`n$Bootstrap`n} -Ref '$escapedRef' -InstallRoot '$escapedRoot'"
        if ($AllowUnsigned) { $invocation += ' -AllowUnsigned' }
        if ($NoLaunch) { $invocation += ' -NoLaunch' }
        if ($Scenario) {
            $escapedScenario = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Scenario)
            $escapedBackend = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($AiBackend)
            $escapedRuntime = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($AiRuntime)
            $invocation += " -Scenario '$escapedScenario' -AiBackend '$escapedBackend' -AiRuntime '$escapedRuntime'"
            if ($AiRequireTriton) { $invocation += ' -AiRequireTriton' }
            if ($PlanOnly) { $invocation += ' -PlanOnly' }
            if ($ReportRoot) {
                $escapedReportRoot = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($ReportRoot)
                $invocation += " -ReportRoot '$escapedReportRoot'"
            }
        }
        $buffer = [IO.MemoryStream]::new()
        $gzip = [IO.Compression.GZipStream]::new($buffer, [IO.Compression.CompressionMode]::Compress, $true)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($invocation)
            $gzip.Write($bytes, 0, $bytes.Length)
        } finally {
            $gzip.Dispose()
        }
        $payload = [Convert]::ToBase64String($buffer.ToArray())
        $buffer.Dispose()
        $launcher = @"
`$stream = [IO.Compression.GZipStream]::new([IO.MemoryStream]::new([Convert]::FromBase64String('$payload')), [IO.Compression.CompressionMode]::Decompress)
`$reader = [IO.StreamReader]::new(`$stream)
try { `$code = `$reader.ReadToEnd() } finally { `$reader.Dispose() }
& ([scriptblock]::Create(`$code))
"@
        return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launcher))
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        # Avoid elevating a script from a user-writable temporary file.
        $encoded = Get-CalmOsElevationCommand `
            -Bootstrap $MyInvocation.MyCommand.ScriptBlock `
            -Ref $Ref `
            -InstallRoot $InstallRoot `
            -AllowUnsigned:$AllowUnsigned `
            -NoLaunch:$NoLaunch `
            -Scenario $Scenario `
            -AiBackend $AiBackend `
            -AiRuntime $AiRuntime `
            -AiRequireTriton:$AiRequireTriton `
            -PlanOnly:$PlanOnly `
            -ReportRoot $ReportRoot
        Write-Host 'Setup needs Administrator rights (a UAC prompt will appear)...' -ForegroundColor Yellow
        $proc = Start-Process -FilePath $shell -ArgumentList ($arguments + @('-EncodedCommand', $encoded)) -Verb RunAs -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            throw "Elevated setup exited with code $($proc.ExitCode). No further setup was started."
        }
        if ($NoLaunch) {
            $target = if ($Scenario -eq 'local-ai') {
                Join-Path $InstallRoot 'Workloads\local-ai\install.ps1'
            } else {
                Join-Path $InstallRoot 'dev-config.ps1'
            }
            $escapedTarget = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($target)
            $runArguments = @()
            if (-not $AllowUnsigned) { $runArguments += '-ExecutionPolicy', 'RemoteSigned' }
            $runArguments += '-File', "'$escapedTarget'"
            if ($Scenario -eq 'local-ai') {
                $runArguments += '-Backend', $AiBackend, '-Runtime', $AiRuntime
                if ($AiRequireTriton) { $runArguments += '-RequireTriton' }
                if ($PlanOnly) { $runArguments += '-PlanOnly' }
                if ($ReportRoot) { $runArguments += '-ReportRoot', "'$ReportRoot'" }
            } elseif ($AllowUnsigned) {
                $runArguments += '-AllowUnsigned'
            }
            Write-Host "Run when ready: & '$escapedShell' -NoProfile $($runArguments -join ' ')" -ForegroundColor Cyan
        }
        return
    }

    # Windows PowerShell 5.1 still defaults to protocols GitHub no longer accepts.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Verbose "Could not raise the TLS version: $($_.Exception.Message)"
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
    Write-Host $(if ($Scenario -eq 'local-ai') { 'Windows Developer Config: local AI' } else { 'Calm OS setup' }) -ForegroundColor Cyan
    Write-Host "  Fetching '$Ref' from $repo..." -ForegroundColor DarkGray

    $flow = if ($AllowUnsigned) { 'src/windows-dev-config' } else { 'windows-dev-config' }
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
        if (-not ((Test-Path (Join-Path $setupDir 'dev-config.ps1')) -and (Test-Path (Join-Path $setupDir 'steps\_security.ps1')))) {
            throw "'$Ref' doesn't contain the requested setup under $flow. Use -AllowUnsigned only for the source copy."
        }

        $workloadsDir = $null
        if ($Scenario -eq 'local-ai') {
            $workloadsDir = if ($AllowUnsigned) {
                Join-Path (Join-Path $top.FullName 'src') 'Workloads'
            } else {
                Join-Path $top.FullName 'Workloads'
            }
            if (-not (Test-Path -LiteralPath (Join-Path $workloadsDir 'local-ai\install.ps1')) -or
                -not (Test-Path -LiteralPath (Join-Path $workloadsDir '_common\direct-setup.ps1'))) {
                $mode = if ($AllowUnsigned) { 'source' } else { 'signed release' }
                throw "'$Ref' does not contain the complete $mode local-ai scenario. For an unsigned PR branch, pass -AllowUnsigned."
            }
        }

        Assert-DevConfigProtectedTree -Directory $setupDir
        if ($workloadsDir) {
            Assert-DevConfigProtectedTree -Directory $workloadsDir
        }
        if ($AllowUnsigned) {
            Write-Host '  Using the unsigned source copy because -AllowUnsigned was passed.' -ForegroundColor Yellow
        } else {
            Write-Host '  Using the signed release copy.' -ForegroundColor DarkGray
            Assert-DevConfigMicrosoftSigned -Directory $setupDir
            if ($workloadsDir) {
                Assert-DevConfigMicrosoftSigned -Directory $workloadsDir
                . (Join-Path $workloadsDir '_common\content-hashes.ps1')
                Assert-DevConfigWorkloadContent -WorkloadsRoot $workloadsDir
            }
        }

        $InstallRoot = New-DevConfigProtectedDirectory -Path $InstallRoot

        if ($Scenario -eq 'local-ai') {
            $installedWorkloads = Join-Path $InstallRoot 'Workloads'
            $installedWindowsConfig = Join-Path $InstallRoot 'windows-dev-config'
            Remove-Item -LiteralPath $installedWorkloads -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $installedWindowsConfig -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $workloadsDir -Destination $installedWorkloads -Recurse -Force
            New-Item -ItemType Directory -Path $installedWindowsConfig -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $setupDir 'steps') -Destination $installedWindowsConfig -Recurse -Force
        } else {
            # Keep logs and progress when replacing setup scripts.
            Copy-Item -LiteralPath (Join-Path $setupDir 'dev-config.ps1') -Destination $InstallRoot -Force
            Copy-Item -LiteralPath (Join-Path $setupDir 'steps') -Destination $InstallRoot -Recurse -Force
        }
        Assert-DevConfigProtectedTree -Directory $InstallRoot
        if (-not $AllowUnsigned) {
            Assert-DevConfigMicrosoftSigned -Directory $InstallRoot
            if ($Scenario -eq 'local-ai') {
                . (Join-Path $InstallRoot 'Workloads\_common\content-hashes.ps1')
                Assert-DevConfigWorkloadContent -WorkloadsRoot (Join-Path $InstallRoot 'Workloads')
            }
        }
        Get-ChildItem -LiteralPath $InstallRoot -Recurse -Filter '*.ps1' -File | Unblock-File

        # Clean up before setup can reboot.
        Remove-Item -LiteralPath $work -Recurse -Force
        $target = if ($Scenario -eq 'local-ai') {
            Join-Path $InstallRoot 'Workloads\local-ai\install.ps1'
        } else {
            Join-Path $InstallRoot 'dev-config.ps1'
        }
        Write-Host "  Ready in $InstallRoot" -ForegroundColor DarkGray

        if ($NoLaunch) {
            $escapedTarget = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($target)
            $command = "& '$escapedShell' $($arguments -join ' ') -File '$escapedTarget'"
            if ($Scenario -eq 'local-ai') {
                $command += " -Backend '$AiBackend' -Runtime '$AiRuntime'"
                if ($AiRequireTriton) { $command += ' -RequireTriton' }
                if ($PlanOnly) { $command += ' -PlanOnly' }
                if ($ReportRoot) {
                    $escapedReportRoot = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($ReportRoot)
                    $command += " -ReportRoot '$escapedReportRoot'"
                }
            } elseif ($AllowUnsigned) {
                $command += ' -AllowUnsigned'
            }
            Write-Host "Run when ready: $command" -ForegroundColor Cyan
            return
        }

        $arguments += '-File', "`"$target`""
        if ($Scenario -eq 'local-ai') {
            $arguments += '-Backend', $AiBackend, '-Runtime', $AiRuntime
            if ($AiRequireTriton) { $arguments += '-RequireTriton' }
            if ($PlanOnly) { $arguments += '-PlanOnly' }
            if ($ReportRoot) { $arguments += '-ReportRoot', "`"$ReportRoot`"" }
        } elseif ($AllowUnsigned) {
            $arguments += '-AllowUnsigned'
        }
        $proc = Start-Process -FilePath $shell -ArgumentList $arguments -NoNewWindow -Wait -PassThru

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
