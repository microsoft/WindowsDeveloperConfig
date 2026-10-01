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
