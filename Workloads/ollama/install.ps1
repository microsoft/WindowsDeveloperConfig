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
        $version = Wait-JsonEndpoint -Uri ([uri]"$apiBase/api/version") -TimeoutSeconds 30
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
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCoEdija8ar6vG5
# Xemln/LD4K7uYT/FLoV89P3CEHeYT6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEILAtkfpQOSSzIo47xTSqx1ZkihnjP02345qD+7eCJvJwMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAFRE5BpbH9Qx49uyq
# SqOmSHXdn7n+3jwbvex2W8ajcHZFTV44uHJCVClzOkd0ZjpBoZhX+F0H7vodEjVX
# AQLiBgZ30xEWWNpRBnqjyR2MQUqEWT3qdwAFu+l3PtCc/r/4AUac9LNUsVUo3EcF
# JgDjFXEW+iI6E8ibDapYQVwfZPgfNjYrpmbL4kMitgZM1/3SnmLyfSg67tdKfoxH
# HtnE7gFvMiP9mEXCSkhvFSSZS18QBzkme9yoNXHsh2NLO4Vlpy7zC2OJJtxDC3fh
# 1F+ySOLckDxrkhko7tVNYn7/bc78jTIk4ftsj+CW7yxFphKuYW8kw3Ox5a7bfY90
# 878nkqGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3Aw
# ghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCuvarwQCoxKJsp
# nisV1nbr2Or+gMZOShIef6Cig91aAgIGaqpMus2hGBMyMDI2MTAwOTAwMTc0MC45
# NjdaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzcwMy0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgIT
# MwAAAh86cGnkojAulQABAAACHzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTFaFw0yNzA1MTcxOTM5NTFa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046MzcwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDL
# O8XFOcfGqAqgiz0+AmQmFl3dZ0aTG4UFJkqqNdMHy28DaheCBs6ONufukye5x42C
# WkzgRIy9kE2VWwEntZ8ZkgyrykC0bIqsID7+6FxguseTXf1Vwvm1D8104VmetoBJ
# lJ4uGbuyJZUvXDx55nVh50ygLTzZ24WkQsnPpvRZv2kPc39f3bhLyHVtnHsa/W/8
# 6Vrftd+AfFveA+qN/EY+XGj5c/DPMXCYECb0arYb92dDJWtwzpyBrp4gfHlgY1UE
# pc4l4AGELrf2J4wrxTzTW+SM8XhV1dOOPrYjD080IbZqL8B+IF0RCdn269YXrGK6
# QIHipznKZcCS8jN30YAHnTJVN5Zzs6t/2YsqBGDquvDad7934FFTwzvUcO3VoIyd
# 93XWwvP8/SCFVJh21W8oGQTptGHyly+Fl4henVMVZF1v6osOtirX8GFTiEhnf8nR
# dOg7yZYAJ0xy9CtDfbXaTn/cf3Lq3N/GCYKFjC+5mUCE+AJhmxMuMdvSUGmKiAFd
# iPAjUTqsWWBBZJm0eCwgeGJFmmQA+V7/98BKcE+gUL7O9eWRDQwKeAcvo6rxNv2Y
# 4jKrHA6Z/wi3a/fKUhLCNZES8qGdrpDAm7qh+6FjYxytAbkiKM6uTNy/ULPlwtlY
# ZoAJDDQP7eYCywwVbNTbHXRBSS+NccC0sSB4W7U67wIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFNk72sGDlH0r5DwvfGR5XwJI8B7bMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQBlbu3IoynnPz0K1iPbeNnsej2b15l5sdl2FAFBBGT9lRdc2gNV8LAIusPY
# HHhUvRDcsx4lbMNhVKPGu4TDLaqNt/CI+SFtGuqdRLpVP1XE9cCLyKrKPpcJFJCq
# PpV+efoAtYBmIUQcxxwT7WIQ7gag8+rkKvrMkCoRqKS0mKv8J1sKfi85+G2uhZ/1
# RteSVdYZOZOj+Sb4wzonTCTj7EtgMN/BX35W5dTzd7wJdGepYkVi871dSrC2Tr1Z
# FzAR7S44drCWZpJ6phJabVNOsNxFJKgSykugOGWzQ318Rr3MTPg2s3Bns+pUPVgM
# ijd4bUOH2BlEsLMMwOcolTTZqg1HYrdY1jxpUAI9ipjBQRINL/O705Z+/f2LjNmJ
# QooCVJVX24adpZ519SsfazGoqXGt91bmqKo0fI09Il4sUHh4ih6rpiQDBlyL7vmv
# CejwVxYevY4qVwTZ/o3gvl+R0lFxYS9feIM4NeG0+WsDZ7jLci5MFeuNwosQY3z2
# 6Xg1oj0U9u+ncR9uTU+xBmJ8BtlCdhQ13RNMX5P+krRYPB3XCp9Jm6XaO1995q32
# AIZm1mzBGI6yHlviXaEC5TzGiO1LXuPtXZU2X93oQJbMoe3v8+5CPKrQalGWyYuh
# 2a3V1pwbj+W0FEmEFPpu8TI+qYO1IIQWUSRvFjXth5Ob02hMMjCCB3EwggVZoAMC
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
# U1MgRVNOOjM3MDMtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQBLIMg1P7sNuCXpmbH2IXT2tXeE
# EKCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7nJxRTAiGA8yMDI2MTAwODE5NDUwOVoYDzIwMjYxMDA5MTk0NTA5
# WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDucnFFAgEAMAoCAQACAgcCAgH/MAcC
# AQACAhNxMAoCBQDuc8LFAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkK
# AwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBABBr
# X2Y3JFzmJ/GEwMNzf3siBw1wLvfS0uvCFfxcNATq9EFUmzt63KEKLKaLcftkV0oq
# CDciuKFYiXsmz8BLolBfqbdCxf4R8Q/6j3ZjC37F9wkj5v8+mFy0unD+4hdB2GS8
# SgFZiSBUClSz/QlDhv+dHS850/6nesqFRa+X1gk8SCM7Bl67jCLtZCW0LnGPbG2Y
# GlrbkxAi32GGm/ZNv/p7Wk9XJ60u78qx6yDbnOHcRXJDn2Ansv3CWb0FMyagUT7a
# 1hbI1lBT8i9CqRvizKb/MgnpDzVDJN4SmToDyjnLuQ+j3gxzHw4YP2vqZcGJFEed
# HeGfFZPSwkISJWAervsxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFt
# cCBQQ0EgMjAxMAITMwAAAh86cGnkojAulQABAAACHzANBglghkgBZQMEAgEFAKCC
# AUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCDr
# 5hCY2/uSRKHHYvPRXsAzns/53nNYeajSolWJPEUMgjCB+gYLKoZIhvcNAQkQAi8x
# geowgecwgeQwgb0EILAkCt9WkCsMtURkFu6TY0P3UXdRnCiYuPZhe3ykLfwUMIGY
# MIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIfOnBp5KIw
# LpUAAQAAAh8wIgQgkvx+J25WKnMiC/uUxSYaLzGpX09OSp9LXX704h/vORkwDQYJ
# KoZIhvcNAQELBQAEggIAdwVhejPuVkO06jV9thn6FnkeT3ytqDZqmCquRrTuBTfN
# DXlP75DrN2ztqGQvcEwERME2gHQ4Scg5FsSxQxL0Hlp3ny+fWbmGasLcodeARHTK
# QW2l0fZe/NKB8MtueAmOTMoGIwjoUXAuLVvOY+UFVkjnT5/e3CkXdEiNbXVVxGt3
# M68JLXpPPNO7+4dFpWKBGp5NNUoK/KPjt5bftREoFYQGt9IlHFZMHp69C91kQWP0
# LJYXjxD72OJ2kduqUfO2TcI0aw4LY5QyKlZOZNhuWtUU0mvJ72iGPmEyT5mfMx18
# rBiLBWoUlM4CLjfM7ygoTOuQI385VTEk3RHRL+5/o5gd/v2EpVgdlbds0snPeSqm
# o7dO9VdR17YDLypbcPgjdB1BiPXYu2ffyYhRkjTlZxnFQhQyNDooq2vzCGO9VNjP
# Y0eeivSHRCoZbI5DW4hZ5nCsvOo+5ONP5uREqUlhkJTqmgRVg96bW29lqZz1cGO4
# Ur9os6FSd03yR+uOdFa862MWKRnn3jNEJpEMZ6+gMqtTGlMJxq8fGLB2WojBTxSw
# URGBxRLRf9c5BqddKJZuvlRMkKLuoLAFlYHGMZO+82tWjN+1LNj8Bw2+nwB8I2SQ
# CYscqx+svX1UGelD7JVCe+YGnSzjd2Z9Sd2zGL5Z2pr7x86uJ4+2WKijC/OCecY=
# SIG # End signature block
