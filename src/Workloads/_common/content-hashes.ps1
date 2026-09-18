$Script:DevConfigWorkloadContentHashes = @{
    '_common\ai-catalog.psd1' = '56b455424d8900a6b03f4854d535bf683a17d714d2032eee314a89d84f33526a'
    'cuda\smoke.cu' = '6252383bda8856daa14c4f315961e17d4de3bdba1cba6bf4c09a5d0aa52a2a6f'
    'dotnet\configuration.winget' = 'cba2c6873cee7eff241b6d7698d773f8575cfc60a6e9d7dbb8986f4ecea5c048'
    'go\configuration.winget' = '552e6fe17baa47df8d1f429735cdd718bdb61b052a86cc47e8f8c6c2cd22232c'
    'intel-ai\openvino-smoke.py' = '0b71b5f5351dd7536c6352dc02ffd523fa89f2fa60a23ff27d45fd3e8f9c1326'
    'intel-ai\sycl-smoke.cpp' = '6ed0361d8374bcae060b84469b3b167738f016abc9f3b46ba5f19ad870bd74b7'
    'java\configuration.winget' = 'f36edd7ca81b9389ba490505892d6ca5068d5942a249a98f3997356300b8447e'
    'php\configuration.winget' = '34e040193202a8cb0e4cadcefaf5bd678e9fb775bf5ad428d94c78f326604c06'
    'powershell\configuration.winget' = 'b86d0cc7dea26309a14478e5a94304dc9b037fe32220bdc83da8318ed60e220d'
    'python\configuration.winget' = 'bfec7eaad24ba3c5913e7713dafef31d6ac62c53005cc3fb6688db33dbf66f13'
    'pytorch\smoke.py' = 'f28b8ca06e0a2832684f1342626c74904c13d575ce96282f86cf66f44d3eba68'
    'pytorch\triton-smoke.py' = 'a2d2a538b1b30315f249753ccad68d6977bf85d711e3e3541c52ae16268814f4'
    'pytorch\xpu-smoke.py' = '7cba1b04e7ecbce0c24a9188ff847cd3c2fd9792810b5fd4324728ad21786c50'
    'rocm\hip-smoke.cpp' = 'ece1ed905b3afc7ceb918cc3ff751d624b8d681444b1c507a74cfef3d326034d'
    'rust\configuration.winget' = 'ea58a4b6dfe1aedcc1af4674b69dd376609c67140ee6a60dba0060edb266c701'
    'sql\configuration.winget' = '99472e573c10316a17be12d45da834e22be4b1b774afc5c15fdefe3d63bb98e7'
    'typescript\configuration.winget' = '826e1755d85798e376baa00a9891c58fd2dd6da67d0f54486ad957202ee7c8b1'
    'winforms\configuration.winget' = '39de8aee958e1e4989fd5b484a45a36537a7f8cb72dc966fa3afa4d0e8b9e34f'
    'winui\configuration.winget' = '4b3851372222328c758ac12320a7032f276c45e9d3cc9c498969956d1f5b65ad'
}

function Get-DevConfigCanonicalWorkloadHash {
    param([Parameter(Mandatory)] [string] $Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $stream = [IO.MemoryStream]::new()
    try {
        for ($index = 0; $index -lt $bytes.Length; $index++) {
            if ($bytes[$index] -eq 13 -and
                $index + 1 -lt $bytes.Length -and
                $bytes[$index + 1] -eq 10) {
                $stream.WriteByte(10)
                $index++
            } else {
                $stream.WriteByte($bytes[$index])
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

function Assert-DevConfigWorkloadContent {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $WorkloadsRoot)

    $root = (Get-Item -LiteralPath $WorkloadsRoot -Force).FullName.TrimEnd('\')
    $actualFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force |
        Where-Object { $_.Extension -ne '.ps1' })
    $actualPaths = @($actualFiles | ForEach-Object {
        $_.FullName.Substring($root.Length).TrimStart([char]'\')
    })

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Script:DevConfigWorkloadContentHashes.GetEnumerator()) {
        $path = Join-Path $root $entry.Key
        if (-not (Test-Path -LiteralPath $path)) {
            [void]$failures.Add("$($entry.Key) [missing]")
            continue
        }
        $actualHash = Get-DevConfigCanonicalWorkloadHash -Path $path
        if ($actualHash -ne $entry.Value) {
            [void]$failures.Add("$($entry.Key) [SHA-256 mismatch]")
        }
    }
    foreach ($path in $actualPaths) {
        if (-not $Script:DevConfigWorkloadContentHashes.ContainsKey($path)) {
            [void]$failures.Add("$path [not declared by signed content manifest]")
        }
    }

    if ($failures.Count -gt 0) {
        throw "The Workloads content manifest failed verification: $($failures -join '; ')"
    }
    Write-Host "  Verified $($actualFiles.Count) non-PowerShell workload files." -ForegroundColor DarkGray
}
