# SHA-256 of each non-PowerShell file that setup.ps1 downloads, hashed after converting CRLF to LF.
# These files can't carry a signature, so the one-line setup runs them only when they match this signed list.
# Update a hash whenever you change its file; src\tests\comfort-shell\unit.ps1 checks them.
@{
    'comfort-shell-bootstrap.sh' = '01e3e242a697b02db9cada0ae80161c926041be7cba5833a909ad56c07b9a68a'
}
