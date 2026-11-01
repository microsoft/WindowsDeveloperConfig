$Script:DevConfigWorkloadContentHashes = @{
    'cuda\smoke.cu' = '6252383bda8856daa14c4f315961e17d4de3bdba1cba6bf4c09a5d0aa52a2a6f'
    'intel-ai\openvino-smoke.py' = '0b71b5f5351dd7536c6352dc02ffd523fa89f2fa60a23ff27d45fd3e8f9c1326'
    'intel-ai\sycl-smoke.cpp' = '6ed0361d8374bcae060b84469b3b167738f016abc9f3b46ba5f19ad870bd74b7'
    'pytorch\smoke.py' = 'f28b8ca06e0a2832684f1342626c74904c13d575ce96282f86cf66f44d3eba68'
    'pytorch\triton-smoke.py' = 'a2d2a538b1b30315f249753ccad68d6977bf85d711e3e3541c52ae16268814f4'
    'pytorch\xpu-smoke.py' = '7cba1b04e7ecbce0c24a9188ff847cd3c2fd9792810b5fd4324728ad21786c50'
    'rocm\hip-smoke.cpp' = 'ece1ed905b3afc7ceb918cc3ff751d624b8d681444b1c507a74cfef3d326034d'
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
        Where-Object { $_.Extension -notin @('.ps1', '.psd1') })
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
