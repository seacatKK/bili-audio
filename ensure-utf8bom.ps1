# Ensure a .ps1 file is UTF-8 with BOM, then parse-check it.
# Windows PowerShell 5.1 decodes BOM-less files as ANSI/GBK, which corrupts any
# non-ASCII (e.g. Chinese) script and produces bogus syntax errors.
# This helper is intentionally ASCII-only, so it can never break itself.
# Usage: powershell -NoProfile -File ensure-utf8bom.ps1 <path> [<path2> ...]
param(
    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)][string[]]$Path
)

foreach ($p in $Path) {
    $full = (Resolve-Path -LiteralPath $p).Path
    $bytes = [IO.File]::ReadAllBytes($full)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($hasBom) {
        Write-Host "BOM ok    : $full"
    } else {
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        [IO.File]::WriteAllText($full, $text, (New-Object Text.UTF8Encoding($true)))
        Write-Host "BOM added : $full"
    }
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$null, [ref]$errs)
    if ($errs) {
        Write-Host "  SYNTAX ERRORS:"
        $errs | ForEach-Object { Write-Host ("    line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) }
    } else {
        Write-Host "  syntax ok"
    }
}
