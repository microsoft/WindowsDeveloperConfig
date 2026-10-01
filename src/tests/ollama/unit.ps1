$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')

$x64 = Resolve-OllamaInstallPlan -Architecture X64
Assert-Equal $x64.PackageId 'Ollama.Ollama' 'Ollama x64 should use the current desktop package'
Assert-Equal $x64.LaunchMode 'Desktop' 'Ollama x64 should use desktop background behavior'

$arm = Resolve-OllamaInstallPlan -Architecture Arm64
Assert-Equal $arm.Method 'GitHubRelease' 'Ollama ARM64 should use the current official release'
Assert-Equal $arm.PackageId $null 'Ollama ARM64 should not use a WinGet portable package'
Assert-Equal $arm.LaunchMode 'ManagedStartup' 'ARM64 archive should become a managed per-user application'
Assert-Equal $arm.InstallType 'native-arm64-managed-archive' 'ARM64 source and install semantics should be explicit'
$repeat = Resolve-OllamaInstallPlan -Architecture Arm64
Assert-Equal ($repeat | ConvertTo-Json -Compress) ($arm | ConvertTo-Json -Compress) 'Ollama plan should be idempotent'

$component = (Get-AiCatalogData).Components.OllamaArm64
Assert-Equal $component.AssetPattern '^ollama-windows-arm64\.zip$' 'ARM64 should resolve the exact official native archive'
Assert-Equal $component.SourceType 'native-arm64-managed-archive' 'ARM64 report source should not call the installation portable'
Assert-True ($component.InstallPath -match 'Programs%?\\Ollama|Programs\\Ollama') 'ARM64 should install under the per-user Programs convention'
Assert-True ($component.NormalChannelLimitation -match 'x64 setup EXE') 'ARM64 should explicitly reject x64 setup emulation'
Assert-True ($component.NormalChannelLimitation -notmatch 'Portable') 'ARM64 should not rely on the portable WinGet identity'
Assert-True (-not $component.ContainsKey('PortablePackageId')) 'ARM64 metadata should not expose a portable package fallback'

$paths = Get-OllamaManagedPaths -LocalAppData 'C:\Users\Test\AppData\Local'
Assert-Equal $paths.InstallRoot 'C:\Users\Test\AppData\Local\Programs\Ollama' 'Managed Ollama should use the stable per-user Programs path'
Assert-Equal $paths.InstallManifest 'C:\Users\Test\AppData\Local\Programs\Ollama\.devconfig-install.json' 'Managed Ollama should persist its install manifest'
$startupCommand = Get-OllamaStartupCommand -Executable $paths.Executable
Assert-Equal $startupCommand '"C:\Users\Test\AppData\Local\Programs\Ollama\ollama.exe" serve' 'Startup command should invoke the managed executable'
$pathOnce = Get-AiUpdatedPathValue -CurrentValue 'C:\Windows;C:\Tools' -Path $paths.InstallRoot -Prepend
$pathTwice = Get-AiUpdatedPathValue -CurrentValue $pathOnce -Path $paths.InstallRoot -Prepend
Assert-Equal $pathOnce $pathTwice 'Managed Ollama PATH insertion should be idempotent'
Assert-True $pathOnce.StartsWith($paths.InstallRoot) 'Managed Ollama should precede stale aliases on PATH'

Assert-ThrowsLike {
    Assert-CommandAvailable -CommandName 'devconfig-command-that-does-not-exist' -Remediation 'Install the missing tool.'
} '*Install the missing tool.*' 'Missing tools should produce actionable errors'

$model = Get-OllamaModelSmokePlan
Assert-Equal $model.Model 'qwen3:0.6b' 'Ollama should use the tested small library model'
Assert-Equal $model.ModelBlobSha256 '7f4030143c1c477224c5434f8272c662a8b042079a0a584f0a27a1684fe2e1fa' 'Ollama model blob should be pinned'
$request = New-OllamaGenerateRequest -Model $model.Model -Marker $model.Marker
Assert-Equal $request.stream $false 'Ollama inference should be non-streaming'
Assert-Equal $request.format.properties.marker.enum[0] $model.Marker 'Ollama JSON schema should constrain the marker'
Assert-Equal $request.options.seed 42 'Ollama inference should use a fixed seed'
$manifestPath = Get-OllamaModelManifestPath -ModelRoot 'C:\models' -Model 'qwen3:0.6b'
Assert-Equal $manifestPath 'C:\models\manifests\registry.ollama.ai\library\qwen3\0.6b' 'Ollama digest verification should target the pulled tag manifest'
$installScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\ollama\install.ps1') -Raw
Assert-True ($installScript -match '\[switch\]\s*\$SkipModelSmoke') 'Ollama should expose model-smoke opt-out'
Assert-True ($installScript -match '\[switch\]\s*\$PlanOnly') 'Ollama should expose non-mutating plan mode'
Assert-True ($installScript -match '\[switch\]\s*\$Uninstall') 'Ollama should expose managed uninstall'
Assert-True ($installScript -match '\[switch\]\s*\$RemoveModels') 'Ollama uninstall should make model removal explicit'
Assert-True ($installScript -match 'Ensure-AiWingetPackage') 'Ollama x64 should use direct package acquisition'
Assert-True ($installScript -notmatch 'apply-configuration') 'Ollama should not use winget configure'
Assert-True ($installScript -match '/api/ps') 'Ollama report should use machine-readable VRAM allocation evidence'
Assert-True ($installScript -match '\$inferenceEvidence = \$null') 'Ollama model-smoke opt-out should use explicit skipped evidence'
Assert-True ($installScript -match 'Stop-OllamaManagedProcesses') 'Ollama should stop only Dev Config-managed servers before swapping the runtime'
Assert-True ($installScript -match 'Stop-OllamaManagedProcesses -InstallRoot \$paths\.LegacyRoot') 'Managed upgrade should stop and migrate the prior Dev Config ARM64 runtime'
Assert-True ($installScript -match '\[void\]\(Stop-OllamaManagedProcesses -InstallRoot \$paths\.InstallRoot\)') 'ARM64 validation should clean resolver-owned child processes before persistent startup'
Assert-True ($installScript -match 'Install-VerifiedGitHubLatestAsset') 'Ollama ARM64 should use verified official release acquisition'
Assert-True ($installScript -match '-CacheDirectory \$paths\.CacheDirectory') 'Ollama ARM64 should reuse a verified asset cache'
Assert-True ($installScript -match 'Write-DevConfigTextFile -Path \$paths\.InstallManifest') 'Ollama ARM64 should persist tag, digest, files, and source metadata'
Assert-True ($installScript -match 'Set-OllamaStartupRegistration') 'Ollama ARM64 should register current-user startup'
Assert-True ($installScript -match 'Get-AiPeArchitecture') 'Ollama ARM64 should prove native executable architecture'
Assert-True ($installScript -match 'persistentEndpoint') 'Ollama ARM64 should report the installed persistent endpoint'
Assert-True ($installScript -match 'RedirectStandardOutput \$persistentStdout') 'Persistent Ollama should not inherit the setup output pipe'
Assert-True ($installScript -match 'RedirectStandardError \$persistentStderr') 'Persistent Ollama errors should be retained in the managed install directory'
Assert-True ($installScript -match "source = 'official native ARM64 archive'") 'Managed install manifest should record its authoritative source'
Assert-True ($installScript -match 'installedFiles = @\(') 'Managed install manifest should record installed files'
Assert-True ($installScript -match 'Remove-UserPathEntry -Path \$paths\.LegacyRoot') 'Managed upgrade should remove the obsolete runtime path'
$currentProcess = [pscustomobject]@{ ProcessId = 123 }
$alternateProcess = [pscustomobject]@{ Id = 456 }
$minimalProcess = [pscustomobject]@{}
Assert-Equal (Get-AiProcessId -ProcessObject $currentProcess) 123 'Ollama cleanup should support CIM ProcessId'
Assert-Equal (Get-AiProcessId -ProcessObject $alternateProcess) 456 'Ollama cleanup should support Process.Id'
Assert-Equal (Get-AiProcessId -ProcessObject $minimalProcess) $null 'Missing process id should not throw under StrictMode'
Assert-Equal @(Get-AiProcessIds -ProcessObjects @()).Count 0 'Empty process collection should produce an empty id list'
Assert-Equal ((Get-AiProcessIds -ProcessObjects @($currentProcess)) -join ',') '123' 'Single process collection should project one id'
Assert-Equal ((Get-AiProcessIds -ProcessObjects @($currentProcess, $alternateProcess, $minimalProcess)) -join ',') '123,456' 'Multiple process collection should project only usable ids'
Assert-True ($installScript -match 'Get-AiProcessId') 'Ollama cleanup should use guarded process id extraction'
Assert-True ($installScript -match 'Get-AiFreeTcpPort') 'Ollama ARM64 should allocate a resolver-owned API endpoint'
Assert-True ($installScript -match '\$env:OLLAMA_HOST') 'Ollama ARM64 CLI and server should use the owned endpoint'
Assert-True ($installScript -match 'expectedVersion') 'Ollama ARM64 should verify the managed server matches the acquired release'
$freePort = Get-AiFreeTcpPort
Assert-True ($freePort -gt 0 -and $freePort -le 65535) 'Free TCP port helper should return a usable loopback port'

$assetRoot = Join-Path $env:TEMP "devconfig-ollama-asset-$([guid]::NewGuid().ToString('N'))"
$payload = Join-Path $assetRoot 'payload'
$fixtureArchive = Join-Path $assetRoot 'ollama-windows-arm64.zip'
$destination = Join-Path $assetRoot 'managed'
$cache = Join-Path $assetRoot 'cache'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
$fakeExe = Join-Path $payload 'ollama.exe'
$bytes = [byte[]]::new(256)
$bytes[0] = 0x4D; $bytes[1] = 0x5A
[BitConverter]::GetBytes([int]128).CopyTo($bytes, 0x3C)
$bytes[128] = 0x50; $bytes[129] = 0x45
[BitConverter]::GetBytes([uint16]0xAA64).CopyTo($bytes, 132)
[IO.File]::WriteAllBytes($fakeExe, $bytes)
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $fixtureArchive
$script:fakeOllamaDigest = (Get-FileHash -LiteralPath $fixtureArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$script:ollamaDownloadCount = 0
$script:ollamaApiUnavailable = $false
function Invoke-RestMethod {
    if ($script:ollamaApiUnavailable) {
        throw 'API rate limit exceeded'
    }
    return [pscustomobject]@{
        tag_name = 'v0.35.0'
        draft = $false
        prerelease = $false
        assets = @([pscustomobject]@{
            name = 'ollama-windows-arm64.zip'
            digest = "sha256:$script:fakeOllamaDigest"
            browser_download_url = 'https://example.invalid/ollama-windows-arm64.zip'
        })
    }
}
function Invoke-WebRequest {
    param($Uri, $Headers, $OutFile, [switch] $UseBasicParsing)
    $script:ollamaDownloadCount++
    Copy-Item -LiteralPath $script:fixtureArchive -Destination $OutFile
}
try {
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $destination 'ollama.exe') -Value 'stale-runtime'
    Set-Content -LiteralPath (Join-Path $destination '.devconfig-version') `
        -Value "v0.34.4|ollama-windows-arm64.zip|sha256:$('0' * 64)" `
        -Encoding ascii
    $firstInstall = Install-VerifiedGitHubLatestAsset `
        -Repository 'ollama/ollama' `
        -AssetPattern '^ollama-windows-arm64\.zip$' `
        -Destination $destination `
        -VersionMarker '.devconfig-version' `
        -RequiredFile 'ollama.exe' `
        -CacheDirectory $cache
    Assert-Equal $firstInstall.Action 'installed-or-upgraded' 'First managed archive application should install atomically'
    Assert-Equal $firstInstall.Tag 'v0.35.0' 'A stale 0.34.4 marker should resolve and install the current 0.35.0 release'
    Assert-Equal (Get-AiPeArchitecture -Path (Join-Path $destination 'ollama.exe')) 'Arm64' 'Installed official archive fixture should remain native ARM64'
    $secondInstall = Install-VerifiedGitHubLatestAsset `
        -Repository 'ollama/ollama' `
        -AssetPattern '^ollama-windows-arm64\.zip$' `
        -Destination $destination `
        -VersionMarker '.devconfig-version' `
        -RequiredFile 'ollama.exe' `
        -CacheDirectory $cache
    Assert-Equal $secondInstall.Action 'already-current' 'Matching managed archive installation should skip atomic replacement'
    Assert-Equal $script:ollamaDownloadCount 1 'Verified archive cache should prevent repeat download'
    Assert-True (Test-Path -LiteralPath $firstInstall.CachePath) 'Managed acquisition should report its verified archive cache'
    $script:ollamaApiUnavailable = $true
    $offlineInstall = Install-VerifiedGitHubLatestAsset `
        -Repository 'ollama/ollama' `
        -AssetPattern '^ollama-windows-arm64\.zip$' `
        -Destination $destination `
        -VersionMarker '.devconfig-version' `
        -RequiredFile 'ollama.exe' `
        -CacheDirectory $cache
    Assert-Equal $offlineInstall.Action 'already-current' 'Rate-limited rerun should retain the digest-verified current runtime'
    Assert-Equal $offlineInstall.Resolution 'verified-cache-fallback' 'Offline current-state proof should be explicit'
    Assert-True ($offlineInstall.Warning -match 'rate limit') 'Offline current-state proof should report why latest resolution was unavailable'
} finally {
    $script:ollamaApiUnavailable = $false
    Remove-Item -LiteralPath $assetRoot -Recurse -Force
}

$peRoot = Join-Path $env:TEMP "devconfig-pe-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $peRoot -Force | Out-Null
try {
    foreach ($fixture in @(
        @{ Name = 'arm64.exe'; Machine = 0xAA64; Expected = 'Arm64' },
        @{ Name = 'x64.exe'; Machine = 0x8664; Expected = 'X64' }
    )) {
        $bytes = [byte[]]::new(256)
        $bytes[0] = 0x4D; $bytes[1] = 0x5A
        [BitConverter]::GetBytes([int]128).CopyTo($bytes, 0x3C)
        $bytes[128] = 0x50; $bytes[129] = 0x45
        [BitConverter]::GetBytes([uint16]$fixture.Machine).CopyTo($bytes, 132)
        $fixturePath = Join-Path $peRoot $fixture.Name
        [IO.File]::WriteAllBytes($fixturePath, $bytes)
        Assert-Equal (Get-AiPeArchitecture -Path $fixturePath) $fixture.Expected "PE architecture should identify $($fixture.Expected)"
    }
} finally {
    Remove-Item -LiteralPath $peRoot -Recurse -Force
}

$uninstallRoot = Join-Path $env:TEMP "devconfig-ollama-uninstall-$([guid]::NewGuid().ToString('N'))"
$testPaths = [pscustomobject]@{
    InstallRoot = Join-Path $uninstallRoot 'Programs\Ollama'
    LegacyRoot = Join-Path $uninstallRoot 'legacy'
    CacheDirectory = Join-Path $uninstallRoot 'cache'
    StartupRegistryPath = "HKCU:\Software\WindowsDeveloperConfigTests\$([guid]::NewGuid())"
    StartupValueName = 'Ollama'
}
$models = Join-Path $uninstallRoot 'models'
try {
    New-Item -ItemType Directory -Path $testPaths.InstallRoot, $testPaths.LegacyRoot, $testPaths.CacheDirectory, $models -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $testPaths.InstallRoot 'ollama.exe') -Value 'runtime'
    Set-Content -LiteralPath (Join-Path $models 'model') -Value 'preserve'
    Set-OllamaStartupRegistration -RegistryPath $testPaths.StartupRegistryPath -ValueName $testPaths.StartupValueName -Executable (Join-Path $testPaths.InstallRoot 'ollama.exe') | Out-Null
    $removed = Remove-OllamaManagedInstallation -Paths $testPaths -ModelRoot $models
    Assert-True $removed.RuntimeRemoved 'Managed uninstall should remove its runtime'
    Assert-True $removed.ModelsPreserved 'Managed uninstall should preserve models by default'
    Assert-True (Test-Path -LiteralPath $models) 'Managed uninstall should leave model data'
    Assert-True (-not (Get-ItemProperty -LiteralPath $testPaths.StartupRegistryPath -Name $testPaths.StartupValueName -ErrorAction SilentlyContinue)) 'Managed uninstall should remove startup registration'

    New-Item -ItemType Directory -Path $testPaths.InstallRoot, $models -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $testPaths.InstallRoot 'ollama.exe') -Value 'runtime'
    Set-Content -LiteralPath (Join-Path $models 'model') -Value 'remove'
    $removedWithModels = Remove-OllamaManagedInstallation -Paths $testPaths -ModelRoot $models -RemoveModels
    Assert-True (-not $removedWithModels.ModelsPreserved) 'Explicit model removal should be recorded'
    Assert-True (-not (Test-Path -LiteralPath $models)) 'Explicit model removal should delete model data'
} finally {
    Remove-Item -LiteralPath $testPaths.StartupRegistryPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $uninstallRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-CimInstance {
    @(
        [pscustomobject]@{
            ProcessId = 101
            ExecutablePath = 'C:\Users\Test\AppData\Local\Programs\Ollama\ollama.exe'
            CommandLine = '"C:\Users\Test\AppData\Local\Programs\Ollama\ollama.exe" serve'
        }
        [pscustomobject]@{
            ProcessId = 202
            ExecutablePath = 'C:\Program Files\Ollama\ollama.exe'
            CommandLine = '"C:\Program Files\Ollama\ollama.exe" serve'
        }
    )
}
$managedProcesses = @(Get-OllamaManagedProcesses -InstallRoot 'C:\Users\Test\AppData\Local\Programs\Ollama')
Assert-Equal $managedProcesses.Count 1 'Managed process discovery should not target unrelated Ollama installations'
Assert-Equal $managedProcesses[0].ProcessId 101 'Managed process discovery should select only the Dev Config executable'

Write-Host "UNIT_OK: ollama ($script:AssertionCount assertions)"
