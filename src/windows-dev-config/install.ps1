<#
.SYNOPSIS
  Install the Windows Developer Config with one UAC prompt and reboot-safe resume.

.DESCRIPTION
  Slipstream stages this signed payload under ProgramData, elevates once, repairs
  WinGet if needed, enables WSL, resumes after reboot through an elevated
  interactive-user scheduled task, applies the declared packages and settings,
  and independently verifies the result.

  Run -Action Validate before a signing pass to perform non-destructive payload
  validation. -AllowUnsigned is only for source-tree development.
#>

[CmdletBinding()]
param(
    [ValidateSet('Start', 'Resume', 'Status', 'Validate', 'Cleanup')]
    [string] $Action = 'Start',

    [string] $RunId,
    [string] $PayloadRoot,
    [string] $OriginalUserSid,
    [string] $OriginalUserName,

    [switch] $AllowUnsigned,
    [switch] $NoRestart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$bootstrapIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$bootstrapPrincipal = [Security.Principal.WindowsPrincipal]::new($bootstrapIdentity)
if ($bootstrapPrincipal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    $windowsPowerShellModules = [IO.Path]::Combine(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows),
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'Modules'
    )
    $env:PSModulePath = @(
        [IO.Path]::Combine($PSHOME, 'Modules'),
        $windowsPowerShellModules
    ) -join ';'
}

$sourceRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($sourceRoot)) {
    throw @'
The streamed one-line loader is not published yet. For the Slipstream preview,
download the signed pipeline artifact and run windows-dev-config\install.ps1.
'@
}

function Invoke-SlipstreamWindowsPowerShellRelaunch {
    $invocationArguments = @(
        "-Action '$($Action.Replace("'", "''"))'"
    )
    foreach ($entry in @(
        @{ Name = 'RunId'; Value = $RunId },
        @{ Name = 'PayloadRoot'; Value = $PayloadRoot },
        @{ Name = 'OriginalUserSid'; Value = $OriginalUserSid },
        @{ Name = 'OriginalUserName'; Value = $OriginalUserName }
    )) {
        if (-not [string]::IsNullOrWhiteSpace($entry.Value)) {
            $escapedValue = $entry.Value.Replace("'", "''")
            $invocationArguments += "-$($entry.Name) '$escapedValue'"
        }
    }
    if ($AllowUnsigned) {
        $invocationArguments += '-AllowUnsigned'
    }
    if ($NoRestart) {
        $invocationArguments += '-NoRestart'
    }

    $escapedScript = $PSCommandPath.Replace("'", "''")
    $command = @"
`$result = & '$escapedScript' $($invocationArguments -join ' ')
if (`$result -is [int]) { exit `$result }
exit 0
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $executionPolicy = if ($AllowUnsigned) { 'Bypass' } else { 'AllSigned' }
    $systemDirectory = if ([Environment]::Is64BitOperatingSystem -and
        -not [Environment]::Is64BitProcess) {
        'Sysnative'
    }
    else {
        'System32'
    }
    $nativePowerShell = [IO.Path]::Combine(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows),
        $systemDirectory,
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe'
    )
    $process = Start-Process `
        -FilePath $nativePowerShell `
        -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy', $executionPolicy,
            '-EncodedCommand', $encoded
        ) `
        -Wait `
        -PassThru
    return $process.ExitCode
}

$requiresNativeRuntime = $Action -in @('Start', 'Resume', 'Cleanup')
$requiresWindowsPowerShell = $requiresNativeRuntime -and (
    $PSVersionTable.PSEdition -ne 'Desktop' -or
    ([Environment]::Is64BitOperatingSystem -and
        -not [Environment]::Is64BitProcess)
)
if ($requiresWindowsPowerShell) {
    $nativeExitCode = Invoke-SlipstreamWindowsPowerShellRelaunch
    if ($nativeExitCode -eq 3010) {
        exit 3010
    }
    if ($nativeExitCode -ne 0) {
        throw "The native Windows PowerShell Slipstream process failed with exit code $nativeExitCode."
    }
    return
}

$script:SlipstreamScriptBodyHashes = @{
    'bootstrap\common.ps1' = '12D0B0B660B588FF8BFB730D4B104EBD1E313F86D3C9BBC0C79F032C15D3AF84'
    'bootstrap\controller.ps1' = 'EC64CAFFADB2D6CD30F265A5687A028BF9EEF24B066D42CB194D1B830C8A4779'
    'bootstrap\platform.ps1' = '1FAEEDF7C0CDCE7E1BE751E67A8A9B978EEB1AD4420C0272639828361895FDF0'
    'bootstrap\resume.ps1' = 'A541E3A2C9824FE33AA24EFE6207FD4A25E0A45CF5C1AB249BF0AF54ACC47F34'
    'bootstrap\configure.ps1' = '5515B28F39DDFB9DE895D6722B2F7E8056CCFA18908F7E486BF0CA9EE8007315'
    'bootstrap\user.ps1' = '77593E5F4501B3B80F30082FA1B1A62927253489836766642257BF4BF365F4DA'
    'bootstrap\verify.ps1' = 'B9BD1912CAAE53A79A8D686E818071FF3C2C62FD3D4479FBD25F2B55BA7E7066'
}
$script:SlipstreamInitialConfigHashes = @{
    'config\packages.json' = '75152DFEB6DD08A3718D6CA9486A7D660051E06103B942A029A13F6112DA2BE3'
    'config\registry.json' = '84E5947C1FE4BB0E28411290628FB388444DC15E365C9E2BD04FF41A7E3F15D8'
}

function Get-SlipstreamInitialTextHash {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $StripSignatureBlock
    )

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $lines = $text -split "`r`n|`n"
    if ($StripSignatureBlock) {
        for ($index = 0; $index -lt $lines.Length; $index++) {
            if ($lines[$index].Trim() -eq '# SIG # Begin signature block') {
                $lines = if ($index -eq 0) { @() } else { $lines[0..($index - 1)] }
                break
            }
        }
    }

    $normalized = [Text.Encoding]::UTF8.GetBytes([string]::Join("`n", $lines))
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString(
            $sha256.ComputeHash($normalized)
        ).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Test-SlipstreamInitialPayload {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [switch] $AllowUnsignedPayload
    )

    $requiredScripts = @(
        'install.ps1',
        'bootstrap\common.ps1',
        'bootstrap\controller.ps1',
        'bootstrap\platform.ps1',
        'bootstrap\resume.ps1',
        'bootstrap\configure.ps1',
        'bootstrap\user.ps1',
        'bootstrap\verify.ps1'
    )
    foreach ($relativePath in $requiredScripts) {
        $path = Join-Path $Root $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Slipstream payload is incomplete; missing $relativePath."
        }

        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $path,
            [ref]$null,
            [ref]$parseErrors
        )
        if ($parseErrors) {
            throw "PowerShell parse failure in $relativePath`: $($parseErrors[0].Message)"
        }

        if (-not $AllowUnsignedPayload) {
            $signature = Get-AuthenticodeSignature -LiteralPath $path
            if ($signature.Status -ne 'Valid') {
                throw "Invalid Authenticode signature on $relativePath`: $($signature.Status)"
            }
            if ($signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
                throw "Unexpected signer on $relativePath`: $($signature.SignerCertificate.Subject)"
            }
        }

        if ($relativePath -ne 'install.ps1') {
            $actualHash = Get-SlipstreamInitialTextHash `
                -Path $path `
                -StripSignatureBlock
            $expectedHash = $script:SlipstreamScriptBodyHashes[$relativePath]
            if ($actualHash -ne $expectedHash) {
                throw "Body hash mismatch for $relativePath. Expected $expectedHash, got $actualHash."
            }
        }
    }

    foreach ($relativePath in $script:SlipstreamInitialConfigHashes.Keys) {
        $path = Join-Path $Root $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Slipstream payload is incomplete; missing $relativePath."
        }
        $actualHash = Get-SlipstreamInitialTextHash -Path $path
        $expectedHash = $script:SlipstreamInitialConfigHashes[$relativePath]
        if ($actualHash -ne $expectedHash) {
            throw "Hash mismatch for $relativePath. Expected $expectedHash, got $actualHash."
        }
    }
}

Test-SlipstreamInitialPayload -Root $sourceRoot -AllowUnsignedPayload:$AllowUnsigned
. (Join-Path $sourceRoot 'bootstrap\common.ps1')
. (Join-Path $sourceRoot 'bootstrap\resume.ps1')

function Set-SlipstreamDirectoryAcl {
    param([Parameter(Mandatory)] [string] $Path)

    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($rule in @(
        [System.Security.AccessControl.FileSystemAccessRule]::new(
            [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
            'FullControl',
            $inheritance,
            $propagation,
            'Allow'
        ),
        [System.Security.AccessControl.FileSystemAccessRule]::new(
            [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'),
            'FullControl',
            $inheritance,
            $propagation,
            'Allow'
        ),
        [System.Security.AccessControl.FileSystemAccessRule]::new(
            [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
            'ReadAndExecute',
            $inheritance,
            $propagation,
            'Allow'
        )
    )) {
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Copy-SlipstreamPayload {
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination
    )

    if (-not (Test-Path -LiteralPath $script:SlipstreamProgramDataRoot)) {
        New-Item `
            -ItemType Directory `
            -Path $script:SlipstreamProgramDataRoot `
            -Force | Out-Null
    }
    Set-SlipstreamDirectoryAcl -Path $script:SlipstreamProgramDataRoot

    if (Test-Path -LiteralPath $Destination) {
        throw "Refusing to overwrite an existing pinned payload: $Destination"
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Set-SlipstreamDirectoryAcl -Path $Destination

    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        Copy-Item `
            -LiteralPath $item.FullName `
            -Destination $Destination `
            -Recurse `
            -Force
    }
}

function Invoke-SlipstreamElevation {
    param(
        [Parameter(Mandatory)] [string] $Sid,
        [Parameter(Mandatory)] [string] $UserName
    )

    if (-not $PSCommandPath) {
        throw 'Cannot self-elevate a streamed script. Run the signed install.ps1 file.'
    }

    $escapedScript = $PSCommandPath.Replace("'", "''")
    $escapedSid = $Sid.Replace("'", "''")
    $escapedName = $UserName.Replace("'", "''")
    $command = @"
`$result = & '$escapedScript' -Action Start -OriginalUserSid '$escapedSid' -OriginalUserName '$escapedName'$(if ($AllowUnsigned) { ' -AllowUnsigned' })$(if ($NoRestart) { ' -NoRestart' })
if (`$result -is [int]) { exit `$result }
exit 0
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $executionPolicy = if ($AllowUnsigned) { 'Bypass' } else { 'AllSigned' }
    $systemDirectory = if ([Environment]::Is64BitOperatingSystem -and
        -not [Environment]::Is64BitProcess) {
        'Sysnative'
    }
    else {
        'System32'
    }
    $process = Start-Process `
        -FilePath (Join-Path $env:SystemRoot "$systemDirectory\WindowsPowerShell\v1.0\powershell.exe") `
        -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', $executionPolicy, '-EncodedCommand', $encoded) `
        -Verb RunAs `
        -Wait `
        -PassThru
    return $process.ExitCode
}

function Get-SlipstreamRecoverableRun {
    param([Parameter(Mandatory)] [string] $UserSid)

    $runsRoot = Join-Path $script:SlipstreamProgramDataRoot 'runs'
    if (-not (Test-Path -LiteralPath $runsRoot)) {
        return $null
    }

    $states = foreach ($stateFile in Get-ChildItem -LiteralPath $runsRoot -Filter state.json -Recurse -File) {
        try {
            $state = Get-Content -LiteralPath $stateFile.FullName -Raw -Encoding UTF8 |
                ConvertFrom-Json
            if ($state.originalUserSid -eq $UserSid -and
                $state.status -ne 'Complete' -and
                $state.payloadRoot -and
                (Test-Path -LiteralPath $state.payloadRoot -PathType Container)) {
                $state
            }
        }
        catch {
            Write-Warning "Ignoring unreadable Slipstream state: $($stateFile.FullName)"
        }
    }

    return $states |
        Sort-Object updatedAtUtc -Descending |
        Select-Object -First 1
}

function Show-SlipstreamStatus {
    $runsRoot = Join-Path $script:SlipstreamProgramDataRoot 'runs'
    if (-not (Test-Path -LiteralPath $runsRoot)) {
        Write-Host 'No Windows Developer Config runs were found.'
        return
    }

    $states = foreach ($stateFile in Get-ChildItem -LiteralPath $runsRoot -Filter state.json -Recurse -File) {
        try {
            Get-Content -LiteralPath $stateFile.FullName -Raw -Encoding UTF8 |
                ConvertFrom-Json
        }
        catch {
            Write-Warning "Could not read $($stateFile.FullName): $($_.Exception.Message)"
        }
    }
    $states |
        Sort-Object updatedAtUtc -Descending |
        Select-Object runId, status, phase, rebootCount, updatedAtUtc, lastError |
        Format-List
}

if ($Action -eq 'Status') {
    Show-SlipstreamStatus
    return
}

if ($Action -eq 'Validate') {
    $summary = Test-SlipstreamPayload `
        -PayloadRoot $sourceRoot `
        -AllowUnsigned:$AllowUnsigned
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $validationState = [pscustomobject]@{
        runId = [guid]::Empty.ToString()
        payloadRoot = $sourceRoot
        originalUserSid = $identity.User.Value
    }
    $task = New-SlipstreamResumeTaskDefinition `
        -State $validationState `
        -AllowUnsigned:$AllowUnsigned `
        -NoRestart:$NoRestart
    $userTask = New-SlipstreamUserTaskDefinition `
        -State $validationState `
        -AllowUnsigned:$AllowUnsigned
    return [pscustomobject]@{
        Status = 'Valid'
        Scripts = $summary.Scripts
        Packages = $summary.Packages
        RegistryValues = $summary.RegistryValues
        TaskLogonType = $task.Principal.LogonType
        TaskRunLevel = $task.Principal.RunLevel
        UserTaskLogonType = $userTask.Principal.LogonType
        UserTaskRunLevel = $userTask.Principal.RunLevel
        SignaturesRequired = $summary.SignaturesRequired
    }
}

if ($Action -eq 'Cleanup') {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        throw '-RunId is required for cleanup.'
    }
    if (-not (Test-SlipstreamAdministrator)) {
        throw 'Cleanup must run from an elevated PowerShell.'
    }

    Unregister-SlipstreamResumeTask -RunId $RunId
    $statePath = Get-SlipstreamStatePath -RunId $RunId
    if (Test-Path -LiteralPath $statePath) {
        $state = Read-SlipstreamState -RunId $RunId
        if (Test-Path -LiteralPath $state.payloadRoot) {
            Remove-Item -LiteralPath $state.payloadRoot -Recurse -Force
        }
    }
    Write-Host "Cleanup completed for run $RunId."
    return
}

if ($Action -eq 'Start' -and -not (Test-SlipstreamAdministrator)) {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (Test-SlipstreamAdministratorMembership)) {
        throw @'
Slipstream requires the signed-in user to be a local administrator. Elevating
with a different account would prevent reboot resume from retaining both the
original user's profile and the administrator token without storing credentials.
'@
    }
    Test-SlipstreamPayload `
        -PayloadRoot $sourceRoot `
        -AllowUnsigned:$AllowUnsigned | Out-Null
    $elevationExitCode = Invoke-SlipstreamElevation `
        -Sid $identity.User.Value `
        -UserName $identity.Name
    if ($elevationExitCode -eq 3010) {
        exit 3010
    }
    if ($elevationExitCode -ne 0) {
        throw "Elevated Windows Developer Config failed with exit code $elevationExitCode."
    }
    return
}

if (-not (Test-SlipstreamAdministrator)) {
    throw "Action '$Action' must run elevated."
}

if ($Action -eq 'Start') {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString()
    }
    if ([string]::IsNullOrWhiteSpace($OriginalUserSid) -or
        [string]::IsNullOrWhiteSpace($OriginalUserName)) {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $OriginalUserSid = $identity.User.Value
        $OriginalUserName = $identity.Name
    }

    $recoverable = Get-SlipstreamRecoverableRun -UserSid $OriginalUserSid
    if ($recoverable) {
        $RunId = $recoverable.runId
        $PayloadRoot = $recoverable.payloadRoot
        Write-Host "Resuming existing Slipstream run $RunId." -ForegroundColor Cyan
    }
    else {
        $PayloadRoot = Join-Path `
            (Join-Path $script:SlipstreamProgramDataRoot 'payloads') `
            $RunId
        Copy-SlipstreamPayload -Source $sourceRoot -Destination $PayloadRoot
    }
}
elseif ($Action -eq 'Resume') {
    if ([string]::IsNullOrWhiteSpace($RunId) -or
        [string]::IsNullOrWhiteSpace($PayloadRoot)) {
        throw '-RunId and -PayloadRoot are required for resume.'
    }
    $state = Read-SlipstreamState -RunId $RunId
    $OriginalUserSid = $state.originalUserSid
    $OriginalUserName = $state.originalUserName
}

Test-SlipstreamInitialPayload `
    -Root $PayloadRoot `
    -AllowUnsignedPayload:$AllowUnsigned
. (Join-Path $PayloadRoot 'bootstrap\common.ps1')
Test-SlipstreamPayload `
    -PayloadRoot $PayloadRoot `
    -AllowUnsigned:$AllowUnsigned | Out-Null

$controllerPath = Join-Path $PayloadRoot 'bootstrap\controller.ps1'
$result = & $controllerPath `
    -RunId $RunId `
    -PayloadRoot $PayloadRoot `
    -OriginalUserSid $OriginalUserSid `
    -OriginalUserName $OriginalUserName `
    -AllowUnsigned:$AllowUnsigned `
    -NoRestart:$NoRestart

if ($result -is [int] -and $result -eq 3010) {
    if ($Action -eq 'Resume') {
        exit 0
    }
    exit 3010
}
if ($result -is [int] -and $result -ne 0) {
    exit $result
}
