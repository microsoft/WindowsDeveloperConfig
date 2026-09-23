[CmdletBinding()]
param()

& {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $bootstrap = (Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/windows-dev-config/bootstrap.ps1' -UseBasicParsing -TimeoutSec 60).TrimStart([char]0xFEFF)
    $signature = Get-AuthenticodeSignature -Content ([Text.Encoding]::Unicode.GetBytes($bootstrap)) -SourcePathOrExtension '.ps1'
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -ne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') {
        throw 'The setup bootstrap failed Microsoft signature verification. Setup was not started.'
    }
    & ([scriptblock]::Create($bootstrap)) -Action Full
}
