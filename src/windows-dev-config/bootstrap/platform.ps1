Set-StrictMode -Version Latest

function Get-SlipstreamWinGetCommand {
    $package = Get-AppxPackage `
        -Name Microsoft.DesktopAppInstaller `
        -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $package) {
        return $null
    }

    if ($package.PublisherId -ne '8wekyb3d8bbwe' -or
        $package.Publisher -notmatch 'O=Microsoft Corporation') {
        throw "The registered App Installer package has an unexpected publisher: $($package.Publisher)"
    }

    $wingetPath = Join-Path $package.InstallLocation 'winget.exe'
    $windowsAppsRoot = Join-Path `
        ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) `
        'WindowsApps'
    $trustedRoot = [IO.Path]::GetFullPath($windowsAppsRoot).TrimEnd('\') + '\'
    $fullPath = [IO.Path]::GetFullPath($wingetPath)
    if (-not $fullPath.StartsWith(
        $trustedRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "App Installer resolved outside the protected WindowsApps directory: $fullPath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return $null
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $fullPath
    if ($signature.Status -ne 'Valid' -or
        $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "winget.exe does not have a valid Microsoft signature: $($signature.Status)"
    }
    return $fullPath
}

function Get-SlipstreamWinGetVersion {
    $winget = Get-SlipstreamWinGetCommand
    if (-not $winget) {
        return $null
    }

    try {
        $output = @(& $winget --version 2>$null)
        $exitCode = $LASTEXITCODE
    }
    catch {
        return $null
    }
    $versionLine = $output | Select-Object -First 1
    if ($exitCode -ne 0 -or -not $versionLine) {
        return $null
    }
    $raw = $versionLine.ToString().Trim()
    if ($raw -notmatch '^v?(\d+\.\d+\.\d+)') {
        return $null
    }
    return [version]$Matches[1]
}

function Install-SlipstreamWinGetRelease {
    param([Parameter(Mandatory)] [object] $State)

    Write-SlipstreamLog `
        -RunId $State.runId `
        -Level WARN `
        -Message 'Falling back to the latest signed WinGet GitHub release.'

    $headers = @{
        'User-Agent' = 'Microsoft-WindowsDeveloperConfig'
        'Accept' = 'application/vnd.github+json'
    }
    $release = Invoke-RestMethod `
        -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' `
        -Headers $headers `
        -UseBasicParsing `
        -ErrorAction Stop

    $bundleAsset = $release.assets |
        Where-Object name -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle' |
        Select-Object -First 1
    $dependenciesAsset = $release.assets |
        Where-Object name -eq 'DesktopAppInstaller_Dependencies.zip' |
        Select-Object -First 1
    if (-not $bundleAsset -or -not $dependenciesAsset) {
        throw "WinGet release $($release.tag_name) is missing required assets."
    }
    if ($bundleAsset.digest -notmatch '^sha256:([0-9a-fA-F]{64})$' -or
        $dependenciesAsset.digest -notmatch '^sha256:([0-9a-fA-F]{64})$') {
        throw "WinGet release $($release.tag_name) did not publish SHA256 asset digests."
    }
    $bundleHash = $bundleAsset.digest.Substring(7).ToUpperInvariant()
    $dependenciesHash = $dependenciesAsset.digest.Substring(7).ToUpperInvariant()

    $workDirectory = Join-Path `
        (Get-SlipstreamRunRoot -RunId $State.runId) `
        "winget-$($release.tag_name)"
    $bundlePath = Join-Path $workDirectory $bundleAsset.name
    $dependenciesZip = Join-Path $workDirectory $dependenciesAsset.name
    $dependenciesRoot = Join-Path $workDirectory 'dependencies'

    New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
    try {
        Get-SlipstreamDownload `
            -State $State `
            -Uri $bundleAsset.browser_download_url `
            -Destination $bundlePath `
            -Sha256 $bundleHash
        Get-SlipstreamDownload `
            -State $State `
            -Uri $dependenciesAsset.browser_download_url `
            -Destination $dependenciesZip `
            -Sha256 $dependenciesHash
        Expand-Archive `
            -LiteralPath $dependenciesZip `
            -DestinationPath $dependenciesRoot `
            -Force

        $nativeArchitecture = @(
            $env:PROCESSOR_ARCHITECTURE,
            $env:PROCESSOR_ARCHITEW6432
        ) -join ';'
        $architecture = if ($nativeArchitecture -match '(?i)ARM64') {
            'arm64'
        }
        else {
            'x64'
        }
        $dependencyPaths = @(
            Get-ChildItem `
                -LiteralPath (Join-Path $dependenciesRoot $architecture) `
                -Filter *.appx `
                -File |
                Select-Object -ExpandProperty FullName
        )
        if ($dependencyPaths.Count -eq 0) {
            throw "No $architecture WinGet dependencies were present in the release."
        }

        Add-AppxPackage `
            -Path $bundlePath `
            -DependencyPath $dependencyPaths `
            -ForceApplicationShutdown `
            -ForceUpdateFromAnyVersion `
            -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $workDirectory) {
            Remove-Item -LiteralPath $workDirectory -Recurse -Force
        }
    }
}

function Invoke-SlipstreamPreflight {
    param(
        [Parameter(Mandatory)] [object] $State,
        [switch] $AllowUnsigned
    )

    if (-not (Test-SlipstreamAdministrator)) {
        throw 'Slipstream controller must run elevated.'
    }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.User.Value -ne $State.originalUserSid) {
        throw @"
The elevated process is running as a different account.
Started as: $($State.originalUserName) ($($State.originalUserSid))
Elevated as: $($identity.Name) ($($identity.User.Value))

Slipstream requires an administrator account with a UAC split token so it can
resume as the same user after reboot without storing another account's password.
"@
    }

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'Windows Developer Config requires 64-bit Windows 11.'
    }
    if (-not [Environment]::Is64BitProcess) {
        throw 'Slipstream must run in 64-bit Windows PowerShell.'
    }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    if ([int]$os.BuildNumber -lt 22000) {
        throw "Windows 11 build 22000 or later is required. Found build $($os.BuildNumber)."
    }

    $systemDrive = Get-PSDrive -Name $env:SystemDrive.TrimEnd(':') -ErrorAction Stop
    $freeGb = [math]::Round($systemDrive.Free / 1GB, 1)
    if ($freeGb -lt 15) {
        throw "At least 15 GB free on $env:SystemDrive is required. Found ${freeGb} GB."
    }

    foreach ($command in @(
        'New-ScheduledTask',
        'Register-ScheduledTask',
        'Get-WindowsOptionalFeature'
    )) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required inbox Windows command is unavailable: $command"
        }
    }

    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller'
    foreach ($policyName in @('EnableAppInstaller', 'EnableWindowsPackageManagerCommandLineInterfaces')) {
        $value = Get-ItemPropertyValue `
            -Path $policyPath `
            -Name $policyName `
            -ErrorAction SilentlyContinue
        if ($null -ne $value -and [int]$value -eq 0) {
            throw "Windows Package Manager is disabled by policy: $policyPath\$policyName = 0"
        }
    }

    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cpu -and $computer -and
        -not $cpu.VirtualizationFirmwareEnabled -and
        -not $computer.HypervisorPresent) {
        Write-SlipstreamLog `
            -RunId $State.runId `
            -Level WARN `
            -Message 'Hardware virtualization was not reported as enabled. WSL may require a BIOS/VM-host change.'
    }

    $payload = Test-SlipstreamPayload `
        -PayloadRoot $State.payloadRoot `
        -AllowUnsigned:$AllowUnsigned
    Write-SlipstreamLog `
        -RunId $State.runId `
        -Message "Preflight passed: Windows build $($os.BuildNumber), ${freeGb} GB free, $($payload.Packages) packages, $($payload.RegistryValues) registry values."

    return New-SlipstreamPhaseResult
}

function Repair-SlipstreamWinGet {
    param([Parameter(Mandatory)] [object] $State)

    Write-SlipstreamLog `
        -RunId $State.runId `
        -Level WARN `
        -Message 'WinGet is missing or too old. Installing the latest signed App Installer release.'

    Install-SlipstreamWinGetRelease -State $State

    Start-Sleep -Seconds 3
    Refresh-SlipstreamPath
    $version = Get-SlipstreamWinGetVersion
    if (-not $version) {
        throw 'WinGet repair completed, but winget.exe is still unavailable for the interactive user.'
    }
    Write-SlipstreamLog -RunId $State.runId -Message "WinGet repaired successfully: $version"
}

function Invoke-SlipstreamPlatformRepair {
    param([Parameter(Mandatory)] [object] $State)

    $minimumVersion = [version]'1.6.0'
    $version = Get-SlipstreamWinGetVersion
    if (-not $version -or $version -lt $minimumVersion) {
        Repair-SlipstreamWinGet -State $State
        $version = Get-SlipstreamWinGetVersion
    }

    if (-not $version -or $version -lt $minimumVersion) {
        throw "WinGet $minimumVersion or later is required. Found: $version"
    }

    Write-SlipstreamLog -RunId $State.runId -Message "WinGet ready: $version"
    $winget = Get-SlipstreamWinGetCommand
    $sourceResult = Invoke-SlipstreamNative `
        -RunId $State.runId `
        -FilePath $winget `
        -ArgumentList @('source', 'update', '--name', 'winget', '--disable-interactivity') `
        -Name 'Update WinGet sources' `
        -MaxAttempts 3 `
        -AllowAnyExitCode
    if ($sourceResult.ExitCode -ne 0) {
        Write-SlipstreamLog `
            -RunId $State.runId `
            -Level WARN `
            -Message "WinGet source update failed with $($sourceResult.ExitCodeHex); checking the cached source."
        $probe = Invoke-SlipstreamNative `
            -RunId $State.runId `
            -FilePath $winget `
            -ArgumentList @(
                'show', '--id', 'Git.Git', '--exact', '--source', 'winget',
                '--disable-interactivity', '--accept-source-agreements'
            ) `
            -Name 'Probe cached WinGet source' `
            -AllowAnyExitCode
        if ($probe.ExitCode -ne 0) {
            throw "WinGet source is unusable after update failure: $($probe.ExitCodeHex)"
        }
    }

    return New-SlipstreamPhaseResult
}

function Invoke-SlipstreamPendingRebootGate {
    param([Parameter(Mandatory)] [object] $State)

    $reasons = @(Get-SlipstreamPendingRebootReasons)
    if ($reasons.Count -eq 0) {
        Write-SlipstreamLog -RunId $State.runId -Message 'No pre-existing pending restart detected.'
        return New-SlipstreamPhaseResult
    }

    $priorPendingRestart = @($State.rebootHistory) |
        Where-Object { $_ -like 'PendingReboot:*' } |
        Select-Object -First 1
    if ($priorPendingRestart) {
        Write-SlipstreamLog `
            -RunId $State.runId `
            -Level WARN `
            -Message "Pending restart markers remain after a setup restart; treating them as stale: $($reasons -join ', ')"
        return New-SlipstreamPhaseResult
    }

    return New-SlipstreamPhaseResult `
        -RebootRequired `
        -Reason ('PendingReboot:' + ($reasons -join ','))
}

function Test-SlipstreamWslPlatformReady {
    try {
        $wsl = Get-WindowsOptionalFeature `
            -Online `
            -FeatureName Microsoft-Windows-Subsystem-Linux `
            -ErrorAction Stop
        $vmp = Get-WindowsOptionalFeature `
            -Online `
            -FeatureName VirtualMachinePlatform `
            -ErrorAction Stop
        $vmcompute = Get-CimInstance `
            -ClassName Win32_Service `
            -Filter "Name='vmcompute'" `
            -ErrorAction SilentlyContinue
        return $wsl.State -eq 'Enabled' -and
            $vmp.State -eq 'Enabled' -and
            [bool]$vmcompute
    }
    catch {
        return $false
    }
}

function Invoke-SlipstreamWslPlatform {
    param([Parameter(Mandatory)] [object] $State)

    if (Test-SlipstreamWslPlatformReady) {
        Write-SlipstreamLog -RunId $State.runId -Message 'WSL platform features are already active.'
        return New-SlipstreamPhaseResult
    }

    $wslPath = Join-Path $env:SystemRoot 'System32\wsl.exe'
    $result = Invoke-SlipstreamNative `
        -RunId $State.runId `
        -FilePath $wslPath `
        -ArgumentList @('--install', '--no-distribution') `
        -Name 'Enable WSL platform' `
        -AllowAnyExitCode

    if ($result.ExitCode -notin @(0, 3010, 1641)) {
        throw "wsl --install --no-distribution failed: $($result.ExitCodeHex)"
    }

    if ($result.ExitCode -in @(3010, 1641) -or -not (Test-SlipstreamWslPlatformReady)) {
        return New-SlipstreamPhaseResult `
            -RebootRequired `
            -Reason 'EnableWslPlatform'
    }

    return New-SlipstreamPhaseResult
}

function Get-SlipstreamWslDistros {
    $previousUtf8 = $env:WSL_UTF8
    try {
        $env:WSL_UTF8 = '1'
        $output = & (Join-Path $env:SystemRoot 'System32\wsl.exe') --list --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            return @()
        }
        return @($output |
            ForEach-Object { ($_ -replace "`0", '').Trim() } |
            Where-Object { $_ })
    }
    finally {
        $env:WSL_UTF8 = $previousUtf8
    }
}

function Invoke-SlipstreamWslDistro {
    param([Parameter(Mandatory)] [object] $State)

    $distroName = 'Ubuntu'
    if (@(Get-SlipstreamWslDistros) -contains $distroName) {
        Write-SlipstreamLog -RunId $State.runId -Message "$distroName is already registered with WSL."
        return New-SlipstreamPhaseResult
    }

    $lxssPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    New-Item -Path $lxssPath -Force | Out-Null
    New-ItemProperty `
        -Path $lxssPath `
        -Name OOBEComplete `
        -Value 1 `
        -PropertyType DWord `
        -Force | Out-Null

    $result = Invoke-SlipstreamNative `
        -RunId $State.runId `
        -FilePath (Join-Path $env:SystemRoot 'System32\wsl.exe') `
        -ArgumentList @('--install', '--distribution', $distroName, '--no-launch') `
        -Name "Install WSL distro $distroName" `
        -MaxAttempts 3 `
        -AllowAnyExitCode

    if ($result.ExitCode -in @(3010, 1641)) {
        return New-SlipstreamPhaseResult `
            -RebootRequired `
            -AdvancePhase:$false `
            -Reason 'InstallWslDistro'
    }
    if ($result.ExitCode -ne 0) {
        throw "WSL distro installation failed: $($result.ExitCodeHex)"
    }

    Start-Sleep -Seconds 2
    if (@(Get-SlipstreamWslDistros) -notcontains $distroName) {
        throw "$distroName installation returned success but the distro is not registered."
    }
    return New-SlipstreamPhaseResult
}
