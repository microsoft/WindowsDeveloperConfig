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

function Resolve-CudaInstallPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture,
        [int] $WindowsBuild = 26100
    )

    if ($Architecture -eq 'X64') {
        return [pscustomobject]@{
            Architecture = $Architecture
            Method = 'WinGet'
            ConfigurationName = 'configuration.winget'
            ToolkitVersion = '13.3'
            Preview = $false
            InstallerUrl = $null
            InstallerSha256 = $null
        }
    }

    if ($WindowsBuild -lt 22000) {
        throw "CUDA 13.4 Developer Preview for Windows ARM64 requires Windows 11; detected build $WindowsBuild."
    }

    return [pscustomobject]@{
        Architecture = $Architecture
        Method = 'NvidiaInstaller'
        ConfigurationName = 'configuration.arm64.winget'
        ToolkitVersion = '13.4'
        Preview = $true
        InstallerUrl = 'https://packages.nvidia.com/prerelease/cuda/13.4.0/local_installers/cuda_13.4.0_windows_arm64.exe'
        InstallerSha256 = 'a1f68c81160b16d519c4087788b9c07de41306c3f1b872471ceee0996621374d'
    }
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
    param(
        [Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture,
        [bool] $HasNvidia = $false,
        [int] $DriverMajor = 0,
        [version] $ComputeCapability = [version]'0.0'
    )

    if ($Architecture -eq 'X64') {
        return [pscustomobject]@{
            Method = 'WinGet'
            PackageId = 'ggml.llamacpp'
            AssetPattern = $null
            Backend = 'Vulkan'
        }
    }

    $useCuda = $HasNvidia -and $DriverMajor -ge 616 -and $ComputeCapability.Major -ge 12
    return [pscustomobject]@{
        Method = 'GitHubRelease'
        PackageId = $null
        AssetPatterns = if ($useCuda) {
            @(
                '^llama-b[0-9]+-bin-win-cuda-13\.4-arm64\.zip$',
                '^cudart-llama-bin-win-cuda-13\.4-arm64\.zip$'
            )
        } else {
            @('^llama-b[0-9]+-bin-win-cpu-arm64\.zip$')
        }
        Backend = if ($useCuda) { 'CUDA 13.4 Preview' } else { 'CPU' }
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

    $allOutput = @(& nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader,nounits 2>$null)
    if ($LASTEXITCODE -ne 0 -or $allOutput.Count -eq 0) {
        return $null
    }
    $output = $allOutput | Select-Object -First 1

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

        $canUseCudaPreview = $PythonVersion.Major -eq 3 -and
            $PythonVersion.Minor -eq 13 -and
            $HasNvidia -and
            $DriverMajor -ge 616 -and
            $ComputeCapability.Major -ge 12
        if ($Backend -eq 'CUDA' -and -not $canUseCudaPreview) {
            throw 'Windows ARM64 CUDA PyTorch requires CPython 3.13, an RTX Spark-class NVIDIA GPU (compute capability 12.x), and developer driver branch 616 or newer.'
        }
        if ($Backend -eq 'Auto' -and $HasNvidia -and -not $canUseCudaPreview) {
            throw 'An NVIDIA GPU is present on Windows ARM64, but it does not meet the CUDA 13.4 PyTorch Developer Preview requirements. Use -Backend CPU to explicitly accept CPU-only PyTorch.'
        }
        $selectedBackend = if ($Backend -eq 'Auto') {
            if ($canUseCudaPreview) { 'CUDA' } else { 'CPU' }
        } else {
            $Backend
        }
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
    $torchRequirement = 'torch==2.14.0'
    $preview = $false
    if ($selectedBackend -eq 'CUDA') {
        if ($Architecture -eq 'Arm64') {
            $runtime = 'cu134'
            $indexUrl = $null
            $preview = $true
            $torchRequirement = 'torch @ https://pypi.nvidia.com/nvtorch_oot_nightly/torch/torch-2.15.0.dev20260904%2Bcu134-cp313-cp313-win_arm64.whl#sha256=af0872854d183cb6894dbd5b1e5e9291875ce139d138b5fc0b501498828265d3'
        } elseif ($ComputeCapability.Major -ge 10 -and $DriverMajor -lt 580) {
            throw "This NVIDIA GPU reports compute capability $ComputeCapability and needs a CUDA 13 wheel, but driver branch $DriverMajor is below 580. Update the NVIDIA driver."
        } elseif ($DriverMajor -ge 580) {
            $runtime = 'cu130'
            $indexUrl = 'https://download.pytorch.org/whl/cu130'
        } else {
            $runtime = 'cu126'
            $indexUrl = 'https://download.pytorch.org/whl/cu126'
        }
    }

    $installTriton = $selectedBackend -eq 'CUDA' -and
        $ComputeCapability.Major -ge 8 -and
        -not $SkipTriton

    return [pscustomobject]@{
        Architecture = $Architecture
        Backend = $selectedBackend
        TorchRequirement = $torchRequirement
        IndexUrl = $indexUrl
        Runtime = $runtime
        Preview = $preview
        InstallTriton = $installTriton
        TritonRequirement = if ($installTriton) { 'triton-windows>=3.8,<3.9' } else { $null }
        TritonReason = if ($installTriton) {
            'Compatible PyTorch CUDA, CPython, architecture, and NVIDIA compute capability detected.'
        } elseif ($selectedBackend -ne 'CUDA') {
            'Triton Windows is only installed for the CUDA backend.'
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

function Get-Python313Path {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture)

    $candidates = [System.Collections.Generic.List[string]]::new()
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        $selector = if ($Architecture -eq 'Arm64') { '-3.13-arm64' } else { '-3.13-64' }
        $launcherPath = [string](& $launcher.Source $selector -c 'import sys; print(sys.executable)' 2>$null |
            Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and $launcherPath) {
            [void]$candidates.Add($launcherPath.Trim())
        }
    }
    foreach ($commandName in @('python3.13', 'python')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command) {
            [void]$candidates.Add($command.Source)
        }
    }
    foreach ($candidate in $candidates | Select-Object -Unique) {
        $version = [string](& $candidate -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>$null |
            Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and $version.Trim() -eq '3.13') {
            return $candidate
        }
    }
    throw "Native $Architecture CPython 3.13 was installed but could not be resolved. Disable conflicting App Execution Aliases or run the Python 3.13 installer repair."
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

function Get-FoundryModelSmokePlan {
    return [pscustomobject]@{
        Model = 'qwen3-0.6b'
        Marker = 'DEVCONFIG_FOUNDRY_READY'
        ApproximateDownloadMb = 593
        License = 'Apache-2.0'
    }
}

function Get-FoundryModelSmokeCommands {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Model,
        [Parameter(Mandatory)] [string] $Marker
    )

    return [pscustomobject]@{
        Download = @('model', 'download', $Model)
        Complete = @('complete', $Model, "Reply with exactly $Marker and nothing else. /no_think")
    }
}

function Get-OllamaModelSmokePlan {
    return [pscustomobject]@{
        Model = 'qwen3:0.6b'
        Marker = 'DEVCONFIG_OLLAMA_READY'
        ModelBlobSha256 = '7f4030143c1c477224c5434f8272c662a8b042079a0a584f0a27a1684fe2e1fa'
        ApproximateDownloadMb = 522
        License = 'Apache-2.0'
    }
}

function Get-OllamaModelManifestPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ModelRoot,
        [Parameter(Mandatory)] [string] $Model
    )

    $parts = $Model.Split(':', 2)
    $name = $parts[0]
    $tag = if ($parts.Count -eq 2) { $parts[1] } else { 'latest' }
    return Join-Path $ModelRoot "manifests\registry.ollama.ai\library\$name\$tag"
}

function Get-LlamaModelSmokePlan {
    return [pscustomobject]@{
        Repository = 'Qwen/Qwen3-0.6B-GGUF'
        Revision = 'ef4088322893040952513f532f736ddeab518403'
        FileName = 'Qwen3-0.6B-Q4_K_M.gguf'
        Url = 'https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/ef4088322893040952513f532f736ddeab518403/Qwen3-0.6B-Q4_K_M.gguf?download=true'
        Sha256 = 'b0638f08417a2d3c8652760462eb5407c6e30173cf9608ad0820757a281eea0e'
        Size = 396704416
        Marker = 'DEVCONFIG_LLAMA_READY'
        License = 'Apache-2.0'
    }
}

function New-OllamaGenerateRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Model,
        [Parameter(Mandatory)] [string] $Marker
    )

    return [ordered]@{
        model = $Model
        prompt = "Return a JSON object whose marker is $Marker. Nothing else."
        think = $false
        stream = $false
        format = [ordered]@{
            type = 'object'
            properties = [ordered]@{
                marker = [ordered]@{ type = 'string'; enum = @($Marker) }
            }
            required = @('marker')
            additionalProperties = $false
        }
        options = [ordered]@{
            seed = 42
            temperature = 0.7
            top_p = 0.8
            top_k = 20
            num_predict = 32
        }
    }
}

function Get-LlamaInferenceArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ModelPath,
        [Parameter(Mandatory)] [string] $Marker
    )

    return @(
        '--model', $ModelPath,
        '--single-turn',
        '--prompt', "Reply with exactly $Marker and nothing else.",
        '--reasoning', 'off',
        '--grammar', "root ::= `"$Marker`"",
        '--seed', '42',
        '--temperature', '0.7',
        '--top-p', '0.8',
        '--top-k', '20',
        '--threads', '1',
        '--threads-batch', '1',
        '--predict', '32',
        '--no-display-prompt',
        '--simple-io',
        '--log-disable'
    )
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

function Remove-UserPathEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($current -split ';' | Where-Object { $_ -and $_ -ne $Path })
    [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
    $processEntries = @($env:Path -split ';' | Where-Object { $_ -and $_ -ne $Path })
    $env:Path = $processEntries -join ';'
}

function Remove-TemporaryFileWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [int] $MaxAttempts = 12,
        [int] $DelayMilliseconds = 5000,
        [scriptblock] $RemoveAction = {
            param([string] $Target)
            Remove-Item -LiteralPath $Target -Force -ErrorAction Stop
        }
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            & $RemoveAction $Path
            if (-not (Test-Path -LiteralPath $Path)) {
                return $true
            }
            $lastError = "the file still exists after removal attempt $attempt"
        } catch {
            $lastError = $_.Exception.Message
        }
        if ($attempt -lt $MaxAttempts -and $DelayMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }

    Write-Warning `
        -Message "Could not remove temporary file '$Path' after $MaxAttempts attempts. It may remain until the installer releases it or Windows cleans the temporary directory. Last error: $lastError" `
        -WarningAction Continue
    return $false
}

function Install-VerifiedDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [uri] $Uri,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{64}$')] [string] $Sha256,
        [long] $ExpectedSize = 0
    )

    if (Test-Path -LiteralPath $Destination) {
        $existing = Get-Item -LiteralPath $Destination
        $existingHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        if ($existingHash -eq $Sha256 -and ($ExpectedSize -eq 0 -or $existing.Length -eq $ExpectedSize)) {
            return
        }
    }

    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = "$Destination.download-$([guid]::NewGuid().ToString('N'))"
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $temporary -UseBasicParsing
        $download = Get-Item -LiteralPath $temporary
        if ($ExpectedSize -gt 0 -and $download.Length -ne $ExpectedSize) {
            throw "Download size mismatch for '$Uri'. Expected $ExpectedSize bytes; got $($download.Length)."
        }
        $actualHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
        if ($actualHash -ne $Sha256) {
            throw "SHA-256 mismatch for '$Uri'. Expected $Sha256; got $actualHash."
        }
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            [void](Remove-TemporaryFileWithRetry -Path $temporary)
        }
    }
}

function Invoke-VerifiedInstaller {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [uri] $Uri,
        [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{64}$')] [string] $Sha256,
        [Parameter(Mandatory)] [string] $SignerPattern,
        [string[]] $ArgumentList = @(),
        [int[]] $SuccessExitCodes = @(0)
    )

    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) "devconfig-$([guid]::NewGuid().ToString('N')).exe"
    try {
        Install-VerifiedDownload -Uri $Uri -Destination $temporary -Sha256 $Sha256
        $signature = Get-AuthenticodeSignature -LiteralPath $temporary
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch $SignerPattern) {
            throw "Installer signature validation failed for '$Uri'. Expected a valid signer matching '$SignerPattern'; got '$($signature.Status)' from '$($signature.SignerCertificate.Subject)'."
        }
        $process = Start-Process -FilePath $temporary -ArgumentList $ArgumentList -Wait -PassThru
        if ($process.ExitCode -notin $SuccessExitCodes) {
            throw "Installer '$Uri' failed with exit code $($process.ExitCode)."
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            [void](Remove-TemporaryFileWithRetry -Path $temporary)
        }
    }
}

function Get-CudaNvccPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ToolkitVersion)

    $cudaPath = [Environment]::GetEnvironmentVariable('CUDA_PATH', 'Machine')
    $pathCommand = Get-Command nvcc -ErrorAction SilentlyContinue
    $candidates = @(
        (Join-Path $env:ProgramFiles "NVIDIA GPU Computing Toolkit\CUDA\v$ToolkitVersion\bin\nvcc.exe"),
        $(if ($cudaPath) { Join-Path $cudaPath 'bin\nvcc.exe' }),
        $(if ($pathCommand) { $pathCommand.Source })
    ) | Where-Object { $_ }

    $nvcc = $null
    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }
        $versionOutput = (& $candidate --version 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0 -and $versionOutput -match "release $([regex]::Escape($ToolkitVersion))") {
            $nvcc = $candidate
            break
        }
    }
    if (-not $nvcc) {
        throw "CUDA Toolkit $ToolkitVersion was installed, but a matching nvcc.exe was not found. Reopen the terminal and verify CUDA_PATH does not point to an older toolkit."
    }
    Add-UserPathEntry -Path (Split-Path -Parent $nvcc)
    return $nvcc
}

function Get-MsvcCompilerPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture)

    $vsDevCmd = Get-VsDevCmdPath -Architecture $Architecture
    $installationPath = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $vsDevCmd))
    $toolsRoot = Join-Path $installationPath 'VC\Tools\MSVC'
    $toolset = Get-ChildItem -LiteralPath $toolsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not $toolset) {
        throw "No MSVC toolset was found under '$toolsRoot'."
    }

    $relativeCandidates = if ($Architecture -eq 'Arm64') {
        @('bin\Hostarm64\arm64\cl.exe', 'bin\Hostx64\arm64\cl.exe')
    } else {
        @('bin\Hostx64\x64\cl.exe')
    }
    $compiler = $relativeCandidates |
        ForEach-Object { Join-Path $toolset.FullName $_ } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if (-not $compiler) {
        throw "The MSVC compiler for $Architecture was not found. Re-run the C++ Build Tools configuration."
    }
    return $compiler
}

function Get-VsDevCmdPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture)

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw 'Visual Studio Installer vswhere.exe was not found after installing the C++ Build Tools workload.'
    }
    $installationOutput = @(& $vswhere -all -products Microsoft.VisualStudio.Product.BuildTools -property installationPath 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "vswhere.exe failed while locating Visual Studio Build Tools (exit $LASTEXITCODE)."
    }
    return Resolve-VsDevCmdPath -InstallationPaths $installationOutput -Architecture $Architecture
}

function Resolve-VsDevCmdPath {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [string[]] $InstallationPaths = @(),
        [Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture
    )

    $relativeCompilers = if ($Architecture -eq 'Arm64') {
        @('bin\Hostarm64\arm64\cl.exe', 'bin\Hostx64\arm64\cl.exe')
    } else {
        @('bin\Hostx64\x64\cl.exe')
    }

    foreach ($rawPath in $InstallationPaths) {
        if ([string]::IsNullOrWhiteSpace($rawPath)) {
            continue
        }
        $installationPath = $rawPath.Trim()
        $vsDevCmd = Join-Path $installationPath 'Common7\Tools\VsDevCmd.bat'
        if (-not (Test-Path -LiteralPath $vsDevCmd)) {
            continue
        }
        $toolsets = Get-ChildItem -LiteralPath (Join-Path $installationPath 'VC\Tools\MSVC') `
            -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
        foreach ($toolset in $toolsets) {
            foreach ($relativeCompiler in $relativeCompilers) {
                if (Test-Path -LiteralPath (Join-Path $toolset.FullName $relativeCompiler)) {
                    return $vsDevCmd
                }
            }
        }
    }

    throw "No Visual Studio Build Tools installation with an $Architecture MSVC compiler was found. Re-run the architecture-specific C++ Build Tools configuration."
}

function Import-MsvcEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture)

    $vsDevCmd = Get-VsDevCmdPath -Architecture $Architecture
    $target = if ($Architecture -eq 'Arm64') { 'arm64' } else { 'x64' }
    $command = "call `"$vsDevCmd`" -arch=$target -host_arch=$target >nul && set"
    $environmentLines = @(& $env:ComSpec /d /s /c $command)
    if ($LASTEXITCODE -ne 0) {
        throw "VsDevCmd failed to initialize the $Architecture compiler environment."
    }
    foreach ($line in $environmentLines) {
        if ($line -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }

    $compiler = Get-MsvcCompilerPath -Architecture $Architecture
    $env:CC = $compiler
    return $compiler
}

function Get-CudaKernelCompileCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture,
        [Parameter(Mandatory)] [string] $VsDevCmd,
        [Parameter(Mandatory)] [string] $Nvcc,
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Output
    )

    $target = if ($Architecture -eq 'Arm64') { 'arm64' } else { 'x64' }
    return 'call "{0}" -arch={1} -host_arch={1} >nul && "{2}" -arch=native -o "{3}" "{4}"' -f `
        $VsDevCmd, $target, $Nvcc, $Output, $Source
}

function Find-GitHubReleaseAssetSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string[]] $AssetPatterns,
        [Parameter(Mandatory)] [hashtable] $Headers,
        [int] $MaxPages = 5
    )

    for ($page = 1; $page -le $MaxPages; $page++) {
        try {
            $releaseResponse = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases?per_page=100&page=$page" -Headers $Headers
            $releases = @($releaseResponse | ForEach-Object { $_ })
        } catch {
            throw "Could not query official releases for $Repository. GitHub may be unavailable or rate-limiting this network. Wait for the rate limit to reset, or set GITHUB_TOKEN for authenticated API access. $($_.Exception.Message)"
        }
        foreach ($candidate in $releases | Where-Object { -not $_.draft -and $_.tag_name -match '^b[0-9]+$' }) {
            $candidateAssets = @($candidate.assets | ForEach-Object { $_ })
            if ($candidateAssets.Count -ge 30) {
                $assetResponse = Invoke-RestMethod -Uri "$($candidate.assets_url)?per_page=100" -Headers $Headers
                $candidateAssets = @($assetResponse | ForEach-Object { $_ })
            }
            $selectedAssets = @()
            $complete = $true
            foreach ($pattern in $AssetPatterns) {
                $patternMatches = @($candidateAssets | Where-Object { $_.name -match $pattern })
                if ($patternMatches.Count -ne 1) {
                    $complete = $false
                    break
                }
                $selectedAssets += $patternMatches[0]
            }
            if ($complete) {
                return [pscustomobject]@{
                    Release = $candidate
                    Assets = $selectedAssets
                }
            }
        }
        if ($releases.Count -lt 100) {
            break
        }
    }

    throw "No rolling $Repository release in the newest $MaxPages API pages contains the complete asset set: $($AssetPatterns -join ', ')."
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

    return Install-VerifiedGitHubReleaseAssets `
        -Repository $Repository `
        -AssetPatterns @($AssetPattern) `
        -Destination $Destination `
        -VersionMarker $VersionMarker `
        -RequiredFile $RequiredFile
}

function Install-VerifiedGitHubReleaseAssets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string[]] $AssetPatterns,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $VersionMarker,
        [Parameter(Mandatory)] [string] $RequiredFile,
        [int] $MaxPages = 5
    )

    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'WindowsDeveloperConfig'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if ($env:GITHUB_TOKEN) {
        $headers.Authorization = "Bearer $env:GITHUB_TOKEN"
    }
    $assetSet = Find-GitHubReleaseAssetSet `
        -Repository $Repository `
        -AssetPatterns $AssetPatterns `
        -Headers $headers `
        -MaxPages $MaxPages
    $release = $assetSet.Release
    $assets = @($assetSet.Assets)

    foreach ($asset in $assets) {
        if ($asset.digest -notmatch '^sha256:([0-9a-fA-F]{64})$') {
            throw "GitHub did not publish a SHA-256 digest for asset '$($asset.name)'; refusing an unverified download."
        }
    }

    $markerPath = Join-Path $Destination $VersionMarker
    $selection = "$($release.tag_name)|$(@($assets.name) -join '|')"
    if ((Test-Path -LiteralPath $markerPath) -and
        (Test-Path -LiteralPath (Join-Path $Destination $RequiredFile)) -and
        ((Get-Content -LiteralPath $markerPath -Raw).Trim() -eq $selection)) {
        return $release.tag_name
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "devconfig-$([guid]::NewGuid().ToString('N'))"
    $extractPath = Join-Path $tempRoot 'expanded'
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    try {
        foreach ($asset in $assets) {
            $archivePath = Join-Path $tempRoot $asset.name
            Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $archivePath -UseBasicParsing
            $expectedHash = $asset.digest.Substring(7)
            $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
            if ($actualHash -ne $expectedHash) {
                throw "SHA-256 mismatch for '$($asset.name)'. Expected $expectedHash; got $actualHash."
            }
            Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
        }
        if (-not (Test-Path -LiteralPath (Join-Path $extractPath $RequiredFile))) {
            throw "Verified release $($release.tag_name) did not contain required file '$RequiredFile'."
        }
        $parent = Split-Path -Parent $Destination
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
        Move-Item -LiteralPath $extractPath -Destination $Destination
        Set-Content -LiteralPath $markerPath -Value $selection -Encoding ascii
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
