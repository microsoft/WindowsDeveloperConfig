$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')

$architecture = Get-DevConfigArchitecture
$plan = Resolve-CudaInstallPlan -Architecture $architecture -WindowsBuild (Get-WindowsBuildNumber)
$nvcc = Get-CudaNvccPath -ToolkitVersion $plan.ToolkitVersion
$vsDevCmd = Get-VsDevCmdPath -Architecture $architecture
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) "devconfig-cuda-probe-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporary -Force | Out-Null
try {
    $executable = Join-Path $temporary 'cuda-smoke.exe'
    $compile = Get-CudaKernelCompileCommand `
        -Architecture $architecture `
        -VsDevCmd $vsDevCmd `
        -Nvcc $nvcc `
        -Source (Join-Path $PSScriptRoot '..\..\Workloads\cuda\smoke.cu') `
        -Output $executable
    & $env:ComSpec /d /s /c $compile *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "CUDA probe compilation failed with exit code $LASTEXITCODE."
    }
    $result = (& $executable 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $result -ne 'CUDA_KERNEL_READY') {
        throw "CUDA probe kernel failed with exit code $LASTEXITCODE and output '$result'."
    }
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'CUDA ready'
