<#
.SYNOPSIS
  Verifies setup signatures and protects installed files from non-elevated writes.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-DevConfigProtectedPath {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $Ancestor
    )

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Setup cannot use a junction or symbolic link: $Path"
    }

    $owners = @('S-1-5-18', 'S-1-5-32-544')
    if ($Ancestor) {
        # Windows drive roots can be owned by TrustedInstaller.
        $owners += 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    }
    $acl = Get-Acl -LiteralPath $item.FullName
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $owners) {
        throw "Setup requires an Administrator/SYSTEM-owned directory tree: $Path"
    }
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(), 0)
    if ($null -eq $descriptor.DiscretionaryAcl) {
        throw "Setup cannot use a path without access restrictions: $Path"
    }

    $unsafeRights = [int][Security.AccessControl.FileSystemRights]'Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    # Generic access masks are not named by FileSystemRights.
    $unsafeRights = $unsafeRights -bor 0x10000000
    if (-not $Ancestor) {
        $unsafeRights = $unsafeRights -bor [int][Security.AccessControl.FileSystemRights]::Write -bor 0x40000000
    }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($Ancestor -and ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
        if ($rule.AccessControlType -eq 'Allow' -and
            $rule.IdentityReference.Value -notin $owners -and
            ($rule.FileSystemRights -band $unsafeRights)) {
            throw "Setup cannot use a path writable or replaceable by non-administrators: $Path"
        }
    }
}

function Assert-DevConfigProtectedTree {
    param(
        [Parameter(Mandatory)] [string] $Directory
    )

    $root = Get-Item -LiteralPath $Directory -Force
    if (-not $root.PSIsContainer) {
        throw "Setup requires a directory: $Directory"
    }
    for ($parent = $root.Parent; $null -ne $parent; $parent = $parent.Parent) {
        Assert-DevConfigProtectedPath -Path $parent.FullName -Ancestor
    }

    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($root.FullName)
    while ($pending.Count -gt 0) {
        $path = $pending.Pop()
        Assert-DevConfigProtectedPath -Path $path
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer) {
            foreach ($child in Get-ChildItem -LiteralPath $path -Force) {
                $pending.Push($child.FullName)
            }
        }
    }
}

function New-DevConfigProtectedDirectory {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($Path -notmatch '^[A-Za-z]:\\[^:]+$') {
        throw 'Setup requires a local directory, not a drive root or network path.'
    }
    $Path = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parent = [IO.Directory]::GetParent($Path)
    if (-not $parent -or -not $parent.Exists) {
        throw "The parent directory must already exist: $Path"
    }
    for ($ancestor = $parent; $null -ne $ancestor; $ancestor = $ancestor.Parent) {
        Assert-DevConfigProtectedPath -Path $ancestor.FullName -Ancestor
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')) {
            $rights = if ($sid -eq 'S-1-5-32-545') { 'ReadAndExecute' } else { 'FullControl' }
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new($sid), $rights,
                'ContainerInherit, ObjectInherit', 'None', 'Allow'
            ))
        }
        # Set ownership and permissions atomically to prevent unprivileged writes.
        if ($PSVersionTable.PSEdition -eq 'Core') {
            [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($Path), $acl)
        } else {
            [IO.Directory]::CreateDirectory($Path, $acl) | Out-Null
        }
    }

    Assert-DevConfigProtectedTree -Directory $Path
    return $Path
}

function Assert-DevConfigMicrosoftSigned {
    param(
        [Parameter(Mandatory)] [string] $Directory
    )

    $Directory = (Get-Item -LiteralPath $Directory -Force).FullName
    $scripts = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Filter '*.ps1' -Force)
    if ($scripts.Count -eq 0) {
        throw "The Calm OS payload in '$Directory' contains no PowerShell files."
    }

    $failures = @()
    foreach ($script in $scripts) {
        $signature = Get-AuthenticodeSignature -LiteralPath $script.FullName
        $relativePath = $script.FullName.Substring($Directory.Length).TrimStart([char]'\')
        if ($signature.Status -ne 'Valid') {
            $failures += "$relativePath [$($signature.Status)]"
        } elseif (-not $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -ne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') {
            $failures += "$relativePath [unexpected signer]"
        }
    }

    if ($failures.Count -gt 0) {
        $details = ($failures | ForEach-Object { "    $_" }) -join [Environment]::NewLine
        throw "The Calm OS payload in '$Directory' failed Microsoft signature verification:$([Environment]::NewLine)$details$([Environment]::NewLine)Setup was not started. Use -AllowUnsigned only for development."
    }

    Write-Host "  Verified $($scripts.Count) Microsoft-signed PowerShell files." -ForegroundColor DarkGray
}
