# SHA-256 of each non-PowerShell file that setup.ps1 downloads, hashed after converting CRLF to LF.
# These files can't carry a signature, so the one-line setup runs them only when they match this signed list.
# Update a hash whenever you change its file; src\tests\comfort-shell\unit.ps1 checks them.
@{
    'comfort-shell-bootstrap.sh' = '75074a758f3dfd38ed9f6cf67350dd0fc1a98c9106da2763b68931a12c6f1b91'
}
