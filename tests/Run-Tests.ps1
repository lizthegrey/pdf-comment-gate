<#
Minimal, dependency-free test runner for Check-PdfComments.ps1.
No Pester required -- just PowerShell 7+ (or Windows PowerShell 5.1).

Usage:  pwsh -File tests/Run-Tests.ps1
Exit 0 if all pass, 1 otherwise.
#>
$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$script  = Join-Path (Split-Path -Parent $here) 'Check-PdfComments.ps1'
$fix     = Join-Path $here 'fixtures'
$pass = 0; $fail = 0

# Which engine runs the gate under test. Defaults to pwsh; CI sets GATE_PWSH to
# 'powershell' to exercise Windows PowerShell 5.1.
$gate = if ($env:GATE_PWSH) { $env:GATE_PWSH } else { 'pwsh' }

function Invoke-Gate {
    param([string]$Pdf)
    # capture stdout and the process exit code
    $out = & $gate -NoProfile -ExecutionPolicy Bypass -File $script $Pdf 2>&1 | Out-String
    return [pscustomobject]@{ Output = $out; Code = $LASTEXITCODE }
}

# Build the mojibake sentinels from code points so this file stays pure ASCII
# (Windows PowerShell 5.1 without a BOM would otherwise mangle literal glyphs).
$MojibakeChars = @(0xFFFD, 0x2020, 0x1C00) | ForEach-Object { [char]$_ }
function Test-NoMojibake { param([string]$Text)
    foreach ($ch in $MojibakeChars) { if ($Text.Contains($ch)) { return $false } }
    return $true
}

function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else            { $script:fail++; Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red }
}

Write-Host "clean.pdf (link-only -> must be CLEAN, exit 0)"
$r = Invoke-Gate (Join-Path $fix 'clean.pdf')
Check 'clean exit code 0'      ($r.Code -eq 0)                 "got $($r.Code)"
Check 'clean says CLEAN'       ($r.Output -match 'CLEAN')
Check 'clean does NOT flag'    ($r.Output -notmatch 'DIRTY')
Check 'link not treated as markup' ($r.Output -notmatch 'Link')

Write-Host "dirty-cr.pdf (uncompressed Text annot, CR continuation)"
$r = Invoke-Gate (Join-Path $fix 'dirty-cr.pdf')
Check 'dirty-cr exit code 1'   ($r.Code -eq 1)                 "got $($r.Code)"
Check 'dirty-cr says DIRTY'    ($r.Output -match 'DIRTY')
Check 'dirty-cr counts Text'   ($r.Output -match 'Text=1')
Check 'dirty-cr author'        ($r.Output -match 'Reviewer')
# The regression: the space split by \<CR> must rejoin, not corrupt the tail.
Check 'dirty-cr decodes cleanly' ($r.Output -match 'Remove before filing\.') $r.Output
Check 'dirty-cr no mojibake'   (Test-NoMojibake $r.Output) $r.Output

Write-Host "dirty-lf-compressed.pdf (Flate stream, LF continuation)"
$r = Invoke-Gate (Join-Path $fix 'dirty-lf-compressed.pdf')
Check 'dirty-lf exit code 1'   ($r.Code -eq 1)                 "got $($r.Code)"
Check 'dirty-lf found in stream' ($r.Output -match 'Text=1')
Check 'dirty-lf author'        ($r.Output -match 'Kathryn')
Check 'dirty-lf decodes cleanly' ($r.Output -match 'Delete this note\.') $r.Output

Write-Host ''
Write-Host "PASSED $pass, FAILED $fail" -ForegroundColor ($(if ($fail) { 'Red' } else { 'Green' }))
exit ($(if ($fail) { 1 } else { 0 }))
