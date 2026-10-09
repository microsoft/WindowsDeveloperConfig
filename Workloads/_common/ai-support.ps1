$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-AiCatalogData {
    Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
    return Microsoft.PowerShell.Utility\Import-PowerShellDataFile `
        -LiteralPath (Join-Path $PSScriptRoot 'ai-catalog.psd1')
}

function Get-AiCapabilityMatrix {
    return @((Get-AiCatalogData).CapabilityMatrix)
}

function Resolve-AiCapabilityCell {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Id)

    $cell = Get-AiCapabilityMatrix | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $cell) {
        throw "Unknown AI capability cell '$Id'."
    }
    if ($cell.Status -eq 'upstream-unavailable') {
        throw [string]$cell.Blocker
    }
    $resolver = Get-Command -Name $cell.Resolver -CommandType Function -ErrorAction SilentlyContinue
    if (-not $resolver) {
        throw "Capability '$Id' references missing resolver '$($cell.Resolver)'."
    }
    $arguments = @{}
    foreach ($entry in $cell.ResolverArguments.GetEnumerator()) {
        $arguments[$entry.Key] = $entry.Value
    }
    $plan = & $resolver.Name @arguments
    foreach ($entry in $cell.Expected.GetEnumerator()) {
        $property = $plan.PSObject.Properties[$entry.Key]
        if (-not $property) {
            throw "Capability '$Id' resolver result did not contain expected field '$($entry.Key)'."
        }
        if ($property.Value -ne $entry.Value) {
            throw "Capability '$Id' expected $($entry.Key)='$($entry.Value)' but resolved '$($property.Value)'."
        }
    }
    return $plan
}

function Enable-AiUtf8Console {
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [Console]::InputEncoding = $utf8NoBom
        [Console]::OutputEncoding = $utf8NoBom
        $global:OutputEncoding = $utf8NoBom
    } catch {
        Write-Verbose "Could not force UTF-8 console encoding: $($_.Exception.Message)"
    }
}

function ConvertFrom-AiPrefixedJsonArray {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Text)

    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = @($normalized -split "`n")
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if (-not $lines[$index].TrimStart().StartsWith('[')) {
            continue
        }
        $jsonText = ($lines[$index..($lines.Count - 1)] -join "`n").Trim()
        $diagnostics = if ($index -gt 0) {
            ($lines[0..($index - 1)] -join "`n").Trim()
        } else {
            ''
        }
        try {
            return ConvertFrom-AiJsonArrayWithDiagnostics -Json $jsonText -Diagnostics $diagnostics
        } catch {
            continue
        }
    }
    throw 'No valid JSON array was found after the diagnostic output.'
}

function Get-AiWindowsPathFromOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Text)

    $withoutAnsi = [regex]::Replace($Text, "$([char]27)\[[0-?]*[ -/]*[@-~]", '')
    $match = [regex]::Match($withoutAnsi, '(?im)([A-Za-z]:\\[^\r\n]+)')
    if (-not $match.Success) {
        throw "No absolute Windows path was found in output: $Text"
    }
    $path = $match.Groups[1].Value.Trim().Trim('"', "'", ' ')
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        throw "Output did not contain a rooted Windows path: $Text"
    }
    return $path
}

function ConvertTo-AiNativeCommandLineArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Argument
    )

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $quoted = [System.Text.StringBuilder]::new()
    [void]$quoted.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]0x5c) {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$quoted.Append([char]0x5c, ($backslashes * 2) + 1)
            [void]$quoted.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$quoted.Append([char]0x5c, $backslashes)
            $backslashes = 0
        }
        [void]$quoted.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$quoted.Append([char]0x5c, $backslashes * 2)
    }
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function Invoke-AiNativeCommandSeparated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @(),
        [ValidateRange(1, 2147483)] [int] $TimeoutSeconds = 600
    )
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = @($Arguments | ForEach-Object {
        ConvertTo-AiNativeCommandLineArgument -Argument $_
    }) -join ' '
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        if (-not $process.Start()) {
            throw "Native command '$FilePath' did not start."
        }
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {
                Write-Verbose "Could not stop timed-out native command '$FilePath': $($_.Exception.Message)"
            }
            throw [System.TimeoutException]::new(
                "Native command '$FilePath' did not finish within $TimeoutSeconds seconds, so it was stopped."
            )
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = $stdoutTask.GetAwaiter().GetResult()
            StandardError = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        if ($started -and -not $process.HasExited) {
            try { $process.Kill() } catch {
                Write-Verbose "Could not stop native command '$FilePath': $($_.Exception.Message)"
            }
        }
        $process.Dispose()
    }
}

function ConvertFrom-AiJsonArrayWithDiagnostics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Json,
        [AllowEmptyString()] [string] $Diagnostics = ''
    )
    $jsonText = $Json.Trim()
    $jsonRepaired = $jsonText.StartsWith('[') -and $jsonText.EndsWith('}')
    if ($jsonRepaired) {
        $jsonText = "$jsonText`n]"
    }
    try {
        $parsedData = $jsonText | ConvertFrom-Json -ErrorAction Stop
        $data = @($parsedData)
    } catch {
        throw "llama-bench stdout was not a valid JSON array: $($_.Exception.Message)"
    }
    if ($data.Count -eq 0) {
        throw 'llama-bench returned an empty JSON array.'
    }
    $diagnosticText = $Diagnostics.Trim()
    if ($jsonRepaired) {
        $repairDiagnostic = 'LLAMA_BENCH_JSON_REPAIRED: appended the missing closing array bracket.'
        $diagnosticText = @($repairDiagnostic, $diagnosticText | Where-Object { $_ }) -join "`n"
    }
    return [pscustomobject]@{
        Data = $data
        Json = $jsonText
        Diagnostics = $diagnosticText
        JsonRepaired = $jsonRepaired
    }
}

function ConvertFrom-AiKeyedJsonLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [string] $Prefix
    )

    $line = @($Text -split '\r?\n' | Where-Object { $_.StartsWith($Prefix) }) | Select-Object -Last 1
    if (-not $line) {
        throw "Output did not contain a '$Prefix' JSON record."
    }
    $json = $line.Substring($Prefix.Length)
    try {
        return $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "The '$Prefix' record was not valid JSON: $json"
    }
}

function Test-AiDeviceNameMatch {
    [CmdletBinding()]
    param(
        [AllowNull()] [string] $Expected,
        [AllowNull()] [string] $Actual
    )
    if (-not $Expected -or -not $Actual) { return $false }
    $normalizedExpected = ($Expected -replace '\((TM|R)\)', '' -replace '[^A-Za-z0-9]+', ' ').Trim()
    $normalizedActual = ($Actual -replace '\((TM|R)\)', '' -replace '[^A-Za-z0-9]+', ' ').Trim()
    if (-not $normalizedExpected -or -not $normalizedActual) { return $false }
    return $normalizedActual -eq $normalizedExpected -or
        $normalizedActual.Contains($normalizedExpected) -or
        $normalizedExpected.Contains($normalizedActual)
}

function Get-FoundryModelVariantEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ModelInfo,
        [AllowEmptyString()] [string] $ServerLogs = ''
    )

    if (-not $ModelInfo) { return $null }
    $variants = [System.Collections.Generic.List[object]]::new()
    $current = $null
    $inVariantTable = $false
    foreach ($line in @($ModelInfo -split '\r?\n')) {
        if ($line -match '^\|\s*Variant\s*\|') {
            $inVariantTable = $true
            continue
        }
        if (-not $inVariantTable) { continue }
        if ($line -match '^\+') {
            if ($null -ne $current) {
                [void]$variants.Add([pscustomobject]$current)
                $current = $null
            }
            if ($variants.Count -gt 0) { break }
            continue
        }
        if ($line -notmatch '^\|') { continue }
        $columns = @($line -split '\|')
        if ($columns.Count -lt 8) { continue }
        $devicePart = $columns[3].Trim()
        $providerPart = $columns[4].Trim()
        $cachedPart = $columns[6].Trim()
        if ($devicePart -and $devicePart -ne 'Device' -and $devicePart -notmatch '^-+$') {
            if ($null -ne $current) {
                [void]$variants.Add([pscustomobject]$current)
            }
            $current = [ordered]@{
                Device = $devicePart
                Provider = $providerPart
                Cached = $cachedPart
            }
        } elseif ($null -ne $current -and $providerPart -and $providerPart -ne 'Provider') {
            $current.Provider += $providerPart
        }
    }
    if ($null -ne $current) {
        [void]$variants.Add([pscustomobject]$current)
    }
    if ($variants.Count -eq 0) { return $null }

    $loadedMatches = @([regex]::Matches(
        $ServerLogs,
        "(?im)Model\s+'?[^'\r\n]*-(gpu|cpu|npu):\d+'?\s*(?:\r?\n)?loaded successfully"
    ))
    $selected = $null
    if ($loadedMatches.Count -gt 0) {
        $loadedDevice = $loadedMatches[$loadedMatches.Count - 1].Groups[1].Value.ToUpperInvariant()
        $selected = @($variants | Where-Object { $_.Device -ieq $loadedDevice }) | Select-Object -First 1
    }
    if ($null -eq $selected) {
        $cachedMarker = [string][char]0x25CF
        $selected = @($variants | Where-Object {
            $_.Cached -eq $cachedMarker -or $_.Cached -match '(?i)^(yes|true)$'
        }) | Select-Object -First 1
    }
    if ($null -eq $selected -and $variants.Count -eq 1) {
        $selected = $variants[0]
    }
    return $selected
}

function Get-FoundryExecutionProviderEvidence {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string] $ModelInfo = '',
        [AllowEmptyString()] [string] $ServerLogs = ''
    )
    $providerNames = @(
        'CUDAExecutionProvider',
        'NvTensorRTRTXExecutionProvider',
        'QNNExecutionProvider',
        'OpenVINOExecutionProvider',
        'VitisAIExecutionProvider',
        'MIGraphXExecutionProvider',
        'WebGPUExecutionProvider',
        'DmlExecutionProvider',
        'CPUExecutionProvider'
    )
    $providerPattern = '(?i)(' + ($providerNames -join '|') + ')'
    $selectionMatches = @([regex]::Matches($ServerLogs, '(?im)Device:\s*([^,\r\n]+),\s*EPs:\s*([^\r\n]+)'))
    if ($selectionMatches.Count -gt 0) {
        $selection = $selectionMatches[$selectionMatches.Count - 1]
        $selectedDevice = $selection.Groups[1].Value.Trim()
        $providerText = $selection.Groups[2].Value
    } elseif ($ServerLogs -match '(?im)Using\s+WebGPU\s+EP\s+for\s+model:') {
        $selectedDevice = 'GPU'
        $providerText = 'WebGPUExecutionProvider'
    } else {
        $variant = Get-FoundryModelVariantEvidence -ModelInfo $ModelInfo -ServerLogs $ServerLogs
        if ($null -eq $variant -or -not $variant.Device -or -not $variant.Provider) {
            throw 'Foundry inference succeeded, but neither the current inference logs nor the selected model variant identified its device and execution provider.'
        }
        $selectedDevice = $variant.Device
        $providerText = $variant.Provider
    }
    $providers = @([regex]::Matches($providerText, $providerPattern) |
        ForEach-Object {
            $matchedProvider = $_.Groups[1].Value
            @($providerNames | Where-Object { $_ -ieq $matchedProvider })[0]
        } |
        Select-Object -Unique)
    if ($providers.Count -eq 0) {
        throw "Foundry selection event for device '$selectedDevice' did not identify a supported execution provider."
    }
    return [pscustomobject]@{
        SelectedDevice = $selectedDevice
        SelectedProvider = $providers -join ','
        ObservedProviders = $providers
        CpuFallback = $providers.Count -eq 1 -and $providers[0] -ieq 'CPUExecutionProvider'
    }
}

function Get-AiAppendedLogText {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string] $Before = '',
        [AllowEmptyString()] [string] $After = ''
    )
    $beforeCounts = @{}
    foreach ($line in @($Before -split '\r?\n' | Where-Object { $_ })) {
        $beforeCounts[$line] = 1 + $(if ($beforeCounts.ContainsKey($line)) { $beforeCounts[$line] } else { 0 })
    }
    $appended = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($After -split '\r?\n' | Where-Object { $_ })) {
        if ($beforeCounts.ContainsKey($line) -and $beforeCounts[$line] -gt 0) {
            $beforeCounts[$line]--
        } else {
            [void]$appended.Add($line)
        }
    }
    return $appended -join "`n"
}

function Get-LlamaBenchmarkBackendEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Data,
        [AllowEmptyString()] [string] $Diagnostics = '',
        [Parameter(Mandatory)] [ValidateSet('CUDA', 'ROCm', 'SYCL', 'OpenVINO', 'Vulkan', 'OpenCL', 'CPU')] [string] $Backend,
        [AllowNull()] [string] $ExpectedDeviceName,
        [AllowNull()] [string] $RequestedDevice
    )

    $actualBackends = @($Data | ForEach-Object {
        $property = $_.PSObject.Properties['backends']
        if ($property) { @($property.Value) | ForEach-Object { [string]$_ } }
    } | Where-Object { $_ } | Select-Object -Unique)
    $requestedDevices = @($Data | ForEach-Object {
        $property = $_.PSObject.Properties['devices']
        if ($property) { [string]$property.Value }
    } | Where-Object { $_ } | Select-Object -Unique)
    $gpuInfo = @($Data | ForEach-Object {
        $property = $_.PSObject.Properties['gpu_info']
        if ($property) { [string]$property.Value }
    } | Where-Object { $_ } | Select-Object -Unique)
    $requestedGpuMeasurements = @($Data | Where-Object {
        $property = $_.PSObject.Properties['n_gpu_layers']
        $property -and [int]$property.Value -gt 0
    })
    $offloadMatches = @([regex]::Matches($Diagnostics, '(?im)offloaded\s+([0-9]+)\s*/\s*([0-9]+)\s+layers(?:\s+to\s+GPU)?'))
    $actualOffloadedLayers = 0
    $totalModelLayers = 0
    foreach ($match in $offloadMatches) {
        $actualOffloadedLayers = [math]::Max($actualOffloadedLayers, [int]$match.Groups[1].Value)
        $totalModelLayers = [math]::Max($totalModelLayers, [int]$match.Groups[2].Value)
    }
    $evidenceText = (@($actualBackends) + @($gpuInfo) + @($Diagnostics)) -join "`n"
    $backendPattern = switch ($Backend) {
        'CUDA' { 'CUDA' }
        'ROCm' { 'ROCm|HIP' }
        'SYCL' { 'SYCL' }
        'OpenVINO' { 'OpenVINO' }
        'Vulkan' { 'Vulkan' }
        'OpenCL' { 'OpenCL' }
        'CPU' { 'CPU' }
    }
    if (($actualBackends -join "`n") -notmatch $backendPattern) {
        throw "llama-bench did not identify the selected $Backend backend. Actual backends: $($actualBackends -join ', ')."
    }
    if ($Backend -ne 'CPU' -and $gpuInfo.Count -eq 0) {
        throw "llama-bench identified $Backend but did not provide physical device evidence in gpu_info."
    }
    if ($Backend -eq 'CPU') {
        if ($actualOffloadedLayers -gt 0) {
            throw "llama-bench offloaded $actualOffloadedLayers layers while the CPU backend was selected."
        }
    } elseif ($actualOffloadedLayers -le 0) {
        throw "llama-bench identified $Backend but diagnostics did not prove any layers were actually offloaded."
    }
    $vendorPattern = switch ($Backend) {
        'CUDA' { 'NVIDIA|CUDA' }
        'ROCm' { 'AMD|Radeon|ROCm|HIP' }
        'SYCL' { 'Intel|SYCL' }
        'OpenVINO' { 'OpenVINO' }
        'Vulkan' { 'Vulkan' }
        'OpenCL' { 'Qualcomm|Adreno|OpenCL' }
        'CPU' { 'CPU' }
    }
    if ($evidenceText -notmatch $vendorPattern) {
        throw "llama-bench did not report device evidence for the selected $Backend backend."
    }
    if ($ExpectedDeviceName -and $Backend -ne 'CPU' -and $ExpectedDeviceName -ne 'OpenVINO-selected device') {
        if (-not (Test-AiDeviceNameMatch -Expected $ExpectedDeviceName -Actual $evidenceText)) {
            throw "llama-bench selected $Backend but did not identify the expected device '$ExpectedDeviceName'."
        }
    }
    if ($RequestedDevice -and $Backend -ne 'CPU') {
        $matchingRequestedDevices = @($requestedDevices | Where-Object { $_ -ieq $RequestedDevice })
        if ($matchingRequestedDevices.Count -eq 0) {
            throw "llama-bench structured devices '$($requestedDevices -join ',')' did not match requested selector '$RequestedDevice'."
        }
        $selectorPattern = "(?im)using device\s+$([regex]::Escape($RequestedDevice))\b|dev\s*=\s*$([regex]::Escape($RequestedDevice))\b"
        if ($Diagnostics -notmatch $selectorPattern) {
            throw "llama-bench did not prove that requested device selector '$RequestedDevice' was used."
        }
    }

    return [pscustomobject]@{
        Backend = $Backend
        ActualBackends = $actualBackends
        RequestedDevices = $requestedDevices
        GpuInfo = $gpuInfo
        ExpectedDevice = $ExpectedDeviceName
        RequestedDevice = $RequestedDevice
        RequestedGpuLayerMeasurements = $requestedGpuMeasurements.Count
        ActualOffloadedLayers = $actualOffloadedLayers
        TotalModelLayers = $totalModelLayers
        HardwareAccelerated = $Backend -ne 'CPU' -and $actualOffloadedLayers -gt 0
    }
}

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
            PackageId = 'Nvidia.CUDA'
            ToolkitVersion = $null
            Preview = $false
            InstallerUrl = $null
            InstallerSha256 = $null
        }
    }

    if ($WindowsBuild -lt 22000) {
        throw "CUDA 13.4 Developer Preview for Windows ARM64 requires Windows 11; detected build $WindowsBuild."
    }

    $catalog = (Get-AiCatalogData).Components.CudaArm64
    return [pscustomobject]@{
        Architecture = $Architecture
        Method = 'NvidiaInstaller'
        InstallerIdentity = $catalog.Artifact
        ToolkitVersion = $catalog.Version.Substring(0, 4)
        Preview = $true
        InstallerUrl = $catalog.Uri
        InstallerSha256 = $catalog.Sha256
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
        [ValidateSet('Auto', 'CUDA', 'ROCm', 'SYCL', 'OpenVINO', 'Vulkan', 'OpenCL', 'CPU')] [string] $Backend = 'Auto',
        [bool] $HasNvidia = $false,
        [version] $DriverVersion = [version]'0.0',
        [version] $ComputeCapability = [version]'0.0',
        [string] $NvidiaGpuName,
        [string] $AmdGpuName,
        [string] $AmdGfxTarget,
        [string] $IntelGpuName,
        [string] $QualcommGpuName,
        [bool] $HasOpenCl = $false,
        [bool] $HasVulkan = $false,
        [string] $VulkanGpuName
    )

    $catalog = (Get-AiCatalogData).Components.LlamaCppRolling
    $assets = $catalog.BackendAssets
    $cudaAsset = $null
    if ($HasNvidia) {
        if ($Architecture -eq 'Arm64') {
            if ($ComputeCapability.Major -ge 12) {
                $cudaAsset = $assets.Cuda134Arm64
            }
        } elseif ($DriverVersion -ge [version]'580.0' -and $ComputeCapability -ge [version]'7.5') {
            $cudaAsset = $assets.Cuda133X64
        } elseif ($DriverVersion -ge [version]'551.61' -and
            $ComputeCapability -ge [version]'5.0' -and
            $ComputeCapability.Major -lt 10) {
            $cudaAsset = $assets.Cuda124X64
        }
    }
    $rocmSupported = $Architecture -eq 'X64' -and [bool]$AmdGpuName -and [bool]$AmdGfxTarget
    $syclSupported = $Architecture -eq 'X64' -and (Test-IntelXpuGpuSupported -GpuName $IntelGpuName)
    $openClSupported = $Architecture -eq 'Arm64' -and [bool]$QualcommGpuName -and $HasOpenCl

    $selectedBackend = if ($Backend -eq 'Auto') {
        if ($cudaAsset) {
            'CUDA'
        } elseif ($rocmSupported) {
            'ROCm'
        } elseif ($syclSupported) {
            'SYCL'
        } elseif ($openClSupported) {
            'OpenCL'
        } elseif ($Architecture -eq 'X64' -and $HasVulkan) {
            'Vulkan'
        } else {
            'CPU'
        }
    } else {
        $Backend
    }

    $selectedAsset = switch ($selectedBackend) {
        'CUDA' {
            if (-not $cudaAsset) {
                if ($Architecture -eq 'Arm64') {
                    throw 'llama.cpp CUDA on Windows ARM64 requires an NVIDIA RTX Spark-class GPU with compute capability 12.x. Driver/runtime compatibility is verified by the real benchmark and inference workload.'
                }
                if ($HasNvidia -and $ComputeCapability.Major -ge 10 -and $DriverVersion -lt [version]'580.0') {
                    throw "llama.cpp CUDA 13.3 is required for NVIDIA compute capability $ComputeCapability, but driver $DriverVersion is below branch 580."
                }
                throw 'llama.cpp CUDA on Windows x64 requires an NVIDIA GPU with compute capability 5.0 or newer and driver 551.61 or newer.'
            }
            $cudaAsset
        }
        'ROCm' {
            if (-not $rocmSupported) {
                throw "llama.cpp ROCm requires Windows x64 and an AMD GPU in the ROCm 10.0 Windows support matrix. Detected: '$AmdGpuName'."
            }
            $assets.Rocm10X64
        }
        'SYCL' {
            if (-not $syclSupported) {
                throw "llama.cpp SYCL requires Windows x64 and a supported Intel GPU. Detected: '$IntelGpuName'."
            }
            $assets.SyclX64
        }
        'OpenVINO' {
            if ($Architecture -ne 'X64') {
                throw 'llama.cpp OpenVINO is not published for native Windows ARM64.'
            }
            $assets.OpenVinoX64
        }
        'Vulkan' {
            if ($Architecture -ne 'X64') {
                throw 'llama.cpp Vulkan is not selected on Windows ARM64; use CUDA, OpenCL, or CPU.'
            }
            if (-not $HasVulkan) {
                throw 'llama.cpp Vulkan was requested, but no Vulkan loader and usable display adapter were detected.'
            }
            $assets.VulkanX64
        }
        'OpenCL' {
            if (-not $openClSupported) {
                throw "llama.cpp OpenCL is published here only for Qualcomm Adreno on Windows ARM64 with a working OpenCL loader. Detected: '$QualcommGpuName'; OpenCL loader: $HasOpenCl."
            }
            $assets.OpenClAdrenoArm64
        }
        'CPU' {
            if ($Architecture -eq 'Arm64') { $assets.CpuArm64 } else { $assets.CpuX64 }
        }
    }
    $deviceName = switch ($selectedBackend) {
        'CUDA' { $NvidiaGpuName }
        'ROCm' { $AmdGpuName }
        'SYCL' { $IntelGpuName }
        'OpenVINO' { if ($IntelGpuName) { $IntelGpuName } else { 'OpenVINO-selected device' } }
        'Vulkan' { $VulkanGpuName }
        'OpenCL' { $QualcommGpuName }
        default { 'CPU' }
    }
    return [pscustomobject]@{
        Method = 'GitHubRelease'
        PackageId = $null
        AssetPatterns = @($selectedAsset.Patterns)
        Backend = $selectedAsset.Backend
        Runtime = $selectedAsset.Runtime
        Vendor = $selectedAsset.Vendor
        DeviceName = $deviceName
        Maturity = $(if ($selectedAsset.ContainsKey('Maturity')) { $selectedAsset.Maturity } else { $catalog.Maturity })
        VersionPolicy = $(if ($selectedAsset.ContainsKey('VersionPolicy')) { $selectedAsset.VersionPolicy } else { $catalog.VersionPolicy })
        AmdGfxTarget = $(if ($selectedBackend -eq 'ROCm') { $AmdGfxTarget } else { $null })
    }
}

function Get-QualcommGpuName {
    $names = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match 'VEN_(17CB|QCOM)' -or $_.Name -match 'Qualcomm|Adreno' } |
        ForEach-Object Name)
    return $names | Sort-Object | Select-Object -First 1
}

function Get-VulkanGpuName {
    $names = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -and $_.Name -notmatch 'Microsoft Basic|Remote Display|Indirect Display|Hyper-V' } |
        ForEach-Object Name)
    return $names | Sort-Object | Select-Object -First 1
}

function Test-AiOpenClRuntimeAvailable {
    [CmdletBinding()]
    param()
    return Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\OpenCL.dll')
}

function Test-AiVulkanRuntimeAvailable {
    [CmdletBinding()]
    param([AllowNull()] [string] $GpuName)
    if (-not $GpuName) { return $false }
    return Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\vulkan-1.dll')
}

function Resolve-OllamaInstallPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture)

    return [pscustomobject]@{
        Method = 'WinGet'
        PackageId = 'Ollama.Ollama'
        LaunchMode = 'InstalledApplication'
        Architecture = $Architecture
    }
}

function Get-OllamaWingetManifestEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture)

    $result = Invoke-DevConfigNativeCommand -FilePath 'winget.exe' -Arguments @(
        'show', '--id', 'Ollama.Ollama', '--exact', '--source', 'winget',
        '--architecture', $Architecture.ToLowerInvariant(), '--accept-source-agreements',
        '--disable-interactivity'
    )
    if ($result.ExitCode -ne 0) {
        throw "Ollama.Ollama has no applicable $Architecture WinGet installer. Refresh the winget source and verify the package before setup."
    }
    $urlMatch = [regex]::Match(
        $result.Output,
        'https://github\.com/ollama/ollama/releases/download/v([^/\s]+)/OllamaSetup\.exe',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $shaMatch = [regex]::Match(
        $result.Output,
        '(?<![0-9a-fA-F])([0-9a-fA-F]{64})(?![0-9a-fA-F])')
    if (-not $urlMatch.Success -or -not $shaMatch.Success) {
        throw "Ollama.Ollama is applicable to $Architecture, but WinGet did not expose the expected official installer URL and SHA-256."
    }
    return [pscustomobject]@{
        PackageId = 'Ollama.Ollama'
        Architecture = $Architecture
        Version = $urlMatch.Groups[1].Value
        InstallerUrl = $urlMatch.Value
        InstallerSha256 = $shaMatch.Groups[1].Value.ToLowerInvariant()
        Applicable = $true
        RawEvidence = $result.Output.Trim()
    }
}

function Get-OllamaRegisteredApplicationEvidence {
    [CmdletBinding()]
    param()

    $entry = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -match '^Ollama version ' -and
            $_.UninstallString
        } |
        Sort-Object DisplayVersion -Descending |
        Select-Object -First 1
    if (-not $entry) { return $null }
    return [pscustomobject]@{
        DisplayName = [string]$entry.DisplayName
        DisplayVersion = [string]$entry.DisplayVersion
        InstallLocation = [string]$entry.InstallLocation
        UninstallString = [string]$entry.UninstallString
    }
}

function ConvertFrom-OllamaUninstallString {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $UninstallString)

    $match = [regex]::Match($UninstallString.Trim(), '^(?:"([^"]+)"|(\S+))(?:\s+(.*))?$')
    if (-not $match.Success) {
        throw "Ollama registered an invalid uninstall command: $UninstallString"
    }
    return [pscustomobject]@{
        FilePath = $(if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value })
        Arguments = [string]$match.Groups[3].Value
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

function Get-AmdGfxTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $GpuName)

    $normalizedGpuName = ($GpuName -replace '\((TM|R)\)', '' -replace '\s+', ' ').Trim()
    $map = @(
        @{ Pattern = 'R9700|R9600D|RX 9070'; Gfx = 'gfx1201' }
        @{ Pattern = 'RX 9060|RX 9050'; Gfx = 'gfx1200' }
        @{ Pattern = 'W7900|W7800|RX 7900'; Gfx = 'gfx1100' }
        @{ Pattern = 'W7700|RX 7800|RX 7700'; Gfx = 'gfx1101' }
        @{ Pattern = 'RX (7600|7650)'; Gfx = 'gfx1102' }
        @{ Pattern = 'Ryzen AI Max|Radeon 8060S'; Gfx = 'gfx1151' }
        @{ Pattern = 'Ryzen AI 9.*(475|470|375|370|465|365)|Radeon (890M|880M)'; Gfx = 'gfx1150' }
        @{ Pattern = 'Ryzen AI (7|5).*(450|350|345|440|340|330)|Radeon 860M'; Gfx = 'gfx1152' }
        @{ Pattern = 'Ryzen AI (7|5).*(445|435|430)|Radeon 840M'; Gfx = 'gfx1153' }
        @{ Pattern = 'Ryzen (9 270|7 (260|250)|5 (240|230|220)|3 210)|Radeon (780M|760M|740M)'; Gfx = 'gfx1103' }
    )
    $entry = $map | Where-Object { $normalizedGpuName -match $_.Pattern } | Select-Object -First 1
    if (-not $entry) {
        return $null
    }
    return $entry.Gfx
}

function Get-AiDetectedVendor {
    $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    if ($controllers | Where-Object { $_.PNPDeviceID -match 'VEN_10DE' -or $_.Name -match 'NVIDIA' }) { return 'NVIDIA' }
    if ($controllers | Where-Object { $_.PNPDeviceID -match 'VEN_1002' -or $_.Name -match 'AMD|Radeon' }) { return 'AMD' }
    if ($controllers | Where-Object { $_.PNPDeviceID -match 'VEN_8086' -or $_.Name -match 'Intel' }) { return 'Intel' }
    return 'None'
}

function Get-AiProcessId {
    [CmdletBinding()]
    param([AllowNull()] $ProcessObject)
    if ($null -eq $ProcessObject) { return $null }
    foreach ($name in @('ProcessId', 'Id')) {
        $property = $ProcessObject.PSObject.Properties[$name]
        if ($property -and $null -ne $property.Value) {
            return [int]$property.Value
        }
    }
    return $null
}

function Get-AiProcessIds {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $ProcessObjects = @())
    return @($ProcessObjects |
        ForEach-Object { Get-AiProcessId -ProcessObject $_ } |
        Where-Object { $null -ne $_ })
}

function Get-AiPeArchitecture {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) {
            throw "'$Path' is not a PE executable."
        }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "'$Path' has an invalid PE signature."
        }
        $machine = $reader.ReadUInt16()
        switch ($machine) {
            43620 { return 'Arm64' }
            34404 { return 'X64' }
            332 { return 'X86' }
            default { return ('Unknown-0x{0:X4}' -f $machine) }
        }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-OllamaLocalEndpoint {
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string] $HostValue = $env:OLLAMA_HOST)

    $value = ([string]$HostValue).Trim().Trim([char[]]@('"', "'")).Trim()
    if (-not $value) { $value = '127.0.0.1:11434' }
    if ($value -cnotmatch '^https?://') {
        $authority = ($value -split '/', 2)[0]
        $suffix = $value.Substring($authority.Length)
        $address = $null
        if ([Net.IPAddress]::TryParse($authority.Trim([char[]]'[]'), [ref]$address) -and
            $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
            $authority = "[$address]:11434"
        } elseif ($authority -notmatch ':\d+$') {
            $authority += ':11434'
        }
        $value = "http://$authority$suffix"
    }
    $uri = $null
    if (-not [uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or $uri.Port -lt 1 -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') {
        throw 'OLLAMA_HOST must be a local host/port or root HTTP(S) URL without credentials, a path, query, or fragment.'
    }
    $endpoint = [UriBuilder]::new($uri)
    $bindAddress = $null
    if ([Net.IPAddress]::TryParse($uri.DnsSafeHost, [ref]$bindAddress)) {
        if ($bindAddress.Equals([Net.IPAddress]::Any)) { $endpoint.Host = '127.0.0.1' }
        if ($bindAddress.Equals([Net.IPAddress]::IPv6Any)) { $endpoint.Host = '::1' }
    }
    if (-not $endpoint.Uri.IsLoopback) {
        throw 'OLLAMA_HOST must use a loopback address; remote servers cannot be verified against local model files.'
    }
    return $endpoint.Uri.AbsoluteUri.TrimEnd('/')
}

function Get-OllamaManagedPaths {
    [CmdletBinding()]
    param([string] $LocalAppData = $env:LOCALAPPDATA)

    $installRoot = Join-Path $LocalAppData 'Programs\Ollama'
    return [pscustomobject]@{
        InstallRoot = $installRoot
        Executable = Join-Path $installRoot 'ollama.exe'
        InstallManifest = Join-Path $installRoot '.devconfig-install.json'
        VersionMarker = '.devconfig-version'
        CacheDirectory = Join-Path $LocalAppData 'DevConfig\ollama\asset-cache'
        LegacyRoot = Join-Path $LocalAppData 'DevConfig\ollama\runtime'
        StartupRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        StartupValueName = 'WindowsDeveloperConfig.Ollama'
    }
}

function Get-OllamaManagedProcesses {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $InstallRoot)

    $resolvedRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $rootPrefix = "$resolvedRoot\"
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            if (-not $_.ExecutablePath) {
                $false
            } else {
                $executablePath = [IO.Path]::GetFullPath([string]$_.ExecutablePath)
                $executablePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
            }
        })
}

function Stop-OllamaManagedProcesses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InstallRoot,
        [int] $TimeoutSeconds = 30
    )

    $processes = @(Get-OllamaManagedProcesses -InstallRoot $InstallRoot)
    $ids = @(Get-AiProcessIds -ProcessObjects $processes)
    foreach ($processId in $ids) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
    foreach ($processId in $ids) {
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
            if ((Get-Date) -ge $deadline) {
                throw "Managed Ollama process $processId did not exit within $TimeoutSeconds seconds."
            }
            Start-Sleep -Milliseconds 250
        }
    }
    return $ids
}

function Remove-OllamaStartupRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RegistryPath,
        [Parameter(Mandatory)] [string] $ValueName
    )
    if (Test-Path -LiteralPath $RegistryPath) {
        Remove-ItemProperty -LiteralPath $RegistryPath -Name $ValueName -ErrorAction SilentlyContinue
    }
}

function Remove-OllamaManagedDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateRange(1, 30)] [int] $Attempts = 10
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $lastError = $null
    foreach ($attempt in 1..$Attempts) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $Path)) { return }
        } catch {
            $lastError = $_
        }
        if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds 500 }
    }
    throw "Could not remove the Dev Config-managed Ollama path '$Path' after $Attempts attempts: $($lastError.Exception.Message)"
}

function Remove-OllamaLegacyManagedInstallation {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Paths)

    $markerPresent = (Test-Path -LiteralPath $Paths.InstallManifest) -or
        (Test-Path -LiteralPath (Join-Path $Paths.InstallRoot $Paths.VersionMarker)) -or
        (Test-Path -LiteralPath $Paths.LegacyRoot)
    if (-not $markerPresent) {
        return [pscustomobject]@{
            Migrated = $false
            StoppedManagedProcessIds = @()
            StartupRemoved = $false
            PathRemoved = $false
            RuntimeRemoved = $false
            ModelsPreserved = $true
        }
    }
    $stopped = @(Stop-OllamaManagedProcesses -InstallRoot $Paths.InstallRoot)
    $stopped += @(Stop-OllamaManagedProcesses -InstallRoot $Paths.LegacyRoot)
    Remove-OllamaStartupRegistration `
        -RegistryPath $Paths.StartupRegistryPath `
        -ValueName $Paths.StartupValueName
    Remove-UserPathEntry -Path $Paths.InstallRoot
    Remove-UserPathEntry -Path $Paths.LegacyRoot
    Remove-OllamaManagedDirectory -Path $Paths.InstallRoot
    Remove-OllamaManagedDirectory -Path $Paths.LegacyRoot
    Remove-OllamaManagedDirectory -Path $Paths.CacheDirectory
    return [pscustomobject]@{
        Migrated = $true
        StoppedManagedProcessIds = @($stopped | Select-Object -Unique)
        StartupRemoved = $true
        PathRemoved = $true
        RuntimeRemoved = -not (Test-Path -LiteralPath $Paths.InstallRoot)
        ModelsPreserved = $true
    }
}

function Get-AmdGpuName {
    param([Nullable[int]] $DeviceIndex = $null)
    $names = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match 'VEN_1002' -or $_.Name -match 'AMD|Radeon' } |
        ForEach-Object Name)
    if ($null -ne $DeviceIndex) {
        if ($DeviceIndex -ge $names.Count) { return $null }
        return $names[$DeviceIndex]
    }
    return Select-AmdGpuName -GpuNames $names
}

function Select-AmdGpuName {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]] $GpuNames = @())
    $supported = $GpuNames | Where-Object { Get-AmdGfxTarget -GpuName $_ } | Sort-Object | Select-Object -First 1
    if ($supported) { return $supported }
    return $GpuNames | Sort-Object | Select-Object -First 1
}

function Resolve-RocmInstallPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture,
        [AllowNull()] [string] $GpuName
    )

    if ($Architecture -ne 'X64') {
        throw 'AMD ROCm Core SDK 10.0 does not publish native Windows ARM64 packages.'
    }
    $gfx = if ($GpuName) { Get-AmdGfxTarget -GpuName $GpuName } else { $null }
    if (-not $gfx) {
        throw "No AMD GPU supported by the ROCm 10.0 Windows matrix was detected. Detected GPU: '$GpuName'."
    }
    return [pscustomobject]@{
        Architecture = $Architecture
        GpuName = $GpuName
        GfxTarget = $gfx
        Requirement = "rocm[libraries,devel,device-$gfx]==10.0.0"
    }
}

function Get-IntelGpuName {
    param([Nullable[int]] $DeviceIndex = $null)
    $names = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match 'VEN_8086' -or $_.Name -match 'Intel' } |
        ForEach-Object Name)
    if ($null -ne $DeviceIndex) {
        if ($DeviceIndex -ge $names.Count) { return $null }
        return $names[$DeviceIndex]
    }
    return Select-IntelGpuName -GpuNames $names
}

function Select-IntelGpuName {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]] $GpuNames = @())
    $supported = $GpuNames | Where-Object { Test-IntelXpuGpuSupported -GpuName $_ } | Sort-Object | Select-Object -First 1
    if ($supported) { return $supported }
    return $GpuNames | Sort-Object | Select-Object -First 1
}

function Resolve-IntelAiPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture,
        [Parameter(Mandatory)] [ValidateSet('Auto', 'CPU', 'GPU', 'NPU')] [string] $Device,
        [Parameter(Mandatory)] [ValidateSet('OpenVINO', 'SYCL', 'Full')] [string] $Profile,
        [bool] $IntelGpuPresent = $false,
        [bool] $IntelNpuPresent = $false
    )

    if ($Architecture -ne 'X64') {
        throw 'Intel oneAPI, OpenVINO, PyTorch XPU, and Triton XPU do not publish native Windows ARM64 artifacts.'
    }
    $selectedDevice = if ($Profile -eq 'SYCL' -and $Device -eq 'Auto') {
        'GPU'
    } elseif ($Device -eq 'Auto') {
        if ($IntelNpuPresent) { 'NPU' } elseif ($IntelGpuPresent) { 'GPU' } else { 'CPU' }
    } else { $Device }
    if ($Profile -eq 'SYCL' -and $selectedDevice -ne 'GPU') {
        throw 'The SYCL-only profile supports -Device Auto or GPU. Use -Profile OpenVINO or Full for CPU/NPU inference.'
    }
    if ($selectedDevice -eq 'GPU' -and -not $IntelGpuPresent) {
        throw 'Intel GPU was requested, but no Intel display adapter was detected.'
    }
    if ($selectedDevice -eq 'NPU' -and -not $IntelNpuPresent) {
        throw 'Intel NPU was requested, but no Intel AI Boost/NPU device was detected.'
    }
    if ($Profile -in @('SYCL', 'Full') -and -not $IntelGpuPresent) {
        throw 'The SYCL profile requires a detected Intel GPU because its acceptance kernel uses gpu_selector_v.'
    }
    return [pscustomobject]@{
        Architecture = $Architecture
        Device = $selectedDevice
        Profile = $Profile
        InstallOpenVino = $Profile -in @('OpenVINO', 'Full')
        InstallOneApi = $Profile -in @('SYCL', 'Full')
    }
}

function Test-IntelXpuGpuSupported {
    [CmdletBinding()]
    param([AllowNull()] [string] $GpuName)
    if (-not $GpuName) { return $false }
    $normalized = ($GpuName -replace '\((TM|R)\)', '' -replace '\s+', ' ').Trim()
    return $normalized -match 'Arc.*(A|B)[0-9]|Arc.*(130V|140V)|Arc.*Graphics|Meteor Lake|Arrow Lake|Lunar Lake|Panther Lake|Core Ultra'
}

function Get-NvidiaDriverInfo {
    [CmdletBinding()]
    param([ValidateRange(0, 63)] [int] $DeviceIndex = 0)

    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
        return $null
    }

    $result = Invoke-DevConfigNativeCommand -FilePath 'nvidia-smi' -Arguments @(
        '--query-gpu=name,driver_version,compute_cap', '--format=csv,noheader,nounits'
    )
    $allOutput = @($result.Output -split '\r?\n' | Where-Object { $_ })
    if ($result.ExitCode -ne 0 -or $allOutput.Count -eq 0) {
        return $null
    }
    if ($DeviceIndex -ge $allOutput.Count) {
        throw "NVIDIA device index $DeviceIndex was requested, but nvidia-smi reported $($allOutput.Count) device(s)."
    }
    $output = $allOutput[$DeviceIndex]

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

function Get-CudaKernelDeviceEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Output,
        [Parameter(Mandatory)] [string] $ExpectedDeviceName,
        [ValidateRange(0, 63)] [int] $DeviceIndex = 0
    )

    $deviceMatch = [regex]::Match($Output.Trim(), '^CUDA_KERNEL_READY device_index=([0-9]+) device=(.+)$')
    if (-not $deviceMatch.Success) {
        throw "CUDA kernel evidence did not contain the device index and name: $Output"
    }
    $actualDeviceIndex = 0
    if (-not [int]::TryParse($deviceMatch.Groups[1].Value, [ref]$actualDeviceIndex) -or $actualDeviceIndex -ne $DeviceIndex) {
        throw "CUDA kernel reported device index '$($deviceMatch.Groups[1].Value)' instead of requested index $DeviceIndex."
    }
    $actualDeviceName = $deviceMatch.Groups[2].Value.Trim()
    if (-not (Test-AiDeviceNameMatch -Expected $ExpectedDeviceName -Actual $actualDeviceName)) {
        throw "CUDA device index $DeviceIndex executed on '$actualDeviceName', but nvidia-smi qualified '$ExpectedDeviceName'. Check CUDA_VISIBLE_DEVICES and CUDA_DEVICE_ORDER."
    }
    return [pscustomobject]@{
        DeviceIndex = $actualDeviceIndex
        Name = $actualDeviceName
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
        [Parameter(Mandatory)] [ValidateSet('Auto', 'CPU', 'CUDA', 'ROCm', 'XPU')] [string] $Backend,
        [Parameter(Mandatory)] [version] $PythonVersion,
        [bool] $HasNvidia = $false,
        [int] $DriverMajor = 0,
        [version] $ComputeCapability = [version]'0.0',
        [ValidateSet('NVIDIA', 'AMD', 'Intel', 'None')] [string] $GpuVendor = 'None',
        [string] $GpuName,
        [string] $AmdGpuName,
        [string] $IntelGpuName,
        [string] $AmdGfxTarget,
        [bool] $HasAmd = $false,
        [bool] $HasIntel = $false,
        [switch] $SkipTriton
    )

    if ($Architecture -eq 'Arm64') {
        if ($PythonVersion -lt [version]'3.11' -or $PythonVersion -ge [version]'3.14') {
            throw "PyTorch 2.14 Windows ARM64 wheels require CPython 3.11-3.13; detected $PythonVersion."
        }

        $canUseCudaPreview = $PythonVersion.Major -eq 3 -and
            $PythonVersion.Minor -eq 13 -and
            $HasNvidia -and
            $ComputeCapability.Major -ge 12
        if ($Backend -in @('ROCm', 'XPU')) {
            throw "$Backend is not published for native Windows ARM64."
        }
        if ($Backend -eq 'CUDA' -and -not $canUseCudaPreview) {
            throw 'Windows ARM64 CUDA PyTorch requires CPython 3.13 and an NVIDIA RTX Spark-class GPU with compute capability 12.x. Driver/runtime compatibility is verified by the real tensor and Triton workloads.'
        }
        if ($Backend -eq 'Auto' -and $HasNvidia -and -not $canUseCudaPreview) {
            throw 'An NVIDIA GPU is present on Windows ARM64, but it does not meet the CUDA 13.4 PyTorch Developer Preview requirements. Use -Backend CPU to explicitly accept CPU-only PyTorch.'
        }
        if ($Backend -eq 'Auto' -and -not $canUseCudaPreview -and ($HasAmd -or $GpuVendor -eq 'AMD')) {
            throw 'AMD ROCm PyTorch is not published for native Windows ARM64. Use -Backend CPU to explicitly accept CPU-only PyTorch.'
        }
        if ($Backend -eq 'Auto' -and -not $canUseCudaPreview -and ($HasIntel -or $GpuVendor -eq 'Intel')) {
            throw 'Intel XPU PyTorch is not published for native Windows ARM64. Use -Backend CPU to explicitly accept CPU-only PyTorch.'
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
        if ($Backend -eq 'CUDA' -and $ComputeCapability -lt [version]'5.0') {
            throw "CUDA backend was requested, but NVIDIA compute capability $ComputeCapability is below the supported Windows CUDA wheel minimum of 5.0."
        }
        $amdPresent = $HasAmd -or $GpuVendor -eq 'AMD'
        $amdRocmSupported = $amdPresent -and [bool]$AmdGfxTarget
        $intelPresent = $HasIntel -or $GpuVendor -eq 'Intel'
        if ($Backend -eq 'ROCm' -and -not $amdRocmSupported) {
            throw 'ROCm backend was requested, but no supported Windows AMD GPU/gfx target was detected.'
        }
        $intelCandidateName = if ($IntelGpuName) { $IntelGpuName } else { $GpuName }
        $intelXpuSupported = $intelPresent -and (Test-IntelXpuGpuSupported -GpuName $intelCandidateName)
        if ($Backend -eq 'XPU' -and -not $intelXpuSupported) {
            throw "XPU backend was requested, but the detected Intel GPU '$intelCandidateName' is not in the validated Windows PyTorch XPU families."
        }
        if ($Backend -eq 'Auto' -and $amdPresent -and -not $amdRocmSupported -and -not $HasNvidia -and -not $intelXpuSupported) {
            throw "An AMD GPU is present, but '$AmdGpuName' is not in the ROCm 10.0 Windows support matrix. Use -Backend CPU to explicitly accept CPU-only PyTorch."
        }
        if ($Backend -eq 'Auto' -and $intelPresent -and -not $intelXpuSupported -and -not $HasNvidia -and -not $amdRocmSupported) {
            throw "An Intel GPU is present, but '$intelCandidateName' is not in the validated Windows PyTorch XPU families. Use -Backend CPU to explicitly accept CPU-only PyTorch."
        }
        $cudaSupported = $HasNvidia -and $DriverMajor -ge 525 -and
            $ComputeCapability -ge [version]'5.0' -and
            -not ($ComputeCapability.Major -ge 10 -and $DriverMajor -lt 580)
        $selectedBackend = if ($Backend -eq 'Auto') {
            if ($cudaSupported) {
                'CUDA'
            } elseif ($amdRocmSupported) {
                'ROCm'
            } elseif ($intelXpuSupported) {
                'XPU'
            } else {
                'CPU'
            }
        } else {
            $Backend
        }
        if ($Backend -eq 'Auto' -and $HasNvidia -and -not $cudaSupported -and
            -not $amdRocmSupported -and -not $intelXpuSupported) {
            throw "An NVIDIA GPU is present, but driver branch $DriverMajor and compute capability $ComputeCapability do not match a supported Windows CUDA wheel. Use -Backend CPU to explicitly accept CPU-only PyTorch."
        }
    }

    $indexUrl = 'https://download.pytorch.org/whl/cpu'
    $runtime = 'cpu'
    $torchRequirement = 'torch==2.14.0+cpu'
    $torchVersion = '2.14.0+cpu'
    $directWheelUrl = $null
    $directWheelSha256 = $null
    $directWheelFileName = $null
    $preview = $false
    $catalog = (Get-AiCatalogData).Components
    $additionalRequirements = @()
    if ($selectedBackend -eq 'CUDA') {
        if ($Architecture -eq 'Arm64') {
            $runtime = 'cu134'
            $indexUrl = $null
            $preview = $true
            $torchVersion = $catalog.NvidiaPyTorchArm64.Version
            $directWheelUrl = $catalog.NvidiaPyTorchArm64.Uri
            $directWheelSha256 = $catalog.NvidiaPyTorchArm64.Sha256
            $directWheelFileName = 'torch-2.15.0.dev20260904+cu134-cp313-cp313-win_arm64.whl'
            $torchRequirement = "torch @ $directWheelUrl#sha256=$directWheelSha256"
        } elseif ($ComputeCapability.Major -ge 10 -and $DriverMajor -lt 580) {
            throw "This NVIDIA GPU reports compute capability $ComputeCapability and needs a CUDA 13 wheel, but driver branch $DriverMajor is below 580. Update the NVIDIA driver."
        } elseif ($DriverMajor -ge 580 -and $ComputeCapability -ge [version]'7.5') {
            $runtime = 'cu130'
            $indexUrl = 'https://download.pytorch.org/whl/cu130'
            $torchVersion = '2.14.0+cu130'
            $torchRequirement = 'torch==2.14.0+cu130'
        } else {
            $runtime = 'cu126'
            $indexUrl = 'https://download.pytorch.org/whl/cu126'
            $torchVersion = '2.14.0+cu126'
            $torchRequirement = 'torch==2.14.0+cu126'
        }
    } elseif ($selectedBackend -eq 'ROCm') {
        $runtime = 'rocm10.0.0'
        $indexUrl = 'https://stable.repo.amd.com/rocm/whl-next/'
        $torchVersion = '2.13.0+rocm10.0.0'
        $torchRequirement = "torch[device-$AmdGfxTarget]==2.13.0+rocm10.0.0"
        $additionalRequirements = @(
            "torchvision[device-$AmdGfxTarget]==0.28.0+rocm10.0.0",
            'torchaudio==2.11.0.2+rocm10.0.0'
        )
    } elseif ($selectedBackend -eq 'XPU') {
        $runtime = 'xpu'
        $indexUrl = 'https://download.pytorch.org/whl/xpu'
        $torchVersion = '2.14.0+xpu'
        $torchRequirement = 'torch==2.14.0+xpu'
        $additionalRequirements = @('torchvision==0.29.0+xpu')
    }

    $installTriton = -not $SkipTriton -and (
        ($selectedBackend -eq 'CUDA' -and $ComputeCapability.Major -ge 8) -or
        $selectedBackend -eq 'XPU')
    $tritonRequirement = if (-not $installTriton) {
        $null
    } elseif ($selectedBackend -eq 'XPU') {
        'triton-xpu==3.8.0'
    } else {
        $catalog.TritonWindows.Package
    }
    $tritonVersion = if (-not $installTriton) {
        $null
    } elseif ($selectedBackend -eq 'XPU') {
        '3.8.0'
    } else {
        '3.8.0.post28'
    }

    return [pscustomobject]@{
        Architecture = $Architecture
        Backend = $selectedBackend
        Vendor = switch ($selectedBackend) {
            'CUDA' { 'NVIDIA' }
            'ROCm' { 'AMD' }
            'XPU' { 'Intel' }
            default { 'CPU' }
        }
        DeviceName = switch ($selectedBackend) {
            'CUDA' { $GpuName }
            'ROCm' { $AmdGpuName }
            'XPU' { $intelCandidateName }
            default { 'CPU' }
        }
        AmdGfxTarget = if ($selectedBackend -eq 'ROCm') { $AmdGfxTarget } else { $null }
        TorchRequirement = $torchRequirement
        TorchVersion = $torchVersion
        AdditionalRequirements = $additionalRequirements
        IndexUrl = $indexUrl
        Runtime = $runtime
        Preview = $preview
        DirectWheelUrl = $directWheelUrl
        DirectWheelSha256 = $directWheelSha256
        DirectWheelFileName = $directWheelFileName
        NumpyRequirement = 'numpy==2.5.2'
        NumpyVersion = '2.5.2'
        InstallTriton = $installTriton
        TritonRequirement = $tritonRequirement
        TritonVersion = $tritonVersion
        TritonReason = if ($SkipTriton) {
            'Triton installation and verification were disabled by the caller.'
        } elseif ($installTriton) {
            "Compatible PyTorch $selectedBackend stack detected."
        } elseif ($selectedBackend -ne 'CUDA') {
            "No supported native-Windows Triton package is selected for $selectedBackend."
        } elseif ($ComputeCapability.Major -lt 8) {
            "Triton Windows requires NVIDIA compute capability 8.0 or newer; detected $ComputeCapability."
        } else {
            'Triton installation was disabled by the caller.'
        }
    }
}

function Test-PyTorchStateCompatible {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DesiredStateJson,
        [AllowNull()] [string] $CurrentStateJson
    )

    if ([string]::IsNullOrWhiteSpace($CurrentStateJson)) {
        return $false
    }

    $desired = $DesiredStateJson | ConvertFrom-Json
    try {
        $current = $CurrentStateJson | ConvertFrom-Json
    } catch {
        return $false
    }
    foreach ($property in @('architecture', 'backend', 'index', 'python')) {
        if ($current.$property -ne $desired.$property) {
            return $false
        }
    }
    $legacyStableTorch = $current.torch -eq 'torch==2.14.0' -and
        $desired.torch -match '^torch==2\.14\.0\+(cpu|cu126|cu130)$'
    if ($current.torch -ne $desired.torch -and -not $legacyStableTorch) {
        return $false
    }
    if (-not $desired.tritonVersion -and $current.triton) {
        return $false
    }
    return $true
}

function Test-PyTorchEnvironmentMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DesiredStateJson,
        [AllowNull()] [string] $CurrentStateJson,
        [AllowNull()] $InstalledVersions
    )

    if (-not (Test-PyTorchStateCompatible `
            -DesiredStateJson $DesiredStateJson `
            -CurrentStateJson $CurrentStateJson) -or
        $null -eq $InstalledVersions) {
        return $false
    }

    $desired = $DesiredStateJson | ConvertFrom-Json
    foreach ($requiredProperty in @('torch', 'numpy', 'triton')) {
        if ($InstalledVersions.PSObject.Properties.Name -notcontains $requiredProperty) {
            return $false
        }
    }
    if ($InstalledVersions.torch -ne $desired.torchVersion -or
        $InstalledVersions.numpy -ne $desired.numpyVersion) {
        return $false
    }
    if ($desired.tritonVersion) {
        if ($InstalledVersions.triton -ne $desired.tritonVersion) {
            return $false
        }
    } elseif (-not [string]::IsNullOrEmpty($InstalledVersions.triton)) {
        return $false
    }

    $additionalRequirements = if ($desired.PSObject.Properties.Name -contains 'additionalRequirements') {
        @($desired.additionalRequirements)
    } else {
        @()
    }
    foreach ($requirement in $additionalRequirements) {
        if ($requirement -match '^torchvision(?:\[[^\]]+\])?==(.+)$' -and
            ($InstalledVersions.PSObject.Properties.Name -notcontains 'torchvision' -or
                $InstalledVersions.torchvision -ne $Matches[1])) {
            return $false
        }
        if ($requirement -match '^torchaudio==(.+)$' -and
            ($InstalledVersions.PSObject.Properties.Name -notcontains 'torchaudio' -or
                $InstalledVersions.torchaudio -ne $Matches[1])) {
            return $false
        }
    }
    return $true
}

function Get-PyTorchPackageAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DesiredStateJson,
        [AllowNull()] [string] $CurrentStateJson,
        [AllowNull()] $InstalledVersions
    )

    if (Test-PyTorchEnvironmentMatches `
            -DesiredStateJson $DesiredStateJson `
            -CurrentStateJson $CurrentStateJson `
            -InstalledVersions $InstalledVersions) {
        return 'VerifyOnly'
    }
    return 'Install'
}

function Test-PyTorchEnvironmentRequiresRecreation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DesiredStateJson,
        [AllowNull()] [string] $CurrentStateJson,
        [AllowNull()] $InstalledVersions
    )

    if (-not (Test-PyTorchStateCompatible `
            -DesiredStateJson $DesiredStateJson `
            -CurrentStateJson $CurrentStateJson)) {
        return $true
    }
    $desired = $DesiredStateJson | ConvertFrom-Json
    return $null -ne $InstalledVersions -and
        -not $desired.tritonVersion -and
        -not [string]::IsNullOrEmpty($InstalledVersions.triton)
}

function Get-PythonEnvironmentVersions {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $PythonPath)

    if (-not (Test-Path -LiteralPath $PythonPath)) {
        return $null
    }
    $script = @'
import importlib.metadata
import json
import numpy
import torch

versions = {}
for distribution in ("triton-windows", "triton-xpu", "torchvision", "torchaudio"):
    try:
        versions[distribution] = importlib.metadata.version(distribution)
    except importlib.metadata.PackageNotFoundError:
        versions[distribution] = None

triton_distribution = next(
    (name for name in ("triton-windows", "triton-xpu") if versions[name]),
    None,
)

print(json.dumps({
    "torch": torch.__version__,
    "numpy": numpy.__version__,
    "triton": versions[triton_distribution] if triton_distribution else None,
    "triton_distribution": triton_distribution,
    "torchvision": versions["torchvision"],
    "torchaudio": versions["torchaudio"],
}, sort_keys=True))
'@
    $temporary = Join-Path ([IO.Path]::GetTempPath()) "devconfig-python-versions-$([guid]::NewGuid().ToString('N')).py"
    try {
        [IO.File]::WriteAllText($temporary, $script, [Text.UTF8Encoding]::new($false))
        $result = Invoke-DevConfigNativeCommand -FilePath $PythonPath -Arguments @($temporary)
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
    $json = @($result.Output -split '\r?\n' | Where-Object { $_ }) | Select-Object -Last 1
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        return $null
    }
    try {
        return $json | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Test-PythonDistributionVersions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $PythonPath,
        [Parameter(Mandatory)] [hashtable] $Expected
    )

    if (-not (Test-Path -LiteralPath $PythonPath)) { return $false }
    $namesJson = @($Expected.Keys) | ConvertTo-Json -Compress
    $script = @"
import importlib.metadata
import json
names = json.loads(r'''$namesJson''')
result = {}
for name in names:
    try:
        result[name] = importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        result[name] = None
print(json.dumps(result, sort_keys=True))
"@
    $result = Invoke-DevConfigNativeCommand -FilePath $PythonPath -Arguments @('-c', $script)
    $json = @($result.Output -split '\r?\n' | Where-Object { $_ }) | Select-Object -Last 1
    if ($result.ExitCode -ne 0 -or -not $json) { return $false }
    $installed = $json | ConvertFrom-Json
    foreach ($name in $Expected.Keys) {
        if ($installed.$name -ne $Expected[$name]) { return $false }
    }
    return $true
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
        $launcherResult = Invoke-DevConfigNativeCommand -FilePath $launcher.Source -Arguments @(
            $selector, '-c', 'import sys; print(sys.executable)'
        )
        $launcherPath = [string](@($launcherResult.Output -split '\r?\n' | Where-Object { $_ }) | Select-Object -First 1)
        if ($launcherResult.ExitCode -eq 0 -and $launcherPath) {
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
        $versionResult = Invoke-DevConfigNativeCommand -FilePath $candidate -Arguments @(
            '-c', 'import sys; print(sys.version_info.major,sys.version_info.minor,sep=chr(46))'
        )
        $version = [string](@($versionResult.Output -split '\r?\n' | Where-Object { $_ }) | Select-Object -First 1)
        if ($versionResult.ExitCode -eq 0 -and $version.Trim() -eq '3.13') {
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

function Get-PipLocalWheelInstallArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $WheelPath)

    return @('-m', 'pip', 'install', '--only-binary=:all:', $WheelPath)
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

function Get-LlamaCodingDemoPlan {
    return [pscustomobject]@{
        Repository = 'Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF'
        Revision = 'f86cb2c1fa58255f8052cc32aeede1b7482d4361'
        FileName = 'qwen2.5-coder-1.5b-instruct-q4_k_m.gguf'
        Url = 'https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/f86cb2c1fa58255f8052cc32aeede1b7482d4361/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf?download=true'
        Sha256 = 'cc324af070c2ecbfd324a30884d2f951a7ff756aba85cb811a6ec436933bb046'
        Size = 1117320768
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

    $result = Invoke-DevConfigNativeCommand -FilePath $FilePath -Arguments $ArgumentList
    if ($result.Output) { Write-Host $result.Output.TrimEnd() }
    if ($result.ExitCode -ne 0) {
        throw "$DisplayName failed with exit code $($result.ExitCode)."
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

function Get-AiUpdatedPathValue {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string] $CurrentValue,
        [Parameter(Mandatory)] [string] $Path,
        [switch] $Prepend
    )

    $entries = @($CurrentValue -split ';' | Where-Object { $_ -and $_ -ne $Path })
    if ($Prepend) {
        return (@($Path) + $entries) -join ';'
    }
    return (@($entries) + $Path) -join ';'
}

function Add-UserPathEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $Prepend
    )

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    [Environment]::SetEnvironmentVariable(
        'Path',
        (Get-AiUpdatedPathValue -CurrentValue $current -Path $Path -Prepend:$Prepend),
        'User')
    $env:Path = Get-AiUpdatedPathValue -CurrentValue $env:Path -Path $Path -Prepend:$Prepend
}

function Install-VerifiedDirectorySwap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination
    )

    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $newPath = "$Destination.new-$([guid]::NewGuid().ToString('N'))"
    $oldPath = "$Destination.old-$([guid]::NewGuid().ToString('N'))"
    Move-Item -LiteralPath $Source -Destination $newPath
    try {
        if (Test-Path -LiteralPath $Destination) {
            Move-Item -LiteralPath $Destination -Destination $oldPath
        }
        Move-Item -LiteralPath $newPath -Destination $Destination
        if (Test-Path -LiteralPath $oldPath) {
            Remove-Item -LiteralPath $oldPath -Recurse -Force
        }
    } catch {
        if (-not (Test-Path -LiteralPath $Destination) -and (Test-Path -LiteralPath $oldPath)) {
            Move-Item -LiteralPath $oldPath -Destination $Destination -ErrorAction SilentlyContinue
        }
        throw
    } finally {
        Remove-Item -LiteralPath $newPath -Recurse -Force -ErrorAction SilentlyContinue
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

function Invoke-VerifiedLocalInstaller {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{64}$')] [string] $Sha256,
        [Parameter(Mandatory)] [string] $SignerPattern,
        [string[]] $ArgumentList = @(),
        [int[]] $SuccessExitCodes = @(0),
        [int] $TimeoutSeconds = 7200
    )

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actualHash -ne $Sha256) {
        throw "Installer SHA-256 mismatch for '$Path'. Expected $Sha256; got $actualHash."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch $SignerPattern) {
        throw "Installer signature validation failed for '$Path'."
    }
    $exitCode = Invoke-DevConfigProcess -FilePath $Path -Arguments $ArgumentList -TimeoutSeconds $TimeoutSeconds
    if ($exitCode -notin $SuccessExitCodes) {
        throw "Installer '$Path' failed with exit code $exitCode."
    }
}

function Get-CudaNvccPath {
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string] $ToolkitVersion)

    $cudaPath = [Environment]::GetEnvironmentVariable('CUDA_PATH', 'Machine')
    $pathCommand = Get-Command nvcc -ErrorAction SilentlyContinue
    $versionedCandidate = if ($ToolkitVersion) {
        Join-Path $env:ProgramFiles "NVIDIA GPU Computing Toolkit\CUDA\v$ToolkitVersion\bin\nvcc.exe"
    } else { $null }
    $cudaRoot = Join-Path $env:ProgramFiles 'NVIDIA GPU Computing Toolkit\CUDA'
    $installedCandidates = @(Get-ChildItem -LiteralPath $cudaRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^v[0-9]+\.[0-9]+$' } |
        Sort-Object { [version]$_.Name.Substring(1) } -Descending |
        ForEach-Object { Join-Path $_.FullName 'bin\nvcc.exe' })
    $candidates = @(
        $versionedCandidate,
        $(if ($cudaPath) { Join-Path $cudaPath 'bin\nvcc.exe' }),
        $(if ($pathCommand) { $pathCommand.Source }),
        $installedCandidates
    ) | Where-Object { $_ }

    $nvcc = $null
    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }
        $versionResult = Invoke-DevConfigNativeCommand -FilePath $candidate -Arguments @('--version')
        $versionOutput = $versionResult.Output
        if ($versionResult.ExitCode -eq 0 -and
            (-not $ToolkitVersion -or $versionOutput -match "release $([regex]::Escape($ToolkitVersion))")) {
            $nvcc = $candidate
            break
        }
    }
    if (-not $nvcc) {
        throw 'A matching CUDA nvcc.exe was not found. Reopen the terminal and verify CUDA_PATH.'
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
    $vswhereResult = Invoke-DevConfigNativeCommand -FilePath $vswhere -Arguments @(
        '-all', '-products', 'Microsoft.VisualStudio.Product.BuildTools', '-property', 'installationPath'
    )
    $installationOutput = @($vswhereResult.Output -split '\r?\n' | Where-Object { $_ })
    if ($vswhereResult.ExitCode -ne 0) {
        throw "vswhere.exe failed while locating Visual Studio Build Tools (exit $($vswhereResult.ExitCode))."
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
    $vsInstaller = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
    $command = "set `"PATH=$vsInstaller;%PATH%`" && call `"$vsDevCmd`" -arch=$target -host_arch=$target >nul && set"
    $environmentResult = Invoke-DevConfigNativeCommand -FilePath $env:ComSpec -Arguments @('/d', '/s', '/c', $command)
    $environmentLines = @($environmentResult.Output -split '\r?\n')
    if ($environmentResult.ExitCode -ne 0) {
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
    $vsInstaller = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
    return 'set "PATH={0};%PATH%" && call "{1}" -arch={2} -host_arch={2} >nul && "{3}" -arch=native -o "{4}" "{5}"' -f `
        $vsInstaller, $VsDevCmd, $target, $Nvcc, $Output, $Source
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
        [Parameter(Mandatory)] [string[]] $RequiredFile
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
        [Parameter(Mandatory)] [string[]] $RequiredFile,
        [string] $CacheDirectory = '',
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
    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = [string]::Concat('Bea', 'rer ', $env:GITHUB_TOKEN)
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
    $selection = "$($release.tag_name)|$(@($assets | ForEach-Object { "$($_.name)=$($_.digest)" }) -join '|')"
    $requiredFilesPresent = @($RequiredFile | Where-Object {
        Test-Path -LiteralPath (Join-Path $Destination $_)
    }).Count -eq $RequiredFile.Count
    if ((Test-Path -LiteralPath $markerPath) -and
        $requiredFilesPresent -and
        ((Get-Content -LiteralPath $markerPath -Raw).Trim() -eq $selection)) {
        return [pscustomobject]@{
            Tag = $release.tag_name
            Assets = $assets
            Action = 'already-current'
            Destination = $Destination
            CacheDirectory = $CacheDirectory
        }
    }

    $hadExistingRuntime = Test-Path -LiteralPath $Destination
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "devconfig-$([guid]::NewGuid().ToString('N'))"
    $extractPath = Join-Path $tempRoot 'expanded'
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    try {
        foreach ($asset in $assets) {
            $expectedHash = $asset.digest.Substring(7)
            if ($CacheDirectory) {
                $releaseCache = Join-Path $CacheDirectory $release.tag_name
                New-Item -ItemType Directory -Path $releaseCache -Force | Out-Null
                $archivePath = Join-Path $releaseCache $asset.name
            } else {
                $archivePath = Join-Path $tempRoot $asset.name
            }
            $cacheValid = (Test-Path -LiteralPath $archivePath) -and
                ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -eq $expectedHash)
            if (-not $cacheValid) {
                $downloadPath = "$archivePath.download-$([guid]::NewGuid().ToString('N'))"
                try {
                    Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $downloadPath -UseBasicParsing
                    $downloadHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
                    if ($downloadHash -ne $expectedHash) {
                        throw "SHA-256 mismatch for '$($asset.name)'. Expected $expectedHash; got $downloadHash."
                    }
                    Move-Item -LiteralPath $downloadPath -Destination $archivePath -Force
                } finally {
                    if (Test-Path -LiteralPath $downloadPath) {
                        Remove-Item -LiteralPath $downloadPath -Force
                    }
                }
            }
            $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
            if ($actualHash -ne $expectedHash) {
                throw "SHA-256 mismatch for '$($asset.name)'. Expected $expectedHash; got $actualHash."
            }
            Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
        }
        $missingFiles = @($RequiredFile | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $extractPath $_))
        })
        if ($missingFiles.Count -gt 0) {
            throw "Verified release $($release.tag_name) did not contain required files: $($missingFiles -join ', ')."
        }
        Install-VerifiedDirectorySwap -Source $extractPath -Destination $Destination
        Set-Content -LiteralPath $markerPath -Value $selection -Encoding ascii
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }

    return [pscustomobject]@{
        Tag = $release.tag_name
        Assets = $assets
        Action = $(if ($hadExistingRuntime) { 'upgraded' } else { 'installed' })
        Destination = $Destination
        CacheDirectory = $CacheDirectory
    }
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

# SIG # Begin signature block
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC9sQBWdlz8yRX9
# qC7qPOm74hKSm9EPx28hElnpoarWNaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
# yE7XD1dIAAAAAAIdMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQzWhcNMjcwNDE1MTg1
# OTQzWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDQvewXxx9gZZFC6Ys1WBay8BJ8kGA4JQnH5CMafqOASlTpK9H8
# o5ZXTXt0caVQTNMUPt445wXYD+dFtaKWTwDn1I52oUSrC9vJin1Gsqt+zyKJL5Dg
# 3eQXbQNR61DmMy20GLTIO3SFed9Rfi/ophgCLGFLDR3r0KvHjwMb/jYWS0celV/4
# Lz27LfAekm8v9E5IXaeiXbAUYZKK090n4CVl3JBtbN+9DtI9SNu/yjvozW52/u7R
# X/Ttpa/KDlpuokZ+Zcbvmtd9ur9gFLvZzh41o9MsE/clQtdaFWGvuo6Jua/ntpgk
# ey3E5/vBFe+MJPG6phdnuo6r57ZudCudiI1bAgMBAAGjggGbMIIBlzAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFH6QuMwqcPG0hQlQ6c5jCtTTLrVeMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQL
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDAxMis1MDc1NTkw
# HwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEwYAYDVR0fBFkwVzBVoFOg
# UYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNybDBtBggrBgEFBQcBAQRh
# MF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# dDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBKTbYOjzwTG/DXGaz9
# s6+fQeaTtDcFmMY+5UyVFCyj7Pv+5i37qfX8lSL/tBIfYQfWsMuBQlfZurJD6r4H
# VJ2CeH+1fgiq8dcHdVKoZ3Sa2qXoX3cq9iS8cVb06B7+5/XJ7I0OxHH9fDsvJ3T3
# w5V/ZtAIFmLrl+P0CtG+92uzRsn0nTbdFjOkLMLWPLAU3THohKRlSEMgFJpPkm5n
# 5UAZ35xX6FWCrDLsSKb555bTifwa8mJBwdlof0bmfYidH+dxZ1FdDxvLnNl9zeKs
# A4kejaaIqqIPguhwAti5Ql7BlTNoJNwxCvBmqW2MQLnCkYN/VVUsR3V2x/rcTNzo
# Bf/Z/SpROvdaA2ZOOd1uioXJt3tdLQ7vHpqpib0KfWr/FWXW10q38VxfCnRQBqzb
# SuztR7nEMuzX7Ck+B/XaPDXd1qh72+QYyB0Z2VzWmO9zsnb9Uq/dwu8LGeQqnyu6
# 7SDGACvnXii2fb9+US492VTnXSnFKyqwgzUyFMtZK1/sHYTv6bG4TtQUygQxTN+Z
# V+aJIlKO2MqZ7bKrAnOzS9m6NgoTdWOq11bTOZwKlIEV/EhV9SWkDmdpR/hPPT2v
# 6TEj4F8PT/zHjRezIU5c/DGlt/VhY/pK0XkJtEyMmmS1BMtjU/rqBZVMIm3dnxQs
# /TBByr+Cf8Z1r7aifQVQ+WSqzjCCBr0wggSloAMCAQICEzMAAAA5O7Y3Gb8GHWcA
# AAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoXDTM2MDMyMjIyMTMwNFow
# VzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEo
# MCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAyNDCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeqlRYHNa265v4IY9fH8TKh
# emHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo0dtS/EW6I/yEL/bLSY8h
# KpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATvQVL4tcf03aTycsz8QeCd
# M0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a1uv1zerOYMnsneRRwCbp
# yW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1FyQfK0fVkaya8SmVHQ/t
# Of23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfOGSWHIIV4YrTJTT6PNty5
# REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7ttOu1bVnXfHaqPYl2rPs
# 20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJuz2MXMCt7iw7lFPG9LXK
# Gjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxSCwyoGIq0PhaA7Y+VPct5
# pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOmVQop36wUVUYklUy++vDW
# eEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3SkE/xIkgpfl22MM1itkZ
# 35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGC
# NxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPXLQaUEggxMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU
# ci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAwTgYIKwYBBQUHMAKGQmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAFJQfOChP7onn6fLI
# MKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D5W4wMwYeLystcEqfkjz4
# NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBYnbu0+THSuVHTe0VTTPVh
# ily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSIvgn0JksVBVMYVI5QFu/q
# hnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6aR9y34aiM1qmxaxBi6OU
# nyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4wPKC5OmHm1DQIt/MNokbb
# H3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7RTX8AdBPo0I6OEojf39z
# uFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK/fg8B2qjW88MT/WF5V5u
# vZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSKYBv0VisCzfxgeU+dquXW
# 9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkwYTu/9dLeH2pDqeJZAABV
# DWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVTQl0v4q8J/AUmQN5W4n10
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnHMIIZwwIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIID67ib8YqvmTqd7xA1VdsgPOS31JOx6/VOjra3Pb3aJMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAu9Z8oBbBvhpsTlKn
# zRmhBtOehS5V6DuqfgZ8WgIp/ICG/oF8E1OkfLBRnn8hvKo1qADVlBGu7WE1Bjwl
# OTUOusDUcy4rD5opunzYdGgfTm8R+XZMxzoxssubKhg5m+Yrs/qrkSzv7BN78Yec
# qLh4mLdpJadY9JGCqn90tiSohqr5F3IEQ94JeRBPIWsqb4x+raKr6fzw7vhfwwYD
# IUXwg2ceQosppTPi3qrAoJIzt3Uk3ys+v9wGxk2RzEpwIuMBn7MxTeI5uLpPsx/o
# DKpE3qBLkuqk3wFcy3CaoEbIDqmdOW9b+a4Y6rMG2gkKxGT9D4yDlvVQmSUSYCqJ
# MWTRmqGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3Aw
# ghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCB8lWh2N/Wwgp7s
# 7uBTePfQaiWMVuxN1qeQDqpwsKJU0QIGaqouxP/OGBMyMDI2MTAwOTAwMTc0MC43
# MDlaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODkwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgIT
# MwAAAiJB0vaq/8i1/wABAAACIjANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTZaFw0yNzA1MTcxOTM5NTZa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046ODkwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC1
# ueKJukIuUsAAJo/AY5DZRqH7bhgv7CWGNlEdbRGoITrdE6Wsn57NaNu1BTdjBbFc
# v7Rfixte0x+HRvXSqsD+WeSX/6/y9wE0Mz+xRPTGIY20K7aQDa68OyzVyUeUCypy
# ZC/gW/3ytO/ZOnU9H2ri77kJP8ABrqyy1UxX/OseEgvHsj8yikWT0ARtrjWbXMHF
# zSOo5hQcfUmMXKqWWz6+N0+UynhGy1n+doW4WZgpH8Y5W7hpSokWj1M/Lu4wi3o6
# Dz9vVWukcgUFGjLAl4YZpOhah7HuiC/alXImMQf8C3A8q/6/1hFoeIZB4UGkywxB
# /OSTOSsL6+39pDqzM7CgOpf4V799kN94yM9uXJI5T/SiA5MdIZIhEW0+bh85RqDh
# 5YW3/oav54RPxw5OPlH64QV6KJkl0FIElMVoLNo8UWRQcMD179x7WASjC6LsaNZ7
# yK0qcESIsL1wiQmdfQBxcqrFCpIQfnmQFkOp9IyXUWqza8tmpz8E6aXg9b1eiAT3
# PVTgrOlPi/hYZCfPxX/6jGtyPjy1CiwOmJamohmSU//COAenfRT2G2HMRUpCX1zs
# +AmDmdQM1XRab4YSALLAlDzGCsgI77nnuJjoXAliJmv7NfrvWAcA5KqCUOWQ6kSP
# t5r28MfKXWJJpSXtFeS/MkDzJy/iJRVyHcFy/B+MtwIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFFkHwGoDJ5ZbEEiu8KstiusqaozQMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQBiAM+nqrpwG29txSXv42o+CsTe2C4boaRfFju9JaWkLTHwq7pknNONL3n+
# UG3x/B083EKXiFYrAmul7BTHCGXU63/xRsZ2wj3ZmR0A4d9nf9saCJVm4juPVFBa
# i/oktOOYH2j+1+zM70woN5ongB/pvy7X8AfY6JB4XPvb80Qz7fY5eddbnwjzg1sZ
# hUPFbbcweWeACINrzqFK62mMeXKmhtufMraoogJeJXfWY3x4/pbubgENT3+pXT65
# 203CPF9kfdKE7GKAIRYy3xkBTDvFd8dufjOpCn38nK6qMlVtnBjDhWQG0PM3E/ox
# Bs5UBrI6pBYkmIHtbjifDquHT+ThaVV7xHc6InoSc3aNzX49JHUgQmuvDdMjLkbY
# XeA0/1q5IxSg2U+ycZBOvAi3udZPKhA5VzODjf/ucu/vFtXrYcRkmGKN3jujaK3/
# yMZi2Ju5NEL3ISWorwp7RjeZg+JMIK0fosuVj+YCm5r64LH/D9QJDAj+XfZaNeFd
# v90K5A0QRRGP/poB9yTIVjEXj/uJzp8L4Dd44sAquqDOiHdkLgxfK8nPqpCSWPZ9
# G+RCPm85o9cAfxENtrSuOwcpyKzxsRCYCL+PK4+98orit9EVJ/LLoCeG+jLlj0Ka
# D4Qy6sZe4rWMr1brQLosTBZNwFnXxNjInCWBd0i7is1yTS/4qTCCB3EwggVZoAMC
# AQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29m
# dCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIy
# NVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9
# DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2
# Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N
# 7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXc
# ag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJ
# j361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjk
# lqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37Zy
# L9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M
# 269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLX
# pyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLU
# HMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode
# 2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEA
# ATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYE
# FJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEB
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEE
# AYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB
# /zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEug
# SaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9N
# aWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsG
# AQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jv
# b0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt
# 4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsP
# MeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++
# Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9
# QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2
# wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aR
# AfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5z
# bcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nx
# t67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3
# Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+AN
# uOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/Z
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQMIICOAIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOjg5MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQC7ycXVZx3bsDpJkr7Vucgpksoz
# uKCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7nJTTDAiGA8yMDI2MTAwODE3MzcxNloYDzIwMjYxMDA5MTczNzE2
# WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDuclNMAgEAMAoCAQACAgF3AgH/MAcC
# AQACAhH8MAoCBQDuc6TMAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkK
# AwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAMMC
# QdbbheSVYLX7KkDUC8Gg/oG5Wa2z+odTYTbFIgkySFJA3DwWIGULiL7AO45AhkEn
# tFtWgxerakFesRKiLyLKdVOrS8paNybQjTkSRpXEusEszGNaXe8C3wYSD6cdfS3v
# gXtstW6/OqB3hcItIQOlF5rcIgJoRlLUo0qhrSy1+wAS2VU8sWwpRKsZBef7S76k
# LApfROsgSL0TV4qVFpuA2Xi+eAllupOUrHkUlxpwfMEMjayVID5ro7mctvXJ9Nre
# 9RuEle1vFIgBsQ/fxik7SJtyi2caprqnzgkyppkIDdD9ITYQPV3aZBugOjOPfzyY
# zRQb0/oveeIYBENuXoIxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFt
# cCBQQ0EgMjAxMAITMwAAAiJB0vaq/8i1/wABAAACIjANBglghkgBZQMEAgEFAKCC
# AUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCD1
# BuHszfk+PuMdXgdm+4Bzh5d3QcGEk4wDgNwuQl+h4jCB+gYLKoZIhvcNAQkQAi8x
# geowgecwgeQwgb0EIAVgXQEKBOfGgjNskmDOmbcEIOnHGNwA+QcRufDR5AkTMIGY
# MIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIiQdL2qv/I
# tf8AAQAAAiIwIgQgJ8pI6OAOmqUpsVkeQV1274LRGDnXh70tMDVkbw+QxmgwDQYJ
# KoZIhvcNAQELBQAEggIATGcOuAOD/MT1mP4NearFeq8eckqgFzcDjPcnRy9RIkgK
# EHJFSJaj3ZprL0ghE9xcancjN51H/kTizLUqExIqo3bEw0UZQ9wzECdqOuI3QDWe
# 3o/x+MsVGZ5EPrl0b3dRiiWGeSBeJlKSx7HlPnvDYOoN2dHNtMVHD+usoN/TMCHL
# oAr90xggFBbzd2kZeZdtSXesuicd55/0lZBg7NUGrODfUdy0gqK6/jq/HsOdgHAA
# YtwCkpyQXNRZaFW8Gzph+qdG2OSc9UUrv4qrCvk2/dZD1OgtzJ7VxcpxruhjWQA7
# ivZMWptR2chUYnuCZ0gclvZYUnGQaJLO6j60LPUsPY+3DERWN8kkSBML/5exJM75
# Wcw7KnmfuZnTJYWbdelyKohkcMkx2SkOS+EUfM76zz1KkHrCmw0XnSGwMx7Ne/Rp
# cIj6oeYKewvetR87snzqx6/dtBCVXya80QhRI5mHXj3FipO6f/9qqqlvtgljz2PQ
# kg044WetNUnSph/LxVeeJUj10JUtJcwNxa4z0kTz1FBJqOyzueIhwuIllHA01+pG
# RNITx5fD3/HHNWgCftlNCDZu/eeOPjf+0SxcgGoWCGRR0ZS9LbIbcvwPBKHv72p4
# Eyaa+reOqa8BV3yEl1GrNt++9ec9/pZ3IEHXMulDtU5orzSoM4MGaotjCIE2EyU=
# SIG # End signature block
