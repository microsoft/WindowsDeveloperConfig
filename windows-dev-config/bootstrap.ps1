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
#>

[CmdletBinding()]
param(
    [string] $Ref = 'main',
    [string] $InstallRoot,
    [switch] $AllowUnsigned,
    [switch] $NoLaunch,
    [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
    [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig'
)

function Invoke-CalmOsBootstrap {
    [CmdletBinding()]
    param(
        [string] $Ref = 'main',
        [string] $InstallRoot,
        [switch] $AllowUnsigned,
        [switch] $NoLaunch,
        [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
        [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig'
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

    $repo = 'microsoft/WindowsDeveloperConfig'
    $microsoftSignerSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    $Workload = $Workload.ToLowerInvariant()
    # The default workload is omitted from command lines so refs that predate workloads still accept them.
    $workloadSuffix = if ($Workload -ne 'devconfig') { " -Workload $Workload" } else { '' }

    # Reject refs that could escape the repository path.
    if ($Ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $Ref.Contains('..')) {
        throw "'$Ref' is not a valid branch, tag or commit name. Use letters, digits, and . _ - / only."
    }

    if (-not $InstallRoot) {
        $InstallRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'CalmOS'
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
            [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig'
        )

        $launcher = {
            param(
                [string] $Ref,
                [string] $InstallRoot,
                [switch] $AllowUnsigned,
                [switch] $NoLaunch,
                [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
                [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig'
            )

            $ErrorActionPreference = 'Stop'
            Set-StrictMode -Version Latest
            # A child shell can inherit incompatible built-in modules from another PowerShell edition.
            $env:PSModulePath = "$PSHOME\Modules;$env:PSModulePath"
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
            $arguments += '-File', $target, '-Ref', $Ref, '-InstallRoot', $InstallRoot, '-Action', $Action
            if ($Workload -ne 'devconfig') { $arguments += '-Workload', $Workload }
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
            "& {`n$launcher`n} -Ref '$escapedRef' -InstallRoot '$escapedRoot' -Action '$Action'"
        if ($Workload -ne 'devconfig') { $command += " -Workload '$Workload'" }
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
        if ($Workload -ne 'devconfig') {
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
        $command = Get-CalmOsElevationCommand -Ref $Ref -InstallRoot $InstallRoot -AllowUnsigned:$AllowUnsigned -NoLaunch:$NoLaunch -Action $Action -Workload $Workload
        Write-Host 'Setup needs Administrator rights (a UAC prompt will appear)...' -ForegroundColor Yellow
        $proc = Start-Process -FilePath $shell -ArgumentList ($arguments + @('-Command', $command)) -Verb RunAs -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            throw "Elevated setup exited with code $($proc.ExitCode). No further setup was started."
        }
        if ($NoLaunch) {
            $escapedTarget = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent((Join-Path $InstallRoot 'dev-config.ps1'))
            Write-Host "Run when ready: & '$escapedShell' $($arguments -join ' ') -File '$escapedTarget' -Action $Action$workloadSuffix$(if ($AllowUnsigned) { ' -AllowUnsigned' })"
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
    if ($Workload -eq 'devconfig') {
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
# MIInNwYJKoZIhvcNAQcCoIInKDCCJyQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAo9c+YHVgsOz8s
# /NoYHF/NQryZzDxGxr7QQB1cnOJabKCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIDPx8YHxvLUlADerl8E6aeHvtqqB
# MS/VUGZftX6AdpmiMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAz53FQ42/dPvqodP3fxwIA8RVQAaRGv4fbx5RZP+BxWPOYen8TN5YeRTCwr8h
# 2PGKcuYgxvmknqbBSGJVDuXwSxF8tK3GBTI9BIQ2S1ZNzOilp6bBlQ0+yViUWgKq
# agg0zujDI1Q8BNIfhH8Dw+Pzox8EZcqzwobum9A7lfmfJlWtx8aOHan4MtlzM8w3
# oKZhqyIPSLgputFSQhJ/EfXAXtdbbBIGRtR6OZ9pvRWQNt4kBDz2bdABhw/3Ma1g
# FpPb4+Thaeeu9ugdj3zLZbiC2Hhdk+z9wnEnfZHm6VwQIYtD4nFIc7DkAdphWDBj
# R9wGzehtxAuyH37JCO2bNjJTOKGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wG
# CSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCA3m3BLPj2hO0Nf9WhYjmdYEclu3yihvF+l4UwRsmZdZAIGaqppheEGGBMy
# MDI2MTAwNzAwMjgxNy43MjdaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTYwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHq
# MIIHIDCCBQigAwIBAgITMwAAAiY1tD5nQ5P2HwABAAACJjANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDJa
# Fw0yNzA1MTcxOTQwMDJaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTYwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQC//w+ZZIL5RFFpVI8D3ZyuNu8IzcAEOD30OLYjh337rXjc
# rIlOSzpJc4ZeUxEyli6x6F6zm4NR8dbPb9diDp/hOUzHWGxiA1Z3RXKBb/4F/ojy
# vN43SEGWqSfVc3I3BlsYT35ecVAJ9kVf90YOv29tFjJBBZkYvrT/DwwyRLscOyP4
# p+9/lyJjD+ULs3YXBhVrfZ+MbQB+BYKLqRvBKbj/wR9akNrMxQINoGaD5jZO/N/n
# SsmG2P1zv/cv4gSoMBnWeQIBkjd2I5w1DeXupp2vSiNmR5sA2ZkBK3yiQWaJvRxO
# DlkfiyHk9Mkk/TrYTjmjPCbhe+uqhHNRy8UlbOvWsCq0tRtUykHv39DgqAfJNrE8
# OSt835rBzDprrcAhwmgfhoVi4AKeqwikY0nUa48K0Qy80XT4fiEA3ExEZNaRFo9N
# q/GwbfgqKqGmc9xhKuRFcjtua4KHZvnAvpWgEFSOCkovXs/BcLnkEHM9xZ8iUag5
# CyhNqXYYE/z0pcXdYaNIkQ68EWmuvLm7g9oofV2vOm5GVNoghnkWG6nGPo/JwEgm
# A9oSS0EfvFRMWPA/gpSvF3shArKHnaEpVSSi3DNbyiuYiEs9Ko0IkZc8xKFeQRaq
# GRxrB+2r/7B3X81Tps99KhFwg+wD87od22F2MUg1x7twt3gaVnFk0IZIwUPCGwID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFF3hn9fYJN2Y/Z9LVbBPIxAzXHsQMB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQA2Ux0tr9sYCjsq0FRyiVpx15OurNXv6Qk7iX+A
# rVPlz3w4tqjcTNm1dt3tTua2wJMpJhPH8n7UXhmT98d5Du44Ll4adnse4SQfVg3Q
# L6aRkXHnJUn8y9iftB/Py22n9xnwPFfj3QlDOSgLuHleu97U0iH2ZaluYabWXJih
# diYpK8cPHFlqZOAiot0+GD8dP+RMuvpxt/F2LmYelpoZwriiFOUmlxEUV7xJHyZZ
# lDquskeyuq01DTv91N4qM8cfPPhl/2pc4HeMf/nd2HouifJbDQFNd4WPhLzn0Sy3
# u1Zh3+S3tjQdqN+dyw60RaV+RXCoOLgFZ3MAg/GoDl+fvb5hy/1a71ctX8wEad1P
# f6def2pqfl3wFc++hkF8DXXTZofJN4YVaN3InwbAGQDDkNK4lqecCixxmSKwidPy
# nGeE5OtvNoK1pkLsm/i8F1RjGczZ/kSF2VDkqG866iQ+jVbGOQ6Du3eyyFcFKZoD
# J4B5mEAS9aT2SKqllLeybOboH6r67siR5B/2Hnu7+KYuYZy0BEadtA6ngG4cnSR9
# JsrkhhsKmb11ujqwgJyNx92MsoGGwNgN1aI0QID8CsjCFwpfmMzlA44xHKYv3hmj
# xeqBS4uU5rQeiAnVgpJeaVGKm/lzPDtnppGV+7XhRp5b1ZxT/Z7Xxc+I7H7/jCtQ
# DZoaZTCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
# AQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAw
# BgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEw
# MB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk
# 4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9c
# T8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWG
# UNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6Gnsz
# rYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2
# LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLV
# wIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTd
# EonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0
# gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFph
# AXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJ
# YfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXb
# GjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJ
# KwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnP
# EP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMw
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggr
# BgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYw
# DwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoY
# xDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtp
# L2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYB
# BQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0B
# AQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U5
# 18JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgAD
# sAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo
# 32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZ
# iefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZK
# PmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RI
# LLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgk
# ujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9
# af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzba
# ukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/
# OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIIC
# NQIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjk2MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCi/fMx
# Ftkqr7XMXdsRyWU0lSKHZ6CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7m/rhzAiGA8yMDI2MTAwNjIxNDk1OVoY
# DzIwMjYxMDA3MjE0OTU5WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDub+uHAgEA
# MAcCAQACAjO1MAcCAQACAhB6MAoCBQDucT0HAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBAIuQZbBGWLHXcN7IMTrUZqjRZfPo+wsq1jLJhlBzYf+9MBwjq6e1
# c9AyeD4NR/GTlVGE2lCi/iQTsc7C8nanE9ptYBJhPQavNzm9wITLls2Gd9dveujO
# J8jAYGMYFoMCsIJACn3R79kxX0ir3qqOQ+QyKKzGHYrSydIcbGIlwfl4kfEFeoCQ
# ciU2/QdgjjmOaJaC35dnvvBrE01eAbsieb/hFjXByZmSkdh2w1bxyYvIEc6BeoSo
# 4KRci6g2QIR1YjkkDtGXjFNqLDOXk2cGLPr6SWR7yU1xvssaqDCCZv7G+LEuERCG
# foBy9osBPL2d30/p0NydO9lRCRuVe2147JwxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiY1tD5nQ5P2HwABAAACJjANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCDaZUW3vnk9mk5gBJHQlB1ywFm8CEM/qthkp1eereJgRjCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIMwyXGFnTNsZRBrs6GN/BbV0okaNP3VB
# YqLFjUsFnbgqMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAImNbQ+Z0OT9h8AAQAAAiYwIgQggaUg0muDVosM/R8hh4Gxg/lg7+GXQtgd
# 8qBjcw+8k2swDQYJKoZIhvcNAQELBQAEggIAh471vX19ukUhLng9+hWdsYMsI05D
# EXO5YcUjmzHIXkLOcPnxwi+q1a9bsvXH22EHE/OymfWGYL/XJ9Ap7/mc+7HbK4BX
# QlBMBAZBHKR0MzE4H+tLYzwWdkfP5wduw19OC9prhGiBtIDwkMS2r0ywN89tqW03
# hC3xU4A3I7rfv2Ey6Ji1YMbTytGzsbppue3gwK854P5CNj6fZj+zvUP64px85UGr
# G7IKzhe3Y+fKQcD3KROFZnObPD3gzVVGiZZdxRc+E9JhlMfm283R+1uu2udIrrU2
# 1MhcB2jauB9EZyZN0RlTbiSTlMvFO1z6b4tGCEwq/H05XNaV9A6xqj0s3gjR5HI3
# xkBLi9l3vL0IBzXucBYeWQmAGzyn6TIavViq5si9+AcUwdW0K956Msp/8dyOSg6h
# mupk/pMOis0JtzG6JpmAFb1MAr+dWAzQIXQvYcy4biSoY2j/WCS9adRWsAV4j158
# w8FsNVxASC3F8Pa00bsyg5Y7dntcwxUC0MNgkYdrRf9sKMbuOHc6YT3fuC9OqDjT
# PlgFmMierxK9nDjqggfk72b713VhOjOGO1WZAEfnL1g5vNQ0/xUU8v+zg/NATZa8
# cGw6laym9WK3UdpJJayx30ZeyglCKIWBx0J4oGCh/TR0RnvUnIwOyOUeW1zcaC0q
# RclqO4esZNSACZA=
# SIG # End signature block
