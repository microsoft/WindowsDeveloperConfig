Set-StrictMode -Version Latest

$script:SlipstreamProductName = 'WindowsDeveloperConfig'
$script:SlipstreamPayloadVersion = 'slipstream-0.1.0'
$script:SlipstreamProgramDataRoot = Join-Path $env:ProgramData 'Microsoft\WindowsDeveloperConfig'
$script:SlipstreamConfigHashes = @{
    'config\packages.json' = '75152DFEB6DD08A3718D6CA9486A7D660051E06103B942A029A13F6112DA2BE3'
    'config\registry.json' = '84E5947C1FE4BB0E28411290628FB388444DC15E365C9E2BD04FF41A7E3F15D8'
}

function Test-SlipstreamAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-SlipstreamAdministratorMembership {
    if (Test-SlipstreamAdministrator) {
        return $true
    }

    $output = & (Join-Path $env:SystemRoot 'System32\whoami.exe') `
        /groups `
        /fo csv `
        /nh 2>$null
    return $LASTEXITCODE -eq 0 -and
        (($output -join "`n") -match '(?<!\d)S-1-5-32-544(?!\d)')
}

function Get-SlipstreamRunRoot {
    param([Parameter(Mandatory)] [string] $RunId)

    return Join-Path (Join-Path $script:SlipstreamProgramDataRoot 'runs') $RunId
}

function Get-SlipstreamStatePath {
    param([Parameter(Mandatory)] [string] $RunId)

    return Join-Path (Get-SlipstreamRunRoot -RunId $RunId) 'state.json'
}

function Get-SlipstreamLogPath {
    param([Parameter(Mandatory)] [string] $RunId)

    return Join-Path (Join-Path (Get-SlipstreamRunRoot -RunId $RunId) 'logs') 'setup.log'
}

function Write-SlipstreamLog {
    param(
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f [DateTime]::UtcNow.ToString('o'), $Level, $Message
    $color = switch ($Level) {
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color

    $logPath = Get-SlipstreamLogPath -RunId $RunId
    $logDirectory = Split-Path -Parent $logPath
    if (-not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }
    [System.IO.File]::AppendAllText(
        $logPath,
        $line + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Write-SlipstreamJsonAtomic {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Value
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$Path.bak"
    try {
        $json = $Value | ConvertTo-Json -Depth 24
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $json,
            [System.Text.UTF8Encoding]::new($false)
        )

        if (Test-Path -LiteralPath $Path) {
            if (Test-Path -LiteralPath $backupPath) {
                Remove-Item -LiteralPath $backupPath -Force
            }
            [System.IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
            Remove-Item -LiteralPath $backupPath -Force
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Read-SlipstreamState {
    param([Parameter(Mandatory)] [string] $RunId)

    $path = Get-SlipstreamStatePath -RunId $RunId
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Slipstream state does not exist: $path"
    }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-SlipstreamState {
    param([Parameter(Mandatory)] [object] $State)

    $State.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-SlipstreamJsonAtomic `
        -Path (Get-SlipstreamStatePath -RunId $State.runId) `
        -Value $State
}

function Get-SlipstreamBootId {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    return $os.LastBootUpTime.ToUniversalTime().ToString('o')
}

function Get-SlipstreamPendingRebootReasons {
    $reasons = [System.Collections.Generic.List[string]]::new()

    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons.Add('ComponentBasedServicing')
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons.Add('WindowsUpdate')
    }

    $sessionManager = Get-ItemProperty `
        -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
        -Name PendingFileRenameOperations `
        -ErrorAction SilentlyContinue
    if ($sessionManager -and $sessionManager.PendingFileRenameOperations) {
        $reasons.Add('PendingFileRenameOperations')
    }

    $activeName = (Get-ItemProperty `
        -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' `
        -ErrorAction SilentlyContinue).ComputerName
    $pendingName = (Get-ItemProperty `
        -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' `
        -ErrorAction SilentlyContinue).ComputerName
    if ($activeName -and $pendingName -and $activeName -ne $pendingName) {
        $reasons.Add('ComputerRename')
    }

    return @($reasons)
}

function ConvertTo-SlipstreamExitCodeHex {
    param([Parameter(Mandatory)] [int] $ExitCode)

    $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$ExitCode), 0)
    return '0x{0:X8}' -f $unsigned
}

function Test-SlipstreamTransientFailure {
    param(
        [Parameter(Mandatory)] [int] $ExitCode,
        [string[]] $Output = @()
    )

    $hex = ConvertTo-SlipstreamExitCodeHex -ExitCode $ExitCode
    if ($hex -match '^0x80072' -or $hex -in @('0x801901F4', '0x8A15000F', '0x8A150010')) {
        return $true
    }

    $text = $Output -join "`n"
    return $text -match '(?i)temporar|timed?\s*out|network|connection|name resolution|source data'
}

function Invoke-SlipstreamNative {
    param(
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $ArgumentList = @(),
        [Parameter(Mandatory)] [string] $Name,
        [int] $MaxAttempts = 1,
        [switch] $AllowAnyExitCode
    )

    $attempt = 0
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        Write-SlipstreamLog -RunId $RunId -Message "$Name (attempt $attempt/$MaxAttempts)"
        $lines = [System.Collections.Generic.List[string]]::new()

        & $FilePath @ArgumentList 2>&1 | ForEach-Object {
            $line = $_.ToString()
            $lines.Add($line)
            Write-Host $line
            [System.IO.File]::AppendAllText(
                (Get-SlipstreamLogPath -RunId $RunId),
                $line + [Environment]::NewLine,
                [System.Text.UTF8Encoding]::new($false)
            )
        }
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            return [pscustomobject]@{
                ExitCode = $exitCode
                ExitCodeHex = ConvertTo-SlipstreamExitCodeHex -ExitCode $exitCode
                Output = @($lines)
            }
        }

        if ($attempt -lt $MaxAttempts -and
            (Test-SlipstreamTransientFailure -ExitCode $exitCode -Output @($lines))) {
            $delay = [math]::Min(30, [math]::Pow(2, $attempt + 1)) + (Get-Random -Minimum 0 -Maximum 3)
            Write-SlipstreamLog `
                -RunId $RunId `
                -Level WARN `
                -Message "$Name failed transiently with $(ConvertTo-SlipstreamExitCodeHex $exitCode); retrying in ${delay}s."
            Start-Sleep -Seconds $delay
            continue
        }

        if ($AllowAnyExitCode) {
            return [pscustomobject]@{
                ExitCode = $exitCode
                ExitCodeHex = ConvertTo-SlipstreamExitCodeHex -ExitCode $exitCode
                Output = @($lines)
            }
        }

        throw "$Name failed with $(ConvertTo-SlipstreamExitCodeHex $exitCode) ($exitCode)."
    }
}

function Get-SlipstreamSignedCommand {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $PublisherPattern
    )

    $commands = @(Get-Command `
        -Name $Name `
        -CommandType Application `
        -All `
        -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        $path = $command.Source
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }

        $signature = Get-AuthenticodeSignature -LiteralPath $path
        if ($signature.Status -eq 'Valid' -and
            $signature.SignerCertificate.Subject -match $PublisherPattern) {
            return $path
        }
    }

    throw "Unable to find a trusted '$Name' signed by the expected publisher."
}

function Get-SlipstreamDownload {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [uri] $Uri,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $Sha256
    )

    $previousProgress = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-WebRequest `
                    -Uri $Uri `
                    -OutFile $Destination `
                    -UseBasicParsing `
                    -ErrorAction Stop
                break
            }
            catch {
                if ($attempt -eq 3) {
                    throw
                }
                $delay = [math]::Pow(2, $attempt + 1)
                Write-SlipstreamLog `
                    -RunId $State.runId `
                    -Level WARN `
                    -Message "Download failed; retrying in ${delay}s: $Uri"
                Start-Sleep -Seconds $delay
            }
        }
    }
    finally {
        $ProgressPreference = $previousProgress
    }

    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($actual -ne $Sha256) {
        Remove-Item -LiteralPath $Destination -Force
        throw "Hash mismatch for $Uri. Expected $Sha256, got $actual."
    }
}

function Refresh-SlipstreamPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($machine, $user) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $env:Path = $parts -join ';'
}

function ConvertTo-SlipstreamRegistryPath {
    param([Parameter(Mandatory)] [string] $Path)

    if ($Path.StartsWith('HKLM\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'Registry::HKEY_LOCAL_MACHINE\' + $Path.Substring(5)
    }
    if ($Path.StartsWith('HKCU\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'Registry::HKEY_CURRENT_USER\' + $Path.Substring(5)
    }
    throw "Unsupported registry hive in '$Path'."
}

function Get-SlipstreamConfigTextHash {
    param([Parameter(Mandatory)] [string] $Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $normalized = [Text.Encoding]::UTF8.GetBytes(
        ($text -replace "`r`n", "`n")
    )
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

function Test-SlipstreamPayload {
    param(
        [Parameter(Mandatory)] [string] $PayloadRoot,
        [switch] $AllowUnsigned
    )

    $requiredFiles = @(
        'install.ps1',
        'bootstrap\common.ps1',
        'bootstrap\controller.ps1',
        'bootstrap\platform.ps1',
        'bootstrap\resume.ps1',
        'bootstrap\configure.ps1',
        'bootstrap\user.ps1',
        'bootstrap\verify.ps1',
        'config\packages.json',
        'config\registry.json'
    )
    foreach ($relativePath in $requiredFiles) {
        $path = Join-Path $PayloadRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Slipstream payload is incomplete; missing $relativePath."
        }
    }

    foreach ($scriptPath in Get-ChildItem -LiteralPath $PayloadRoot -Recurse -Filter *.ps1 -File) {
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath.FullName,
            [ref]$null,
            [ref]$parseErrors
        )
        if ($parseErrors) {
            throw "PowerShell parse failure in $($scriptPath.FullName): $($parseErrors[0].Message)"
        }

        if (-not $AllowUnsigned) {
            $signature = Get-AuthenticodeSignature -LiteralPath $scriptPath.FullName
            if ($signature.Status -ne 'Valid') {
                throw "Invalid Authenticode signature on $($scriptPath.Name): $($signature.Status)"
            }
            if ($signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
                throw "Unexpected signer on $($scriptPath.Name): $($signature.SignerCertificate.Subject)"
            }
        }
    }

    foreach ($relativePath in $script:SlipstreamConfigHashes.Keys) {
        $path = Join-Path $PayloadRoot $relativePath
        $actual = Get-SlipstreamConfigTextHash -Path $path
        $expected = $script:SlipstreamConfigHashes[$relativePath]
        if ($actual -ne $expected) {
            throw "Hash mismatch for $relativePath. Expected $expected, got $actual."
        }
    }

    $packages = Get-Content (Join-Path $PayloadRoot 'config\packages.json') -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $registry = Get-Content (Join-Path $PayloadRoot 'config\registry.json') -Raw -Encoding UTF8 |
        ConvertFrom-Json
    if ($packages.schemaVersion -ne 1 -or @($packages.packages).Count -eq 0) {
        throw 'packages.json has an unsupported or empty schema.'
    }
    if ($registry.schemaVersion -ne 1 -or @($registry.values).Count -eq 0) {
        throw 'registry.json has an unsupported or empty schema.'
    }

    $duplicatePackages = @($packages.packages | Group-Object id | Where-Object Count -gt 1)
    if ($duplicatePackages.Count -gt 0) {
        throw "packages.json contains duplicate ids: $($duplicatePackages.Name -join ', ')"
    }
    $duplicateRegistryNames = @($registry.values | Group-Object name | Where-Object Count -gt 1)
    if ($duplicateRegistryNames.Count -gt 0) {
        throw "registry.json contains duplicate names: $($duplicateRegistryNames.Name -join ', ')"
    }

    return [pscustomobject]@{
        Scripts = @(Get-ChildItem -LiteralPath $PayloadRoot -Recurse -Filter *.ps1 -File).Count
        Packages = @($packages.packages).Count
        RegistryValues = @($registry.values).Count
        SignaturesRequired = -not $AllowUnsigned
    }
}

function New-SlipstreamPhaseResult {
    param(
        [switch] $RebootRequired,
        [bool] $AdvancePhase = $true,
        [string] $Reason
    )

    return [pscustomobject]@{
        RebootRequired = [bool]$RebootRequired
        AdvancePhase = $AdvancePhase
        Reason = $Reason
    }
}
