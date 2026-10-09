<#
.SYNOPSIS
  Install the architecture-applicable Ollama WinGet application and run verified model inference.

.PARAMETER SkipModelSmoke
  Verify the CLI and local API without pulling or running the quick model.

.PARAMETER Uninstall
  Remove the Ollama application. Models are preserved by default.

.PARAMETER RemoveModels
  With -Uninstall, also remove the configured Ollama model directory.
#>
[CmdletBinding()]
param(
    [switch] $SkipModelSmoke,
    [switch] $Uninstall,
    [switch] $RemoveModels,
    [switch] $PlanOnly,
    [string] $ReportPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\_common\ai-report.ps1')

if ($RemoveModels -and -not $Uninstall) {
    throw '-RemoveModels requires -Uninstall.'
}

$architecture = Get-DevConfigArchitecture
$plan = Resolve-OllamaInstallPlan -Architecture $architecture
$component = if ($architecture -eq 'Arm64') {
    (Get-AiCatalog).Components.OllamaArm64
} else {
    (Get-AiCatalog).Components.OllamaX64
}
$legacyPaths = Get-OllamaManagedPaths
$modelRoot = if ($env:OLLAMA_MODELS) { $env:OLLAMA_MODELS } else { Join-Path $HOME '.ollama\models' }
$report = New-AiWorkloadReport -Id 'ollama' -Request @{
    Architecture = $architecture
    SkipModelSmoke = [bool]$SkipModelSmoke
    Uninstall = [bool]$Uninstall
    RemoveModels = [bool]$RemoveModels
    PlanOnly = [bool]$PlanOnly
}
if (-not $ReportPath) { $ReportPath = Get-AiDefaultReportPath -Id 'ollama' }
trap {
    Write-AiFailureReport -Report $report -Path $ReportPath -ErrorRecord $_
    throw $_
}

function Add-OllamaAcquisition {
    param(
        [Parameter(Mandatory)] [string] $Action,
        [AllowNull()] $PackageEvidence,
        [AllowNull()] $MigrationEvidence
    )
    $entry = [ordered]@{
        component = $component.Component
        vendor = $component.Vendor
        architecture = $architecture
        maturity = $component.Maturity
        sourceType = $component.SourceType
        packageId = $component.PackageId
        versionPolicy = $component.VersionPolicy
        integrity = $component.Integrity
        installPath = $component.InstallPath
        reasonNormalChannelInsufficient = $component.NormalChannelLimitation
        expectedStableSource = $component.ExpectedStableSource
        migrationTrigger = $component.MigrationTrigger
        cleanupUpgrade = $component.CleanupUpgrade
        legacyManagedArchiveMigration = $MigrationEvidence
        action = $Action
        packageEvidence = $PackageEvidence
    }
    if (-not $Uninstall) {
        $entry.selectedInstaller = [ordered]@{
            applicable = $manifestEvidence.Applicable
            architecture = $manifestEvidence.Architecture
            version = $manifestEvidence.Version
            url = $manifestEvidence.InstallerUrl
            sha256 = $manifestEvidence.InstallerSha256
        }
    }
    Add-AiReportAcquisition -Report $report -Entry $entry
}

function Remove-OllamaPortablePackage {
    [CmdletBinding()]
    param([switch] $PlanOnly)

    if ($PlanOnly) {
        return [pscustomobject]@{ Action = 'not-selected-cleanup-if-possible'; PackageId = 'Ollama.Ollama.Portable' }
    }
    $listed = Invoke-DevConfigNativeCommand -FilePath 'winget.exe' -Arguments @(
        'list', '--id', 'Ollama.Ollama.Portable', '--exact', '--source', 'winget',
        '--disable-interactivity', '--accept-source-agreements'
    )
    if ($listed.ExitCode -eq $Script:DevConfigWingetNotFound) {
        return [pscustomobject]@{ Action = 'already-absent'; PackageId = 'Ollama.Ollama.Portable' }
    }
    if ($listed.ExitCode -ne 0) {
        throw "Could not query the retired Ollama.Ollama.Portable package (exit $($listed.ExitCode))."
    }
    $result = Invoke-DevConfigNativeCommand -FilePath 'winget.exe' -Arguments @(
        'uninstall', '--id', 'Ollama.Ollama.Portable', '--exact', '--source', 'winget',
        '--silent', '--disable-interactivity', '--accept-source-agreements'
    )
    if ($result.ExitCode -ne 0) {
        if ($result.Output -match 'user scope cannot be uninstalled when running with administrator privileges') {
            return [pscustomobject]@{
                Action = 'retained-user-scope-not-selected'
                PackageId = 'Ollama.Ollama.Portable'
                Warning = 'A pre-existing user-scope Ollama.Ollama.Portable package remains because WinGet refuses to uninstall it from an elevated process. The official Ollama.Ollama application is selected and verified.'
            }
        }
        throw "Could not uninstall the retired Ollama.Ollama.Portable package (exit $($result.ExitCode)): $($result.Output)"
    }
    $remaining = Invoke-DevConfigNativeCommand -FilePath 'winget.exe' -Arguments @(
        'list', '--id', 'Ollama.Ollama.Portable', '--exact', '--source', 'winget',
        '--disable-interactivity', '--accept-source-agreements'
    )
    if ($remaining.ExitCode -ne $Script:DevConfigWingetNotFound) {
        throw 'WinGet still lists the retired Ollama.Ollama.Portable package.'
    }
    return [pscustomobject]@{
        Action = 'removed'
        PackageId = 'Ollama.Ollama.Portable'
    }
}

if ($Uninstall) {
    if ($PlanOnly) {
        Add-OllamaAcquisition -Action 'planned-uninstall' -PackageEvidence $null -MigrationEvidence ([ordered]@{
            legacyManagedArchive = $null
            portablePackage = Remove-OllamaPortablePackage -PlanOnly
        })
        Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
        Write-Host 'PLAN_OK: ollama uninstall'
        return
    }

    Assert-AiAdministrator
    $migration = Remove-OllamaLegacyManagedInstallation -Paths $legacyPaths
    $portableCleanup = Remove-OllamaPortablePackage
    if ($portableCleanup.PSObject.Properties['Warning']) {
        [void]$report.result.warnings.Add([string]$portableCleanup.Warning)
    }
    $registeredApplication = Get-OllamaRegisteredApplicationEvidence
    $installedCommand = Get-Command ollama -ErrorAction SilentlyContinue
    if ($installedCommand) {
        [void](Stop-OllamaManagedProcesses -InstallRoot (Split-Path -Parent $installedCommand.Source))
    }
    $uninstallResult = Invoke-DevConfigNativeCommand -FilePath 'winget.exe' -Arguments @(
        'uninstall', '--id', $component.PackageId, '--exact', '--source', 'winget',
        '--silent', '--disable-interactivity', '--accept-source-agreements'
    )
    if ($uninstallResult.Output) { Write-Host $uninstallResult.Output.TrimEnd() }
    $uninstallMethod = 'winget'
    if ($uninstallResult.ExitCode -notin @(0, $Script:DevConfigWingetNotFound)) {
        if ($uninstallResult.Output -match 'user scope cannot be uninstalled when running with administrator privileges' -and
            $registeredApplication) {
            $registeredCommand = ConvertFrom-OllamaUninstallString -UninstallString $registeredApplication.UninstallString
            $registeredArguments = @()
            if ($registeredCommand.Arguments) { $registeredArguments += $registeredCommand.Arguments }
            $registeredArguments += @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
            $exitCode = Invoke-DevConfigProcess `
                -FilePath $registeredCommand.FilePath `
                -Arguments $registeredArguments `
                -TimeoutSeconds 1800
            if ($exitCode -ne 0) {
                throw "Ollama registered uninstaller exited with code $exitCode."
            }
            $uninstallMethod = 'winget-registered-uninstaller'
        } else {
            throw "Could not uninstall $($component.PackageId) (exit $($uninstallResult.ExitCode)): $($uninstallResult.Output)"
        }
    }
    $remaining = Invoke-DevConfigCleanupCommand -FilePath 'winget' -Arguments @(
        'list', '--id', $component.PackageId, '--exact', '--source', 'winget',
        '--disable-interactivity', '--accept-source-agreements'
    ) -SuccessCodes @(0, $Script:DevConfigWingetNotFound)
    if ($remaining.ExitCode -ne $Script:DevConfigWingetNotFound) {
        throw "WinGet still lists $($component.PackageId) after uninstall."
    }
    if ($RemoveModels) {
        Remove-OllamaManagedDirectory -Path $modelRoot
    }
    Add-OllamaAcquisition -Action 'uninstalled' -PackageEvidence $null -MigrationEvidence ([ordered]@{
        legacyManagedArchive = $migration
        portablePackage = $portableCleanup
    })
    $report.acceptance.uninstall = [ordered]@{
        packageAbsent = $true
        method = $uninstallMethod
        registeredApplication = $registeredApplication
        legacyManagedArchive = $migration
        portablePackage = $portableCleanup
        modelsPath = $modelRoot
        modelsPreserved = -not $RemoveModels
    }
    Complete-AiWorkloadReport -Report $report -Ready $true -Path $ReportPath
    Write-Host "OLLAMA_UNINSTALLED: models-preserved=$(-not $RemoveModels)"
    return
}

$manifestEvidence = Get-OllamaWingetManifestEvidence -Architecture $architecture

try {
    $configuredApi = Get-OllamaLocalEndpoint
} catch {
    if (-not $PlanOnly) { throw }
    [void]$report.result.blockers.Add($_.Exception.Message)
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host 'PLAN_UNSUPPORTED: ollama'
    return
}
$report.request.Endpoint = $configuredApi

if ($PlanOnly) {
    $acquisition = Ensure-AiWingetPackage -Id $plan.PackageId -PlanOnly
    Add-OllamaAcquisition -Action $acquisition.Action -PackageEvidence $null -MigrationEvidence ([ordered]@{
        legacyManagedArchive = [ordered]@{
            requiredWhenLegacyMarkerExists = $architecture -eq 'Arm64'
            preservesModels = $true
        }
        portablePackage = Remove-OllamaPortablePackage -PlanOnly
    })
    Add-AiReportPhase -Report $report -Name 'installed-application' -Status 'planned' -Evidence @{
        packageId = $plan.PackageId
        architecture = $architecture
        installerUrl = $manifestEvidence.InstallerUrl
        nativeExecutableRequired = $true
    }
    Add-AiReportPhase -Report $report -Name 'model-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'planned' }) -Evidence @{ model = 'qwen3:0.6b' }
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host 'PLAN_OK: ollama'
    return
}

Assert-AiAdministrator
$migration = Remove-OllamaLegacyManagedInstallation -Paths $legacyPaths
$portableCleanup = Remove-OllamaPortablePackage
if ($portableCleanup.PSObject.Properties['Warning']) {
    [void]$report.result.warnings.Add([string]$portableCleanup.Warning)
}
if ($migration.Migrated) {
    try {
        $unexpectedEndpoint = Invoke-RestMethod -Uri "$configuredApi/api/version" -TimeoutSec 3
        if ($unexpectedEndpoint.version) {
            throw "Endpoint $configuredApi remained active after removing the Dev Config-managed Ollama runtime. Stop the unmanaged instance and rerun."
        }
    } catch {
        if ($_.Exception.Message -match 'remained active') { throw }
    }
}

$acquisition = Ensure-AiWingetPackage -Id $plan.PackageId
Update-DevConfigSessionPath
$ollamaCommand = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollamaCommand) {
    $candidate = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path -LiteralPath $candidate) {
        $ollamaPath = $candidate
    } else {
        throw 'WinGet installed Ollama.Ollama, but ollama.exe could not be resolved.'
    }
} else {
    $ollamaPath = $ollamaCommand.Source
}
$binaryArchitecture = Get-AiPeArchitecture -Path $ollamaPath
if ($binaryArchitecture -ne $architecture) {
    throw "Ollama.Ollama installed '$binaryArchitecture' ollama.exe on $architecture Windows; refusing emulated or incompatible runtime."
}
Add-OllamaAcquisition -Action $acquisition.Action -PackageEvidence $acquisition.Evidence -MigrationEvidence ([ordered]@{
    legacyManagedArchive = $migration
    portablePackage = $portableCleanup
})
$registeredApplication = Get-OllamaRegisteredApplicationEvidence
if (-not $registeredApplication) {
    throw 'Ollama.Ollama is installed, but its registered application/uninstaller state was not found.'
}

$oldHost = $env:OLLAMA_HOST
$serverProcess = $null
$serverStdout = Join-Path $env:LOCALAPPDATA 'DevConfig\ollama\server.stdout.log'
$serverStderr = Join-Path $env:LOCALAPPDATA 'DevConfig\ollama\server.stderr.log'
try {
    $apiBase = $configuredApi
    try {
        $version = Invoke-RestMethod -Uri "$apiBase/api/version" -TimeoutSec 3
        $serverProcess = Get-CimInstance Win32_Process -Filter "Name = 'ollama.exe'" -ErrorAction SilentlyContinue |
            Select-Object -First 1
    } catch {
        New-Item -ItemType Directory -Path (Split-Path -Parent $serverStdout) -Force | Out-Null
        Remove-Item $serverStdout, $serverStderr -Force -ErrorAction SilentlyContinue
        $env:OLLAMA_HOST = $apiBase
        $serverProcess = Start-Process `
            -FilePath $ollamaPath `
            -ArgumentList 'serve' `
            -WindowStyle Hidden `
            -RedirectStandardOutput $serverStdout `
            -RedirectStandardError $serverStderr `
            -PassThru
        # The API waits for GPU discovery, which can take over 40 seconds on CPU-only machines.
        Write-Host 'Waiting for the Ollama server to start. This can take up to 2 minutes.'
        try {
            $version = Wait-JsonEndpoint -Uri ([uri]"$apiBase/api/version") -TimeoutSeconds 120 -Process $serverProcess
        } catch {
            $serverLog = (Get-Content -LiteralPath $serverStderr -Tail 10 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
            throw "$($_.Exception.Message) Server log ($serverStderr):$([Environment]::NewLine)$serverLog"
        }
    }
    if ([string]$version.version -ne [string]$manifestEvidence.Version) {
        throw "Ollama API reported version '$($version.version)', expected WinGet installer version '$($manifestEvidence.Version)'."
    }

    $env:OLLAMA_HOST = $apiBase
    Invoke-CheckedCommand -FilePath $ollamaPath -ArgumentList @('--version') -DisplayName 'Ollama CLI verification'
    $report.acceptance.server = [ordered]@{
        endpoint = $apiBase
        processId = Get-AiProcessId -ProcessObject $serverProcess
        executable = $ollamaPath
        executableArchitecture = $binaryArchitecture
        version = $version.version
        packageId = $plan.PackageId
        installerUrl = $manifestEvidence.InstallerUrl
        installerSha256 = $manifestEvidence.InstallerSha256
        registeredPackage = $acquisition.Evidence
        registeredApplication = $registeredApplication
        stdoutLog = $serverStdout
        stderrLog = $serverStderr
    }

    $modelPlan = Get-OllamaModelSmokePlan
    $inferenceEvidence = $null
    if ($SkipModelSmoke) {
        Write-Warning 'OLLAMA_MODEL_SMOKE_SKIPPED: CLI and API are ready, but no model inference was performed.'
    } else {
        Write-Host "Pulling official Ollama library model $($modelPlan.Model) (approximately $($modelPlan.ApproximateDownloadMb) MB, $($modelPlan.License))."
        Invoke-CheckedCommand -FilePath $ollamaPath -ArgumentList @('pull', $modelPlan.Model) -DisplayName 'Ollama model pull'
        $manifestPath = Get-OllamaModelManifestPath -ModelRoot $modelRoot -Model $modelPlan.Model
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            throw "Ollama pulled $($modelPlan.Model), but its local manifest was not found at '$manifestPath'."
        }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $modelLayer = @($manifest.layers | Where-Object { $_.mediaType -match 'model' } | Select-Object -First 1)
        $expectedDigest = "sha256:$($modelPlan.ModelBlobSha256)"
        if ($modelLayer.Count -ne 1 -or $modelLayer[0].digest -ne $expectedDigest) {
            throw "Ollama library tag $($modelPlan.Model) no longer references pinned model digest $expectedDigest."
        }
        $blobPath = Join-Path $modelRoot "blobs\sha256-$($modelPlan.ModelBlobSha256)"
        if (-not (Test-Path -LiteralPath $blobPath)) {
            throw "Ollama pulled $($modelPlan.Model), but its pinned model blob was not found at '$blobPath'."
        }
        $blobHash = (Get-FileHash -LiteralPath $blobPath -Algorithm SHA256).Hash
        if ($blobHash -ne $modelPlan.ModelBlobSha256) {
            throw "Ollama model blob checksum mismatch. Expected $($modelPlan.ModelBlobSha256); got $blobHash."
        }

        $request = New-OllamaGenerateRequest -Model $modelPlan.Model -Marker $modelPlan.Marker
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri "$apiBase/api/generate" `
            -ContentType 'application/json' `
            -Body ($request | ConvertTo-Json -Depth 8) `
            -TimeoutSec 300
        $result = $response.response | ConvertFrom-Json
        if ($result.marker -ne $modelPlan.Marker) {
            throw "Ollama model inference did not produce marker '$($modelPlan.Marker)'."
        }
        $processor = (& $ollamaPath ps 2>&1 | Out-String).Trim()
        $running = Invoke-RestMethod -Uri "$apiBase/api/ps" -TimeoutSec 30
        $loaded = @($running.models | Where-Object { $_.name -eq $modelPlan.Model } | Select-Object -First 1)
        $gpuFraction = if ($loaded.Count -eq 1 -and [double]$loaded[0].size -gt 0) {
            [math]::Round(([double]$loaded[0].size_vram / [double]$loaded[0].size), 4)
        } else { 0 }
        $serverEvidence = if (Test-Path -LiteralPath $serverStderr) {
            (Get-Content -LiteralPath $serverStderr -Tail 200 | Select-String 'inference compute|gpu memory|library=' | Out-String).Trim()
        } else { '' }
        $report.acceptance.inference = [ordered]@{
            model = $modelPlan.Model
            digest = $expectedDigest
            marker = $modelPlan.Marker
            sizeBytes = if ($loaded.Count) { $loaded[0].size } else { $null }
            sizeVramBytes = if ($loaded.Count) { $loaded[0].size_vram } else { $null }
            gpuFraction = $gpuFraction
            processTable = $processor
            backendLogEvidence = $serverEvidence
        }
        $inferenceEvidence = $report.acceptance.inference
        $report.result.fallbackUsed = $gpuFraction -eq 0
        Write-Host $processor
        Write-Host "OLLAMA_READY: version=$($version.version), architecture=$architecture, model=$($modelPlan.Model), verified-blob=$($modelPlan.ModelBlobSha256)."
    }
} finally {
    $env:OLLAMA_HOST = $oldHost
}

Add-AiReportPhase -Report $report -Name 'ollama-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'ready' }) -Evidence $inferenceEvidence
Complete-AiWorkloadReport -Report $report -Ready (-not $SkipModelSmoke) -Path $ReportPath
Write-Host 'INSTALL_OK: ollama'

# SIG # Begin signature block
# MIInQQYJKoZIhvcNAQcCoIInMjCCJy4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBqdwzoJif0FuMT
# eFhd+4wZogxqBWaDqjzFtzP+v/rFn6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghndMIIZ2QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIMbhmtXoGPgMZHWjb1UOQAjJw4oNLSJ/Lq5hS/NEWEUbMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAVvcNDXo8IfVhjolc
# wpR9OeVt/7G4JCRwoPdanjtjBasPiHXOlUXqMfiPKsKYMQrhCmg1qegCLUa38zce
# Vup2cNVB+90KIs6FzLHW7X97fMSH77CE8e8Kh109M6nSZStHbr0efTHLqL3tt/Oh
# PpDhy49VxavJfKpJ5HVCfT/i7wMe3RGC7m1Y4yOkdLAUSLJPfpyvwfj6BC3GJSZY
# 55rq43ap5w7LSVjXN2ivN8wQQHwiCS2dz3+exgTUDsAjz0HuQVaN74ZYCBMsKwhv
# /BCIU0p1zKWxRbsoWAXVYFfcS00wkPXPZcQ4uSbisf/qvXUaYqGcrjViS/2JPViu
# cjcN2aGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4Yw
# gheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCQ2/5kzIFc33dz
# vpENj/tK9HPKRFfr7eAQX6e2p/EywwIGargHQp/0GBMyMDI2MTAwOTIxNDU1OS4w
# NDlaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1MjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIF
# EKADAgECAhMzAAACF3H7LqWvAR3qAAEAAAIXMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgyM1oXDTI2MTEx
# MzE4NDgyM1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjUyMUEtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAwM82sEw+39vYR7iGCIFDnYNhRM+BzF2AYiq5dUpZpJFP
# RjCcipQ6RUbI+RAYNRApExx5ygrXbaWtuwvqsqAVSWbU/W6fecujjILkPqn9pngt
# WRkfQgbYgvaXALl6PY2yOH9f72MD+6AyxQenSpAMdUzY/Qk/jtjsHdFXVBe+tshl
# IkSJ3GZw8VVKqTg3GZElztwbJWNtrhBEvhf6anxMegQMJP7tO8/BJ7ITs4/AV3D2
# bv8eHk81Y+fOmQ8mQ61WLq2wItvlzIT5bzelK9LvEycf5x1lXxAwEw5a7dpS+CKT
# anhtv+Q2mwebAybjf9io4k48stTaq1rtcrOiDwddqVm1S9e8h1TszXFzjLLvE9Em
# jnNfIewsY+RChUaHnY4FFwwJEnEv/JS76oHT0oGdy7+J60fGOl7A1UoUyAkhpb2B
# ja+SwSIiHbQ4FDyJiLlZ6drZZ84MoJ852JSxM0hBjGO6FZlPO8iuNyk680Di8Vnb
# SNpIdJN+DhlepeTUMBDHqCmd0mVWRWZPm1pvgty93asNt/Ng6o4m2dnooWOdM3yK
# sJaWjyHqic9gfTrZBM+PCXqeTaO1oEiaQ+h4w0nHVdV+XSvI2m1yN4iibqjm5HPa
# AO3OJ+OmNLftNVmr4Z6U2T6pIcLBysoKcDUvCqycXj4C/+n1KFBpDGdDMw9gmu8C
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBRQrN9jlwNOoeE5ZQqnF5x8S1bJQzAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEARmgFdhB7xIAIHEEg5I/5S+gx67aR6RiW8ZAw
# tE3mz8o0dyn+pIP+lidNR1IKQQ0r+RjYgI9cZ6mbvAyvh3e2q/BV8rjHE3ud9PyY
# yq32euFgdZ3vX4b5QXePWlpBAYrdziR27rHz6WwpH5dZsSypbXDBbQkWkNl6g82y
# Ty3AbBbKDXBdzxZsEauaOplatK7Er4dhglKBex8JQ2dMSkSZweCNDXqd9r/9W2Vd
# RZsDJKP/Xc4UyQlVsboBotKtYESXFkjwR1HVsH+Q0C69/N5CP/Tq3YgI1ub4b9+3
# MJFKWhJXCcJGFZkcLwUmYwoFg1XLo7DLJdGjrIH1jsI2NFXJFQHef6AdRe1ERvYQ
# eqtyrBvxIvR+P/83FNYyzx04inUT9TF2AwTOuqCC6Z67oNwR4pEEJyAIEREvkdhj
# jfWcgsk/nGTlfahvNY/SOHrNRKo49KDlccNzRCJQyQ+D59r7/qebNSyQPTfwI9++
# jEY0Q/UWKVNLhio55GYBseJ99s7NzkdxOr9Uftp597HEovbA69qGlZ3OpUE3H1RB
# GDVp/FvM2uXTum8LrMkPXx5Ap/kbPASsC9ju9oMCe2IEXO2SeD1aD3IqvAOdHFKH
# g1vpbPUQSWb6g2xfBV30wFcqaPYgzcbxPWPyZqK+S8l7zw64aO5hmJ7eQwoMfTu0
# Vay6r48wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
# DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAx
# MDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA
# 5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/
# XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1
# hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7
# M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3K
# Ni1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy
# 1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF80
# 3RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQc
# NIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahha
# YQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkL
# iWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV
# 2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIG
# CSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUp
# zxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBT
# MFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYI
# KwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGG
# MA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186a
# GMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3Br
# aS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsG
# AQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcN
# AQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1
# OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYA
# A7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbz
# aN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6L
# GYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA0j3m
# Sj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0
# SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxko
# JLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFm
# PWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC482
# 2rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7
# vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDVjCC
# Aj4CAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1MjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUAabKAFaKt2haUdqkHfFYzAzfgSMuggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO5zp8kwIhgPMjAyNjEw
# MDkxNzUwMDFaGA8yMDI2MTAxMDE3NTAwMVowdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7nOnyQIBADAHAgEAAgIF5TAHAgEAAgIT5DAKAgUA7nT5SQIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQA7pw9ZttIR7wWJYYMxAR6AnGVVVhEstNkQd9Th
# 6MftmGzYl41cwp2kV9UdikJSBb+uB20MFyvobtobAwpGuw6yIjorZpnR+wTXvzFR
# G+4U3NAiAxdIoY7RjDYJ0XIJAzOxYE8cBbaeMn1Yq3JKiJkWT8lJl/qkTtx/ytir
# sC9gf56NybUIoeiPQnPgPvnZNVY3zxA1YpOfXuvzcBZ0ogGTWzo818tZfnTLmPOp
# o1HeiKbV7vSWOKCf3ycpcIx0ym6nTYc4i/KiqcmfnME7kfUeGZoy6jQQUpCBWhv4
# 2ql7P86d4vGP7nh6ImdK0Ya4POsJcEGq0mpcD4Q1YV0FwA56MYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIXcfsupa8BHeoA
# AQAAAhcwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgX3Qx/UFiTMjYFnMAsPUlG2hPCsCWLnpbMgT2
# COS1ArYwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCDQ8lBgPl23yZ0SzUSt
# 5phOIegHPywrkNwevxe2k+RaWzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACF3H7LqWvAR3qAAEAAAIXMCIEIGimmxmuSXKXzzoqo7DD
# SU7Cbko0MVNcKniiA4PT/LvMMA0GCSqGSIb3DQEBCwUABIICAHo3Rnjhv4p49+mX
# o104PzhqVkdz4VZZZr6L6hnDQTczDQ1uVQPB7B6DyjTJZNGYeTsvEr+IkzAkS1cJ
# NUGJY/EW/wD8zqZIuWWvzylI3bY0u40TDYbNMobkiREz93ymbC9cLo5H8UVKWXRI
# nbbS8HiPirzR+CirrqojSyBb5mKXAnjTlBCK+ZRVj+z8gnA6EzPceo06jqCmu0Om
# pwYpX1848e89QStT6Zhd4EDdTznVp2KSnR+AICH4epH9eHAdVlomjO4lsWQWmTrJ
# aepI/1fHknLe6iiqf9HND339s7xkh1OxpnxcDySMgV71Wtv3VVCJoBWrfNw3kEYF
# Cs23Xb2Y9ETqIynHH4BVyJ5cgcWlHPt7xGD35al0MINSFjPyx23Yrb55JSosrbGi
# CuBo+xSOXH3/E1l6LMCcRoQJ/Ze3Qg1X5nwZA0XpFh+KFME4JMF52P+TmiYzAt5M
# HPcdmp0kN99l4xDGY4HRd+2VhW3ioTsRkJdBKBQjcaCeMpz5/92CEGXur1L0AXy/
# ITnsd04D9CgX8bI8RGmhalAe4qYzRIKbaeK6MlAPktgQzceSkZZffTexgOnXE+2g
# ZmbM6uAtyrWrz9RmOlCau4e7oZpkzjvHPEhz0D56mvzd9TgtjKM0FdNvNYe7a/YK
# b8aa0AMpG7IAN3f4HggAOjwhiwLk
# SIG # End signature block
