$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')

$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\wsl-comfort')).Path
$launcherText = Get-Content -LiteralPath (Join-Path $sourceRoot 'setup.ps1') -Raw
$launch = [scriptblock]::Create($launcherText)
$microsoftSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
$expectedShell = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
} else {
    Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
}

function Get-CanonicalSha256 {
    param([Parameter(Mandatory)] [byte[]] $Bytes)

    $stream = [IO.MemoryStream]::new()
    try {
        for ($index = 0; $index -lt $Bytes.Length; $index++) {
            if ($Bytes[$index] -ne 13 -or $index + 1 -ge $Bytes.Length -or $Bytes[$index + 1] -ne 10) {
                $stream.WriteByte($Bytes[$index])
            }
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($stream.ToArray()))).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

# The signed manifest must pin every non-PowerShell file the launcher stages next to install.ps1.
$manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $sourceRoot 'content-hashes.psd1')
$payloadFiles = @(Get-ChildItem -LiteralPath $sourceRoot -File |
    Where-Object { $_.Extension -notin @('.ps1', '.psd1', '.md') } |
    ForEach-Object { $_.Name } |
    Sort-Object)
Assert-Equal (@($manifest.Keys | Sort-Object) -join ', ') ($payloadFiles -join ', ') 'content-hashes.psd1 should list every non-PowerShell WSL Comfort payload file'
foreach ($name in $payloadFiles) {
    $expectedHash = Get-CanonicalSha256 -Bytes ([IO.File]::ReadAllBytes((Join-Path $sourceRoot $name)))
    Assert-Equal $manifest[$name] $expectedHash "content-hashes.psd1 should pin the current $name"
}

$payloadRef = [regex]::Match($launcherText, "(?m)^\s*\`$payloadRef = '([^']*)'").Groups[1].Value
Assert-True ($payloadRef -match '^(main|[a-f0-9]{40})$') 'Launcher should pin main or a full payload commit SHA'
$baseUri = "https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/$payloadRef/wsl-comfort"

# Stands in for install.ps1 so the real child process reports what it received.
$installStub = @'
param([switch] $NonInteractive, [string] $Distro, [string[]] $BootstrapArgs = @())
if ($Distro -eq 'fail') { throw 'install.ps1 stub failure' }
$result = [pscustomobject]@{
    NonInteractive = [bool]$NonInteractive
    Distro = $Distro
    BootstrapArgs = @($BootstrapArgs)
    ScriptRoot = $PSScriptRoot
    ModulePath = $env:PSModulePath
    ShellHome = $PSHOME
    Is64BitProcess = [Environment]::Is64BitProcess
}
[IO.File]::WriteAllText($env:COMFORT_SHELL_STUB_RESULT, ($result | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
'@
$validSignature = [pscustomobject]@{
    Status = 'Valid'
    SignerCertificate = [pscustomobject]@{ Subject = $microsoftSubject }
}
$bootstrapBytes = [IO.File]::ReadAllBytes((Join-Path $sourceRoot 'comfort-shell-bootstrap.sh'))
$manifestBytes = [IO.File]::ReadAllBytes((Join-Path $sourceRoot 'content-hashes.psd1'))

function Get-RunFolders {
    return @(Get-ChildItem -LiteralPath $runRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName } |
        Sort-Object)
}

function Reset-LauncherFixture {
    param([hashtable] $Served = @{})

    $script:Served = @{
        'install.ps1' = [Text.Encoding]::UTF8.GetBytes($installStub)
        'content-hashes.psd1' = $manifestBytes
        'comfort-shell-bootstrap.sh' = $bootstrapBytes
    }
    foreach ($key in $Served.Keys) {
        $script:Served[$key] = $Served[$key]
    }
    $script:Signatures = @{ 'install.ps1' = $validSignature; 'content-hashes.psd1' = $validSignature }
    $script:Policies = @{ MachinePolicy = 'Undefined'; UserPolicy = 'Undefined' }
    $script:Downloads = [Collections.Generic.List[string]]::new()
    $script:Started = $null
    $script:RunFoldersBefore = Get-RunFolders
    Remove-Item -LiteralPath $env:COMFORT_SHELL_STUB_RESULT -Force -ErrorAction SilentlyContinue
}

function Get-ExecutionPolicy {
    param([string] $Scope)
    return $script:Policies[$Scope]
}

function Invoke-WebRequest {
    param([string] $Uri, [string] $OutFile, [switch] $UseBasicParsing, [int] $TimeoutSec)
    Assert-True $UseBasicParsing.IsPresent 'Launcher should support Windows PowerShell'
    Assert-Equal $TimeoutSec 60 'Launcher should bound each download'
    Assert-True $Uri.StartsWith("$baseUri/", [StringComparison]::Ordinal) "Launcher should download from its payload ref, not $Uri"
    $name = $Uri.Substring($baseUri.Length + 1)
    $script:Downloads.Add($name)
    if (-not $script:Served.ContainsKey($name)) {
        throw "404 Not Found: $Uri"
    }
    [IO.File]::WriteAllBytes($OutFile, [byte[]]$script:Served[$name])
}

function Get-AuthenticodeSignature {
    param([string] $LiteralPath)
    $name = Split-Path -Leaf $LiteralPath
    Assert-True $script:Signatures.ContainsKey($name) "Launcher should verify signatures only on PowerShell files, not $name"
    return $script:Signatures[$name]
}

function Start-Process {
    param([string] $FilePath, [string[]] $ArgumentList, [switch] $NoNewWindow, [switch] $PassThru, [switch] $Wait)
    Assert-True $NoNewWindow.IsPresent 'Launcher should run install.ps1 in the current console'
    Assert-True $PassThru.IsPresent 'Launcher should read the install.ps1 exit code'
    Assert-True (-not $Wait.IsPresent) 'Launcher should not wait on processes install.ps1 leaves running'
    $script:Started = [pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList }
    return Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru `
        -RedirectStandardOutput (Join-Path $fixtureRoot 'launch-stdout.txt') -RedirectStandardError (Join-Path $fixtureRoot 'launch-stderr.txt')
}

function Write-Host { }

function Get-LaunchResult {
    Assert-True ($null -ne $script:Started) 'Launcher should start install.ps1'
    Assert-Equal $script:Started.FilePath $expectedShell 'Launcher should run install.ps1 in a native-bitness PowerShell'
    Assert-Equal (@($script:Started.ArgumentList)[0..3] -join ' ') '-NoProfile -ExecutionPolicy RemoteSigned -Command' 'Launcher should request process-scoped RemoteSigned'
    if (-not (Test-Path -LiteralPath $env:COMFORT_SHELL_STUB_RESULT)) {
        throw "install.ps1 did not run: $([IO.File]::ReadAllText((Join-Path $fixtureRoot 'launch-stderr.txt')))"
    }
    $result = [IO.File]::ReadAllText($env:COMFORT_SHELL_STUB_RESULT, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-Equal $result.Is64BitProcess ([Environment]::Is64BitOperatingSystem) 'install.ps1 should run in a PowerShell that can see the native wsl.exe'
    Assert-True $result.ModulePath.StartsWith("$($result.ShellHome)\Modules;", [StringComparison]::OrdinalIgnoreCase) 'install.ps1 should load its own edition''s built-in modules first'
    Assert-Equal @(Get-RunFolders).Count (@($script:RunFoldersBefore).Count + 1) 'Launcher should stage each run in one new folder'
    Assert-True ((Split-Path -Parent $result.ScriptRoot) -eq $runRoot -and (Split-Path -Leaf $result.ScriptRoot) -match '^\d{8}-\d{6}-[0-9a-f]{8}$') `
        'install.ps1 should run from its own per-run folder so reboot resume can find it'
    Assert-Equal (@(Get-ChildItem -LiteralPath $result.ScriptRoot -File | ForEach-Object { $_.Name } | Sort-Object) -join ', ') `
        'comfort-shell-bootstrap.sh, content-hashes.psd1, install.ps1' 'Launcher should stage exactly the verified payload'
    return $result
}

function Assert-NotStarted {
    param([string] $Reason)
    Assert-True ($null -eq $script:Started) "Launcher should not start install.ps1 $Reason"
    Assert-Equal (@(Get-RunFolders) -join ', ') (@($script:RunFoldersBefore) -join ', ') "Launcher should remove its folder $Reason"
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "comfort-shell-unit-$([guid]::NewGuid().ToString('N'))"
$originalLocalAppData = $env:LOCALAPPDATA
$originalModulePath = $env:PSModulePath
$originalProtocol = [Net.ServicePointManager]::SecurityProtocol
try {
    $env:LOCALAPPDATA = Join-Path $fixtureRoot 'LocalAppData'
    $env:COMFORT_SHELL_STUB_RESULT = Join-Path $fixtureRoot 'stub-result.json'
    $null = New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force
    $runRoot = Join-Path $env:LOCALAPPDATA 'DevConfig\wsl-comfort'

    # irm | iex: no parameters and the working-tree bootstrap, next to an earlier run awaiting resume.
    $earlierRun = Join-Path $runRoot '20200101-000000-0123abcd'
    $null = New-Item -ItemType Directory -Path $earlierRun -Force
    Set-Content -LiteralPath (Join-Path $earlierRun 'install.ps1') -Value '# earlier run'
    Reset-LauncherFixture
    & {
        $ErrorActionPreference = 'Continue'
        $launcherText | Invoke-Expression
        Assert-Equal $ErrorActionPreference 'Continue' 'Launcher should not change the caller''s error preference'
    }
    Assert-Equal ($script:Downloads -join ', ') 'install.ps1, content-hashes.psd1, comfort-shell-bootstrap.sh' 'Launcher should verify signed files before fetching hashed content'
    $result = Get-LaunchResult
    Assert-Equal $result.NonInteractive $false 'Launcher should stay interactive by default'
    Assert-Equal $result.Distro '' 'Launcher should let install.ps1 pick the distro by default'
    Assert-Equal @($result.BootstrapArgs).Count 0 'Launcher should not add bootstrap arguments by default'
    Assert-Equal (Get-Content -LiteralPath (Join-Path $earlierRun 'install.ps1') -Raw).Trim() '# earlier run' 'Launcher should leave earlier runs alone so a pending resume still works'
    Assert-Equal (Get-CanonicalSha256 -Bytes ([IO.File]::ReadAllBytes((Join-Path $result.ScriptRoot 'comfort-shell-bootstrap.sh')))) `
        $manifest['comfort-shell-bootstrap.sh'] 'Launcher should stage the verified bootstrap bytes'

    # GitHub serves the committed LF bytes; arguments must survive PowerShell and command-line quoting.
    $lfBootstrap = [Text.Encoding]::GetEncoding(28591).GetBytes(
        [Text.Encoding]::GetEncoding(28591).GetString($bootstrapBytes).Replace("`r`n", "`n"))
    Reset-LauncherFixture -Served @{ 'comfort-shell-bootstrap.sh' = $lfBootstrap }
    $distro = "Ubuntu-24.04 it's ""x"""
    $bootstrapArgs = @(
        '--shell=bash'
        ''
        "it's ""quoted"" `$HOME ``tick \\server\share\ trailing\"
        'one\"slash, two\\"slashes, three\\\"slashes'
        "smart $([char]0x2018)single$([char]0x2019) and $([char]0x201C)double$([char]0x201D) quotes"
        "line one`nline two"
    )
    & $launch -NonInteractive -Distro $distro -BootstrapArgs $bootstrapArgs
    $result = Get-LaunchResult
    Assert-Equal $result.NonInteractive $true 'Launcher should forward -NonInteractive'
    Assert-Equal $result.Distro $distro 'Launcher should forward -Distro verbatim'
    Assert-Equal @($result.BootstrapArgs).Count $bootstrapArgs.Count 'Launcher should forward every bootstrap argument'
    for ($index = 0; $index -lt $bootstrapArgs.Count; $index++) {
        Assert-Equal @($result.BootstrapArgs)[$index] $bootstrapArgs[$index] "Launcher should forward bootstrap argument $index verbatim"
    }

    Reset-LauncherFixture
    Assert-ThrowsLike { & $launch -Distro 'fail' } '*WSL Comfort setup finished with exit code 1*' 'Launcher should report install.ps1 failures'

    Reset-LauncherFixture -Served @{ 'comfort-shell-bootstrap.sh' = [byte[]]($bootstrapBytes + [byte[]](35, 10)) }
    Assert-ThrowsLike { & $launch } '*comfort-shell-bootstrap.sh failed SHA-256 verification*' 'Launcher should reject modified bootstrap content'
    Assert-NotStarted 'after a failed hash check'

    foreach ($name in @('install.ps1', 'content-hashes.psd1')) {
        foreach ($invalidSignature in @(
            [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null }
            [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = [pscustomobject]@{ Subject = $microsoftSubject } }
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = $null }
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Other' } }
        )) {
            Reset-LauncherFixture
            $script:Signatures[$name] = $invalidSignature
            Assert-ThrowsLike { & $launch } "*$name failed Microsoft signature verification*" "Launcher should reject an untrusted $name"
            Assert-NotStarted "with an untrusted $name"
            Assert-True (-not $script:Downloads.Contains('comfort-shell-bootstrap.sh')) 'Launcher should fetch hashed content only after the signed files verify'
        }
    }

    foreach ($unexpected in @('..\escape.sh', 'nested/file.sh', 'extra.ps1', 'extra.psd1')) {
        Reset-LauncherFixture -Served @{
            'content-hashes.psd1' = [Text.Encoding]::UTF8.GetBytes("@{ '$unexpected' = '$('0' * 64)' }")
        }
        Assert-ThrowsLike { & $launch } '*content manifest lists an unexpected file*' "Launcher should refuse to fetch '$unexpected'"
        Assert-NotStarted 'for an unexpected manifest entry'
    }

    Reset-LauncherFixture
    $null = $script:Served.Remove('comfort-shell-bootstrap.sh')
    Assert-ThrowsLike { & $launch } '*404 Not Found*' 'Launcher should stop when a payload file cannot be downloaded'
    Assert-NotStarted 'after a failed download'

    foreach ($scope in @('MachinePolicy', 'UserPolicy')) {
        Reset-LauncherFixture
        $script:Policies[$scope] = 'Restricted'
        Assert-ThrowsLike { & $launch } "*Organization policy ($scope) requires Restricted*" "Launcher should explain a Restricted $scope"
        Assert-Equal $script:Downloads.Count 0 'Launcher should check execution policy before downloading'
        Assert-NotStarted 'when script execution is disabled'
    }
    Reset-LauncherFixture
    $script:Policies['MachinePolicy'] = 'RemoteSigned'
    $script:Policies['UserPolicy'] = 'Restricted'
    & $launch
    $null = Get-LaunchResult
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:PSModulePath = $originalModulePath
    [Net.ServicePointManager]::SecurityProtocol = $originalProtocol
    Remove-Item Env:\COMFORT_SHELL_STUB_RESULT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Microsoft.PowerShell.Utility\Write-Host "UNIT_OK: comfort-shell launcher ($script:AssertionCount assertions)"
