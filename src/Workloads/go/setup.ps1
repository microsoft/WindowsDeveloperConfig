[CmdletBinding()]
param()

& {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    $env:PSModulePath = "$PSHOME\Modules;$env:PSModulePath"

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $payloadRef = 'fe21c03a486a1076c425720c1ebe4e25404e0e6b'
    $bootstrap = (Invoke-RestMethod -Uri "https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/$payloadRef/windows-dev-config/bootstrap.ps1" -UseBasicParsing -TimeoutSec 60).TrimStart([char]0xFEFF)
    $signature = Get-AuthenticodeSignature -Content ([Text.Encoding]::Unicode.GetBytes($bootstrap)) -SourcePathOrExtension '.ps1'
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -ne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') {
        throw 'The setup bootstrap failed Microsoft signature verification. Setup was not started.'
    }
    & ([scriptblock]::Create($bootstrap)) -Ref $payloadRef -Workload go -Action Full
}
