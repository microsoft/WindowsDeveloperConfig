# Checks PowerShell discovery and handoff without installing software or elevating.
param(
    [string] $StepsDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $StepsDirectory) {
    $StepsDirectory = Join-Path $PSScriptRoot '..\..\windows-dev-config\steps'
}
. (Join-Path $StepsDirectory '_elevation.ps1')
. (Join-Path $StepsDirectory '_pwsh-bootstrap.ps1')

$tokens = $null
$parseErrors = $null
$bootstrap = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $StepsDirectory '..\bootstrap.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors -join [Environment]::NewLine) }
$bootstrapResolver = $bootstrap.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DevConfigPwshExe'
}, $true)
$bootstrapFunction = $bootstrap.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-CalmOsBootstrap'
}, $true)
$selection = @()
$selecting = $false
foreach ($statement in $bootstrapFunction.Body.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.AssignmentStatementAst]) {
        if ($statement.Left.Extent.Text -eq '$shell') { $selecting = $true }
        if ($statement.Left.Extent.Text -eq '$escapedShell') { break }
    }
    if ($selecting) { $selection += $statement.Extent.Text }
}
if (-not $selection) { throw 'Bootstrap shell selection was not found.' }
$selectBootstrapShell = [scriptblock]::Create(
    'param([string] $Action)' + [Environment]::NewLine +
    ($selection -join [Environment]::NewLine) + [Environment]::NewLine + '$shell')
$elevationSelection = ${function:Invoke-DevConfigElevate}.Ast.Find({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$shell'
}, $true)
$selectElevationShell = [scriptblock]::Create(
    'param([string] $Action)' + [Environment]::NewLine +
    $elevationSelection.Extent.Text + [Environment]::NewLine + '$shell')

$originalEdition = $PSVersionTable.PSEdition
$originalVersion = $PSVersionTable.PSVersion
$originalRoots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})
$currentPwsh = Join-Path $PSHOME 'pwsh.exe'
$msiPwsh = 'C:\DevConfig-Pwsh-Checks\Native\PowerShell\7\pwsh.exe'
$portablePwsh = 'C:\DevConfig-Pwsh-Checks\Portable [7] with spaces\pwsh.exe'
$msixHome = 'C:\DevConfig-Pwsh-Checks\WindowsApps\Microsoft.PowerShell_7.0.0.0_arm64__test'
$msixPwsh = Join-Path $msixHome 'pwsh.exe'
$aliasPwsh = 'C:\DevConfig-Pwsh-Checks\Local\Microsoft\WindowsApps\pwsh.exe'
$passed = 0
$failed = 0

function Assert($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Check([string] $Name, [scriptblock] $Action) {
    try {
        & $Action
        Write-Host "PASS  $Name" -ForegroundColor Green
        $script:passed++
    } catch {
        Write-Host "FAIL  ${Name}: $($_.Exception.Message)" -ForegroundColor Red
        $script:failed++
    }
}
function Expect-Failure([scriptblock] $Action) {
    try { & $Action } catch { return $_ }
    throw 'Expected an error, but the operation succeeded.'
}
function Reset-TestState([string] $Edition = 'Desktop', [version] $Version = '5.1') {
    $PSVersionTable.PSEdition = $Edition
    $PSVersionTable.PSVersion = $Version
    $script:Files = @()
    $script:Commands = @()
    $script:Packages = @()
    $script:PackageQueries = 0
    $script:PackageFailure = $null
    $script:HasAppxCommand = $true
    $script:Starts = @()
    $script:Installs = 0
    $script:InstallRegistersMsix = $false
}
function Test-Path {
    [CmdletBinding()]
    param([string] $LiteralPath, [string] $PathType)
    Assert ($PathType -in @('', 'Leaf')) "Unexpected path type: $PathType"
    return $script:Files -contains $LiteralPath
}
function Get-Command {
    [CmdletBinding()]
    param([string] $Name, [string] $CommandType, [switch] $All)
    if ($Name -eq 'pwsh.exe') {
        Assert ($CommandType -eq 'Application' -and $All) 'Discovery must inspect applications, not functions or aliases.'
        return $script:Commands
    }
    Assert ($Name -eq 'Get-AppxPackage') "Unexpected command lookup: $Name"
    if ($script:HasAppxCommand) { [pscustomobject]@{ Name = $Name } }
}
function Get-AppxPackage {
    [CmdletBinding()]
    param([string] $Name)
    Assert ($Name -eq 'Microsoft.PowerShell') 'Only the current user stable PowerShell package should be queried.'
    Assert ($PSBoundParameters.ErrorAction -eq 'Stop') 'Package discovery failures must surface.'
    $script:PackageQueries++
    if ($script:PackageFailure) { throw $script:PackageFailure }
    return $script:Packages
}
function Install-DevConfigPwshBootstrap {
    $script:Installs++
    if ($script:InstallRegistersMsix) {
        $script:Files += $msixPwsh
        $script:Packages = @([pscustomobject]@{ Version = '7.0.0.0'; InstallLocation = $msixHome })
    }
}
function Start-Process {
    param($FilePath, $ArgumentList, [switch] $Wait, [switch] $NoNewWindow, [switch] $PassThru)
    $script:Starts += [pscustomobject]@{
        FilePath = $FilePath; Arguments = $ArgumentList
        Wait = [bool]$Wait; NoNewWindow = [bool]$NoNewWindow; PassThru = [bool]$PassThru
    }
    throw 'Test stopped before the child process handoff.'
}
function Assert-Discovery([string] $Expected) {
    $actual = @(Get-DevConfigPwshExe)
    Assert ($actual.Count -eq 1 -and $actual[0] -eq $Expected) "Unexpected discovery result: $actual"
    Assert (Test-DevConfigHasPwsh) 'Readiness must recognize the same installation.'
    Assert ((Get-DevConfigShellExe) -eq $Expected) 'Direct elevation selected a different installation.'
    foreach ($action in @('Full', 'Partial')) {
        Assert ((& $selectBootstrapShell $action) -eq $Expected) "Bootstrap selected the wrong shell for $action."
        Assert ((& $selectElevationShell $action) -eq $Expected) "Elevation selected the wrong shell for $action."
    }
}

try {
    $env:ProgramW6432 = 'C:\DevConfig-Pwsh-Checks\Native'
    $env:ProgramFiles = 'C:\DevConfig-Pwsh-Checks\Current'
    ${env:ProgramFiles(x86)} = 'C:\DevConfig-Pwsh-Checks\X86'

    Check 'Standalone bootstrap and staged resolver remain identical' {
        Assert ($null -ne $bootstrapResolver) 'Bootstrap must define its resolver before downloading helpers.'
        $standalone = ($bootstrapResolver.Body.Extent.Text.Trim().Trim('{', '}').Trim() -split '\r?\n' |
            ForEach-Object { $_.Trim() }) -join "`n"
        $staged = (${function:Get-DevConfigPwshExe}.ToString().Trim() -split '\r?\n' |
            ForEach-Object { $_.Trim() }) -join "`n"
        Assert ($standalone -ceq $staged) 'The two resolver implementations diverged.'
    }
    Check 'An existing PS7 host wins over other installations without querying packages' {
        Reset-TestState Core '7.0'
        $script:Files = @($currentPwsh, $msiPwsh, $portablePwsh, $msixPwsh)
        Assert-Discovery $currentPwsh
        Assert ($script:PackageQueries -eq 0) 'The running PS7 must not need Appx cmdlets.'
    }
    Check 'A missing current executable falls back to an installed MSI' {
        Reset-TestState Core '7.0'
        $script:Files = @($msiPwsh)
        Assert-Discovery $msiPwsh
    }
    foreach ($root in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        Check "Windows PowerShell discovers MSI without PATH under $root" {
            Reset-TestState
            $candidate = Join-Path $root 'PowerShell\7\pwsh.exe'
            $script:Files = @($candidate)
            Assert-Discovery $candidate
        }
    }
    Check 'Windows PowerShell discovers portable PS7 using an absolute PATH result' {
        Reset-TestState
        $script:Files = @($portablePwsh)
        $script:Commands = @([pscustomobject]@{ Source = $portablePwsh; Version = [version]'7.0' })
        Assert-Discovery $portablePwsh
    }
    foreach ($withAlias in @($false, $true)) {
        Check "Windows PowerShell discovers registered MSIX with alias present: $withAlias" {
            Reset-TestState
            $script:Files = @($msixPwsh)
            $script:Packages = @([pscustomobject]@{ Version = '7.0.0.0'; InstallLocation = $msixHome })
            if ($withAlias) {
                $script:Files += $aliasPwsh
                $script:Commands = @([pscustomobject]@{ Source = $aliasPwsh; Version = [version]'0.0' })
            }
            Assert-Discovery $msixPwsh
            Assert ($script:PackageQueries -gt 0) 'MSIX must resolve through current-user package registration.'
        }
    }
    Check 'Old PowerShell and stale PATH entries do not hide a usable PS7' {
        Reset-TestState
        $script:Files = @($aliasPwsh, $portablePwsh)
        $script:Commands = @(
            [pscustomobject]@{ Source = $aliasPwsh; Version = [version]'6.0' }
            [pscustomobject]@{ Source = 'C:\DevConfig-Pwsh-Checks\Missing\pwsh.exe'; Version = [version]'7.0' }
            [pscustomobject]@{ Source = $portablePwsh; Version = [version]'7.0' }
        )
        Assert-Discovery $portablePwsh
    }
    Check 'MSIX selection ignores incomplete registrations and sorts versions numerically' {
        Reset-TestState
        $olderHome = "$msixHome-older"
        $script:Files = @($msixPwsh, (Join-Path $olderHome 'pwsh.exe'))
        $script:Packages = @(
            [pscustomobject]@{ Version = '7.9.0.0'; InstallLocation = $olderHome }
            [pscustomobject]@{ Version = '7.12.0.0'; InstallLocation = "$msixHome-missing" }
            [pscustomobject]@{ Version = '7.11.0.0'; InstallLocation = '' }
            [pscustomobject]@{ Version = '7.10.0.0'; InstallLocation = $msixHome }
        )
        Assert-Discovery $msixPwsh
    }
    foreach ($appxAvailable in @($false, $true)) {
        Check "No usable PS7 preserves the Windows PowerShell fallback; Appx available: $appxAvailable" {
            Reset-TestState
            $script:HasAppxCommand = $appxAvailable
            $script:Files = @($aliasPwsh)
            $script:Commands = @([pscustomobject]@{ Source = $aliasPwsh; Version = [version]'0.0' })
            Assert ($null -eq (Get-DevConfigPwshExe)) 'An unresolved execution alias is not a usable host.'
            Assert (-not (Test-DevConfigHasPwsh)) 'Readiness must report the missing host.'
            Assert ((Get-DevConfigShellExe) -eq 'powershell.exe') 'Direct Windows PowerShell fallback changed.'
            $expected = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
            Assert ((& $selectBootstrapShell Full) -eq $expected) 'Bootstrap Windows PowerShell fallback changed.'
        }
    }
    Check 'Package discovery errors cannot trigger an unnecessary installation' {
        Reset-TestState
        $script:PackageFailure = 'Package discovery failed.'
        $failure = Expect-Failure { Invoke-DevConfigEnsurePwsh -ScriptPath 'C:\Setup\dev-config.ps1' }
        Assert ($failure.Exception.Message -eq $script:PackageFailure) 'The discovery error must surface unchanged.'
        Assert ($script:Installs -eq 0 -and $script:Starts.Count -eq 0) 'Failed discovery must not install or launch another host.'
    }
    Check 'Uninstall bypasses PS7 discovery and scheduled tasks keep their separate resolver' {
        Reset-TestState Core '7.0'
        $script:Files = @($currentPwsh, $msixPwsh)
        $script:PackageFailure = 'Uninstall must not query packages.'
        $expected = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
        Assert ((& $selectBootstrapShell Uninstall) -eq $expected) 'Bootstrap cleanup must use Windows PowerShell.'
        $expected = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Assert ((& $selectElevationShell Uninstall) -eq $expected) 'Direct cleanup must use Windows PowerShell.'
        Assert ((Get-DevConfigTaskShellExe) -eq $expected) 'Tasks must not inherit the interactive MSIX resolver.'
        Assert ($script:PackageQueries -eq 0) 'Cleanup and task selection must not query MSIX packages.'
    }
    Check 'A running PS7 does not install or relaunch another copy' {
        Reset-TestState Core '7.0'
        Invoke-DevConfigEnsurePwsh -ScriptPath 'C:\Setup\dev-config.ps1'
        Assert ($script:Installs -eq 0 -and $script:Starts.Count -eq 0) 'A PS7 setup must remain in its host.'
    }
    foreach ($kind in @('MSI', 'Portable', 'MSIX', 'NewInstall')) {
        Check "$kind handoff reuses the resolved executable and preserves launch arguments" {
            Reset-TestState
            $expected = $msixPwsh
            switch ($kind) {
                MSI { $expected = $msiPwsh; $script:Files = @($msiPwsh) }
                Portable {
                    $expected = $portablePwsh
                    $script:Files = @($portablePwsh)
                    $script:Commands = @([pscustomobject]@{ Source = $portablePwsh; Version = [version]'7.0' })
                }
                MSIX {
                    $script:Files = @($msixPwsh)
                    $script:Packages = @([pscustomobject]@{ Version = '7.0.0.0'; InstallLocation = $msixHome })
                }
                NewInstall { $script:InstallRegistersMsix = $true }
            }
            $failure = Expect-Failure {
                Invoke-DevConfigEnsurePwsh -ScriptPath 'C:\Setup Files\dev-config.ps1' `
                    -Action Partial -Workload winui -Resumed -AllowUnsigned
            }
            Assert ($failure.Exception.Message -eq 'Test stopped before the child process handoff.') 'Handoff failed before starting the child.'
            Assert ($script:Installs -eq [int]($kind -eq 'NewInstall')) 'Only a missing PS7 may trigger installation.'
            Assert ($script:Starts.Count -eq 1 -and $script:Starts[0].FilePath -eq $expected) 'Handoff used a different executable.'
            $call = $script:Starts[0]
            Assert ($call.Wait -and $call.NoNewWindow -and $call.PassThru) 'Process waiting and console behavior changed.'
            Assert (($call.Arguments -join ' ') -eq
                '-NoProfile -File "C:\Setup Files\dev-config.ps1" -Action Partial -Workload winui -NoElevate -Resumed -AllowUnsigned') 'Relaunch arguments changed.'
        }
    }
    Check 'An unsuccessful PS7 installation still permits Windows PowerShell setup' {
        Reset-TestState
        Invoke-DevConfigEnsurePwsh -ScriptPath 'C:\Setup\dev-config.ps1'
        Assert ($script:Installs -eq 1 -and $script:Starts.Count -eq 0) 'Missing PS7 must retain the existing fallback.'
    }
} finally {
    $PSVersionTable.PSEdition = $originalEdition
    $PSVersionTable.PSVersion = $originalVersion
    $env:ProgramW6432 = $originalRoots[0]
    $env:ProgramFiles = $originalRoots[1]
    ${env:ProgramFiles(x86)} = $originalRoots[2]
}

Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 }
