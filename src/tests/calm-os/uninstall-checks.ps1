# Checks uninstall command routing without changing machine state.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourceRoot = Join-Path $PSScriptRoot '..\..\windows-dev-config'
. (Join-Path $sourceRoot 'steps\_winget.ps1')

$script:passed = 0
$script:failed = 0
function Assert-Check([bool] $Condition, [string] $Label) {
    if ($Condition) {
        Write-Host "PASS  $Label" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "FAIL  $Label" -ForegroundColor Red
        $script:failed++
    }
}

$script:calls = [Collections.Generic.List[object]]::new()
$script:entry = [pscustomobject]@{
    DisplayName = 'Microsoft Visual Studio Code (User)'
    Publisher = 'Microsoft Corporation'
    UninstallString = '"C:\Fixture\Visual Studio Code\unins000.exe"'
}
$script:packageExit = 0
$script:commandFailure = $false

function Test-Path {
    param([string] $LiteralPath)
    return $LiteralPath -notmatch '\\WOW6432Node\\'
}
function Get-ChildItem {
    param([string] $LiteralPath, [string] $ErrorAction)
    [pscustomobject]@{ PSChildName = 'fixture_is1'; PSPath = "$LiteralPath\fixture_is1" }
}
function Get-ItemProperty {
    param([string] $LiteralPath, [string] $ErrorAction)
    return $script:entry
}
function Get-AppxPackage {
    param([switch] $AllUsers, [string] $Name, [string] $ErrorAction)
    return @()
}
function Invoke-DevConfigCleanupCommand {
    param([string] $FilePath, [string[]] $Arguments, [int[]] $SuccessCodes, [switch] $Unelevated)
    $script:calls.Add([pscustomobject]@{ File = $FilePath; Arguments = $Arguments; Unelevated = [bool]$Unelevated })
    if ($script:commandFailure) { throw 'Fixture uninstaller failed (1).' }
    [pscustomobject]@{ ExitCode = $script:packageExit; Output = '' }
}

$inno = @{ DisplayName = 'Microsoft Visual Studio Code'; Publisher = 'Microsoft Corporation' }
$silentArguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
foreach ($scope in @('user', 'machine')) {
    $script:calls.Clear()
    Invoke-DevConfigInnoCleanup @inno -Scope $scope
    Assert-Check ($script:calls.Count -eq 1) "Find the $scope Inno uninstaller"
    Assert-Check (-not $script:calls[0].Unelevated) "Keep administrator rights for the $scope Inno uninstaller"
    Assert-Check (($script:calls[0].Arguments -join ' ') -eq $silentArguments) "Preserve silent $scope Inno arguments"
}

# Exercise NVM's actual invocation without reading or changing persistent environment variables.
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'steps\packages.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join "`n") }
$nvm = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-DevConfigNvm' }, $true)
$command = $nvm.Body.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-DevConfigCleanupCommand' }, $true)
$script:calls.Clear()
$path = 'C:\Fixture\NVM\unins000.exe'
& ([scriptblock]::Create($command.Extent.Text)) | Out-Null
Assert-Check (-not $script:calls[0].Unelevated) 'Keep administrator rights for the NVM uninstaller'
Assert-Check (($script:calls[0].Arguments -join ' ') -eq $silentArguments) 'Preserve silent NVM arguments'

$script:calls.Clear()
Invoke-DevConfigPackageCleanup -Ids 'Fixture.Package' -InnoUninstall $inno
Assert-Check ($script:calls.Count -eq 4) 'Run direct Inno cleanup and WinGet for both scopes'
Assert-Check (-not $script:calls[0].Unelevated -and -not $script:calls[2].Unelevated) 'Keep both direct Inno calls elevated during package cleanup'
Assert-Check ($script:calls[1].Unelevated -and $script:calls[1].Arguments -contains 'user') 'Keep generic user-scope WinGet cleanup unelevated'
Assert-Check (-not $script:calls[3].Unelevated -and $script:calls[3].Arguments -contains 'machine') 'Keep generic machine-scope WinGet cleanup elevated'

$script:calls.Clear()
$script:packageExit = $Script:DevConfigWingetNotFound
Assert-Check (Invoke-DevConfigPackageCleanup -Ids 'Fixture.Package' -InnoUninstall $inno -CheckOnly) 'Report an already-removed package as complete'
Assert-Check ($script:calls.Count -eq 2 -and @($script:calls | Where-Object { $_.File -ne 'winget.exe' -or $_.Arguments[0] -ne 'list' -or $_.Unelevated }).Count -eq 0) 'No-op checks neither uninstall nor launch limited-token tasks'
$script:packageExit = 0
Assert-Check (-not (Invoke-DevConfigPackageCleanup -Ids 'Fixture.Package' -CheckOnly)) 'Report an installed package as needing cleanup'

$script:calls.Clear()
$script:entry.Publisher = 'Unrelated publisher'
Invoke-DevConfigInnoCleanup @inno -Scope user
Assert-Check ($script:calls.Count -eq 0) 'Ignore an unrelated publisher'
$script:entry.Publisher = $inno.Publisher
$script:entry.UninstallString += ' /unexpected'
$message = $null
try { Invoke-DevConfigInnoCleanup @inno -Scope user } catch { $message = $_.Exception.Message }
Assert-Check ($message -like '*not a supported executable path*' -and $script:calls.Count -eq 0) 'Reject an uninstaller command containing extra arguments'
$script:entry.UninstallString = '"C:\Fixture\Visual Studio Code\unins000.exe"'
$script:commandFailure = $true
$message = $null
try { Invoke-DevConfigPackageCleanup -Ids 'Fixture.Package' -InnoUninstall $inno } catch { $message = $_.Exception.Message }
Assert-Check ($message -like '*Fixture.Package (user): Fixture uninstaller failed (1).*' -and $message -like '*Fixture.Package (machine): Fixture uninstaller failed (1).*') 'Surface failed uninstallers for both scopes'

Write-Host "Results: $script:passed passed, $script:failed failed."
if ($script:failed) { exit 1 }
