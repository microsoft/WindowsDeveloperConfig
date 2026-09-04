$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-DevConfigArchitecture {
    [CmdletBinding()]
    param([ValidateSet('', 'X64', 'Arm64')] [string] $Override = '')

    if ($Override) {
        return $Override
    }

    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    switch ($architecture) {
        'X64' { return 'X64' }
        'Arm64' { return 'Arm64' }
        default { throw "Unsupported Windows architecture '$architecture'. Supported architectures: X64, Arm64." }
    }
}

function Assert-DevConfigArchitecture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Architecture,
        [Parameter(Mandatory)] [string[]] $Supported,
        [Parameter(Mandatory)] [string] $Component
    )

    if ($Architecture -notin $Supported) {
        throw "$Component does not publish a compatible Windows artifact for $Architecture. Supported architectures: $($Supported -join ', ')."
    }
}

function Get-WindowsBuildNumber {
    [CmdletBinding()]
    param()

    return [Environment]::OSVersion.Version.Build
}

function Resolve-FoundryInstallPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture,
        [Parameter(Mandatory)] [int] $WindowsBuild
    )

    if ($WindowsBuild -lt 26100) {
        throw "Foundry Local's Windows/WinML path requires Windows 11 24H2 (build 26100) or later; detected build $WindowsBuild."
    }

    return [pscustomobject]@{
        Architecture = $Architecture
        PackageId = 'Microsoft.FoundryLocal'
        RequiresCuda = $false
    }
}

function Resolve-LlamaCppInstallPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture)

    if ($Architecture -eq 'X64') {
        return [pscustomobject]@{
            Method = 'WinGet'
            PackageId = 'ggml.llamacpp'
            AssetPattern = $null
            Backend = 'Vulkan'
        }
    }

    return [pscustomobject]@{
        Method = 'GitHubRelease'
        PackageId = $null
        AssetPattern = '^llama-b[0-9]+-bin-win-cpu-arm64\.zip$'
        Backend = 'CPU'
    }
}

function Resolve-OllamaInstallPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture)

    if ($Architecture -eq 'X64') {
        return [pscustomobject]@{
            PackageId = 'Ollama.Ollama'
            ConfigurationName = 'configuration.winget'
            LaunchMode = 'Desktop'
        }
    }

    return [pscustomobject]@{
        PackageId = 'Ollama.Ollama.Portable'
        ConfigurationName = 'configuration.arm64.winget'
        LaunchMode = 'Serve'
    }
}

function Get-NvidiaGpu {
    [CmdletBinding()]
    param()

    $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    return $controllers |
        Where-Object { $_.PNPDeviceID -match 'VEN_10DE' -or $_.Name -match 'NVIDIA' } |
        Select-Object -First 1
}

function Get-NvidiaDriverInfo {
    [CmdletBinding()]
    param()

    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
        return $null
    }

    $output = & nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader,nounits 2>$null |
        Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
        return $null
    }

    $parts = @($output -split ',' | ForEach-Object { $_.Trim() })
    if ($parts.Count -lt 3) {
        throw "nvidia-smi returned an unexpected result: $output"
    }

    $driver = [version]$parts[1]
    $compute = [version]$parts[2]
    return [pscustomobject]@{
        Name = $parts[0]
        DriverVersion = $driver
        DriverMajor = $driver.Major
        ComputeCapability = $compute
    }
}

function Get-CudaReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool] $ToolkitAvailable,
        [Parameter(Mandatory)] [bool] $NvidiaGpuPresent,
        [Parameter(Mandatory)] [bool] $DriverAvailable
    )

    return [pscustomobject]@{
        ToolkitReady = $ToolkitAvailable
        GpuReady = $NvidiaGpuPresent -and $DriverAvailable
        Status = if (-not $ToolkitAvailable) {
            'ToolkitMissing'
        } elseif (-not $NvidiaGpuPresent) {
            'ToolkitOnlyNoGpu'
        } elseif (-not $DriverAvailable) {
            'ToolkitOnlyDriverUnavailable'
        } else {
            'Ready'
        }
    }
}

function Resolve-PyTorchPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture,
        [Parameter(Mandatory)] [ValidateSet('Auto', 'CPU', 'CUDA')] [string] $Backend,
        [Parameter(Mandatory)] [version] $PythonVersion,
        [bool] $HasNvidia = $false,
        [int] $DriverMajor = 0,
        [version] $ComputeCapability = [version]'0.0',
        [switch] $SkipTriton
    )

    if ($Architecture -eq 'Arm64') {
        if ($PythonVersion -lt [version]'3.11' -or $PythonVersion -ge [version]'3.14') {
            throw "PyTorch 2.14 Windows ARM64 wheels require CPython 3.11-3.13; detected $PythonVersion."
        }
        if ($Backend -eq 'CUDA') {
            throw 'Official stable PyTorch CUDA wheels are not published for Windows ARM64. Use the CPU backend.'
        }
        $selectedBackend = 'CPU'
    } else {
        if ($PythonVersion -lt [version]'3.10' -or $PythonVersion -ge [version]'3.15') {
            throw "PyTorch 2.14 Windows x64 wheels require CPython 3.10-3.14; detected $PythonVersion."
        }

        if ($Backend -eq 'CUDA' -and -not $HasNvidia) {
            throw "CUDA backend was requested, but nvidia-smi did not report a usable NVIDIA GPU and driver."
        }
        if ($Backend -eq 'CUDA' -and $DriverMajor -lt 525) {
            throw "CUDA backend was requested, but NVIDIA driver branch $DriverMajor is too old. Install a branch 525 or newer driver."
        }
        $selectedBackend = if ($Backend -eq 'Auto') {
            if ($HasNvidia -and $DriverMajor -ge 525) { 'CUDA' } else { 'CPU' }
        } else {
            $Backend
        }
    }

    $indexUrl = 'https://download.pytorch.org/whl/cpu'
    $runtime = 'cpu'
    if ($selectedBackend -eq 'CUDA') {
        if ($ComputeCapability.Major -ge 10 -and $DriverMajor -lt 580) {
            throw "This NVIDIA GPU reports compute capability $ComputeCapability and needs a CUDA 13 wheel, but driver branch $DriverMajor is below 580. Update the NVIDIA driver."
        }
        if ($DriverMajor -ge 580) {
            $runtime = 'cu130'
            $indexUrl = 'https://download.pytorch.org/whl/cu130'
        } else {
            $runtime = 'cu126'
            $indexUrl = 'https://download.pytorch.org/whl/cu126'
        }
    }

    $installTriton = $selectedBackend -eq 'CUDA' -and
        $Architecture -eq 'X64' -and
        $ComputeCapability.Major -ge 8 -and
        -not $SkipTriton

    return [pscustomobject]@{
        Architecture = $Architecture
        Backend = $selectedBackend
        TorchRequirement = 'torch==2.14.0'
        IndexUrl = $indexUrl
        Runtime = $runtime
        InstallTriton = $installTriton
        TritonRequirement = if ($installTriton) { 'triton-windows>=3.8,<3.9' } else { $null }
        TritonReason = if ($installTriton) {
            'Compatible PyTorch CUDA, CPython, architecture, and NVIDIA compute capability detected.'
        } elseif ($selectedBackend -ne 'CUDA') {
            'Triton Windows is only installed for the CUDA backend.'
        } elseif ($Architecture -ne 'X64') {
            'The stable PyTorch CUDA stack is unavailable on Windows ARM64.'
        } elseif ($ComputeCapability.Major -lt 8) {
            "Triton Windows requires NVIDIA compute capability 8.0 or newer; detected $ComputeCapability."
        } else {
            'Triton installation was disabled by the caller.'
        }
    }
}

function Assert-PythonArchitecture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture,
        [Parameter(Mandatory)] [string] $PythonMachine
    )

    $normalized = switch -Regex ($PythonMachine) {
        '^(AMD64|x86_64)$' { 'X64'; break }
        '^(ARM64|aarch64)$' { 'Arm64'; break }
        default { $PythonMachine }
    }
    if ($normalized -ne $Architecture) {
        throw "Python architecture '$PythonMachine' does not match Windows architecture '$Architecture'. Remove emulated or conflicting Python installations and rerun the flow."
    }
}

function Get-PipInstallArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Requirement,
        [string] $IndexUrl,
        [switch] $DryRun
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    [void]$arguments.Add('-m')
    [void]$arguments.Add('pip')
    [void]$arguments.Add('install')
    if ($DryRun) {
        [void]$arguments.Add('--dry-run')
    }
    [void]$arguments.Add('--only-binary=:all:')
    [void]$arguments.Add($Requirement)
    if ($IndexUrl) {
        [void]$arguments.Add('--index-url')
        [void]$arguments.Add($IndexUrl)
    }
    return $arguments.ToArray()
}

function Invoke-CheckedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $ArgumentList = @(),
        [string] $DisplayName = $FilePath
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$DisplayName failed with exit code $LASTEXITCODE."
    }
}

function Assert-CommandAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CommandName,
        [Parameter(Mandatory)] [string] $Remediation
    )

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "$CommandName was not found. $Remediation"
    }
    return $command
}

function Add-UserPathEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($current -split ';' | Where-Object { $_ })
    if ($Path -notin $entries) {
        $newPath = (@($entries) + $Path) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    }
    if ($Path -notin @($env:Path -split ';')) {
        $env:Path = "$Path;$env:Path"
    }
}

function Install-VerifiedGitHubReleaseAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $AssetPattern,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $VersionMarker,
        [Parameter(Mandatory)] [string] $RequiredFile
    )

    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'WindowsDeveloperConfig'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if ($env:GITHUB_TOKEN) {
        $headers.Authorization = "Bearer $env:GITHUB_TOKEN"
    }
    # llama.cpp marks an old semantic release as GitHub "latest" while current
    # Windows binaries are rolling bNNNNN releases. Select the newest published
    # release that actually contains the requested artifact.
    try {
        $releases = @(Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases?per_page=20" -Headers $headers)
    } catch {
        throw "Could not query official releases for $Repository. GitHub may be unavailable or rate-limiting this network. Wait for the rate limit to reset, or set GITHUB_TOKEN for authenticated API access. $($_.Exception.Message)"
    }
    $release = $releases |
        Where-Object { -not $_.draft -and @($_.assets | Where-Object { $_.name -match $AssetPattern }).Count -eq 1 } |
        Select-Object -First 1
    if (-not $release) {
        throw "No published $Repository release among the 20 newest releases contains an asset matching '$AssetPattern'."
    }

    $asset = @($release.assets | Where-Object { $_.name -match $AssetPattern })
    if ($asset.Count -ne 1) {
        throw "Expected exactly one asset matching '$AssetPattern' in $Repository release $($release.tag_name); found $($asset.Count)."
    }
    $asset = $asset[0]
    if ($asset.digest -notmatch '^sha256:([0-9a-fA-F]{64})$') {
        throw "GitHub did not publish a SHA-256 digest for asset '$($asset.name)'; refusing an unverified download."
    }
    $expectedHash = $Matches[1]

    $markerPath = Join-Path $Destination $VersionMarker
    if ((Test-Path -LiteralPath $markerPath) -and
        (Test-Path -LiteralPath (Join-Path $Destination $RequiredFile)) -and
        ((Get-Content -LiteralPath $markerPath -Raw).Trim() -eq $release.tag_name)) {
        return $release.tag_name
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "devconfig-$([guid]::NewGuid().ToString('N'))"
    $archivePath = Join-Path $tempRoot $asset.name
    $extractPath = Join-Path $tempRoot 'expanded'
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $archivePath -UseBasicParsing
        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        if ($actualHash -ne $expectedHash) {
            throw "SHA-256 mismatch for '$($asset.name)'. Expected $expectedHash; got $actualHash."
        }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Copy-Item -Path (Join-Path $extractPath '*') -Destination $Destination -Recurse -Force
        Set-Content -LiteralPath $markerPath -Value $release.tag_name -Encoding ascii
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }

    return $release.tag_name
}

function Wait-JsonEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [uri] $Uri,
        [int] $TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            return Invoke-RestMethod -Uri $Uri -TimeoutSec 5
        } catch {
            Start-Sleep -Seconds 1
        }
    } while ((Get-Date) -lt $deadline)

    throw "Endpoint '$Uri' did not become ready within $TimeoutSeconds seconds."
}
