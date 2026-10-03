[CmdletBinding()]
param(
    [string] $PowerShell7Path = (Get-Command pwsh.exe -ErrorAction Stop).Source
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$source = Join-Path $PSScriptRoot '..\..\windows-dev-config'
$signedHelper = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\windows-dev-config\steps\_security.ps1')).Path
$tokens = $null
$parseErrors = $null
$engine = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'dev-config.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors -join [Environment]::NewLine) }
$bootstrap = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'bootstrap.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors -join [Environment]::NewLine) }
$bootstrapFunction = $bootstrap.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-CalmOsBootstrap'
}, $true)
$launcher = $bootstrap.Find({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$launcher'
}, $true)

function Get-StartupCode {
    param($Block, [string] $Before)
    $statements = @()
    foreach ($statement in $Block.Statements) {
        if ($statement.Extent.Text -like $Before) { return ($statements -join [Environment]::NewLine) }
        $statements += $statement.Extent.Text
    }
    throw "Startup boundary not found: $Before"
}

$entries = [ordered]@{
    Engine = Get-StartupCode $engine.EndBlock '$stepsDir =*'
    Bootstrap = Get-StartupCode $bootstrapFunction.Body.EndBlock 'function Invoke-DevConfigWebRequest*'
    Elevation = Get-StartupCode $launcher.Right.Expression.ScriptBlock.EndBlock '[[]Net.ServicePointManager]*'
}
$shells = @(
    (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'),
    $PowerShell7Path
)
$powerShell7Home = & $PowerShell7Path -NoProfile -NonInteractive -Command '$PSHOME'
if ($LASTEXITCODE -ne 0 -or -not $powerShell7Home) { throw 'Could not resolve the PowerShell 7 installation.' }
$probe = @'
$expected = Join-Path $PSHOME 'Modules'
foreach ($name in @('Get-AuthenticodeSignature', 'Get-FileHash', 'Get-Acl')) {
    $command = Get-Command $name -ErrorAction Stop
    if (-not $command.Module.Path.StartsWith("$expected\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "$name loaded from the wrong shell: $($command.Module.Path)"
    }
}
if ($env:PSModulePath -notlike '*DevConfig-CustomModules*') { throw 'Custom module paths were lost.' }
$code = [IO.File]::ReadAllText($SignedHelper)
$signature = Get-AuthenticodeSignature -Content ([Text.Encoding]::Unicode.GetBytes($code)) -SourcePathOrExtension '.ps1'
if ($signature.Status -ne 'Valid' -or
    $signature.SignerCertificate.Subject -ne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') {
    throw "Signed fixture was not verified: $($signature.Status)"
}
$tampered = Get-AuthenticodeSignature -Content ([Text.Encoding]::Unicode.GetBytes("# modified`r`n$code")) -SourcePathOrExtension '.ps1'
if ($tampered.Status -eq 'Valid') { throw 'Tampered content passed verification.' }
$unsigned = Get-AuthenticodeSignature -Content ([Text.Encoding]::Unicode.GetBytes("'unsigned'")) -SourcePathOrExtension '.ps1'
if ($unsigned.Status -eq 'Valid') { throw 'Unsigned content passed verification.' }
if (-not (Get-FileHash -LiteralPath $SignedHelper).Hash) { throw 'File hashing failed.' }
$null = Get-Acl -LiteralPath $SignedHelper
Write-Output "PASS $($PSVersionTable.PSVersion): native modules, signed/tampered/unsigned content, hash and ACL"
'@
$work = (New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) "DevConfig-ModuleChecks-$([guid]::NewGuid().ToString('N'))")).FullName
$originalModulePath = $env:PSModulePath
try {
    # Match Start-Process inheriting PowerShell 7's built-in modules ahead of Windows PowerShell's.
    $env:PSModulePath = "$powerShell7Home\Modules;$originalModulePath;$work\DevConfig-CustomModules"
    foreach ($shell in $shells) {
        foreach ($entry in $entries.GetEnumerator()) {
            $scriptPath = Join-Path $work 'probe.ps1'
            $scriptText = 'param([string] $SignedHelper)' + [Environment]::NewLine + $entry.Value + [Environment]::NewLine + $probe
            [IO.File]::WriteAllText($scriptPath, $scriptText)
            $stdout = Join-Path $work 'stdout.txt'
            $stderr = Join-Path $work 'stderr.txt'
            $process = Start-Process -FilePath $shell -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned',
                '-File', "`"$scriptPath`"", '-SignedHelper', "`"$signedHelper`""
            ) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            if ($process.ExitCode -ne 0) {
                throw "$($entry.Key) failed in $shell ($($process.ExitCode)):`n$([IO.File]::ReadAllText($stderr))"
            }
            $output = [IO.File]::ReadAllText($stdout).Trim()
            if ($output -notlike 'PASS *') { throw "$($entry.Key) produced no success result: $output" }
            Write-Host "$($entry.Key): $output"
        }
    }
} finally {
    $env:PSModulePath = $originalModulePath
    Remove-Item -LiteralPath $work -Recurse -Force
}
