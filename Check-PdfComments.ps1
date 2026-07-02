<#
.SYNOPSIS
    Pre-filing gate: detects review comments / markup annotations left inside PDFs
    before they are e-filed (e.g. to PACER/ECF).

.DESCRIPTION
    Scans one or more PDFs for markup annotations (sticky-note comments, highlights,
    strikeouts, redaction marks, etc.) -- the kind of internal work-product that is
    supposed to be gone before a document is filed. Reports what was found, who
    authored the comments, and the comment text.

    Pure .NET only: no external modules, no Acrobat, no Ghostscript. Handles both
    uncompressed annotation objects and Flate-compressed object streams by inflating
    them in-process.

    It intentionally does NOT modify the PDF. Auto-stripping annotations from an
    official document is its own hazard. When it finds problems it exits non-zero so
    it can be wired into a pre-upload check / hook.

    REMEDIATION -- remove ONLY the comments, keep interactive links:
    Do NOT use "Sanitize Document" or "Flatten annotations" -- both destroy the
    internal TOC / cross-reference links that courts require to stay active.
    Instead, in Acrobat Pro, do one of:
      * Comment pane: open Tools > Comment, select all comments in the list,
        right-click > Delete. This removes markup but leaves Link annotations and
        bookmarks intact; or
      * Tools > Redact > Remove Hidden Information, tick ONLY "Comments and Markup"
        (leave "Links, Actions and JavaScript" unticked), then Remove.
    Re-run this gate afterward to confirm CLEAN.

.PARAMETER Path
    One or more PDF files, directories, or wildcards. Directories are scanned for *.pdf.

.PARAMETER Recurse
    Recurse into subdirectories when a directory is given.

.PARAMETER IncludeMetadata
    Also report document Author metadata (informational; does not by itself fail the gate).

.PARAMETER Quiet
    Suppress the per-comment detail; print only the summary line per file.

.EXAMPLE
    .\Check-PdfComments.ps1 .\ready-to-file.pdf
    # exit code 0 = clean, 1 = comments/markup found, 2 = read error

.EXAMPLE
    Get-ChildItem .\Filings -Filter *.pdf | .\Check-PdfComments.ps1 -Recurse

.NOTES
    Heuristic. It will not see annotations inside an encrypted PDF, and exotic
    string encodings may render imperfectly, but presence-detection is reliable for
    normal Acrobat / Word / print-to-PDF output. Treat a "CLEAN" result as "no
    markup found", not a guarantee the file is safe to file.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('FullName')]
    [string[]]$Path,

    [switch]$Recurse,
    [switch]$IncludeMetadata,
    [switch]$Quiet
)

begin {
    # Markup/review annotation subtypes that should never survive to a filing.
    # NB: /Link is deliberately excluded -- hyperlinks (mailto:, URLs) are legitimate.
    $MarkupSubtypes = @(
        'Text', 'FreeText', 'Highlight', 'Underline', 'StrikeOut', 'Squiggly',
        'Caret', 'Ink', 'Stamp', 'FileAttachment', 'Sound', 'Redact',
        'Line', 'Square', 'Circle', 'Polygon', 'PolyLine'
    )
    $Latin1 = [System.Text.Encoding]::GetEncoding('ISO-8859-1')
    $anyFindings = $false
    $hadError = $false

    # Inflate a Flate (zlib) stream. PDF /FlateDecode is zlib-wrapped (2-byte header +
    # trailing Adler-32); .NET DeflateStream wants raw DEFLATE, so we skip the 2-byte
    # header. Fall back to raw (skip 0) just in case, and swallow anything that isn't
    # actually Flate (images, LZW, etc.).
    function Expand-FlateStream {
        param([byte[]]$Data)
        foreach ($skip in 2, 0) {
            if ($Data.Length -le $skip) { continue }
            try {
                $ms = New-Object System.IO.MemoryStream(, $Data)
                $ms.Position = $skip
                $ds = New-Object System.IO.Compression.DeflateStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
                $out = New-Object System.IO.MemoryStream
                $ds.CopyTo($out)
                $ds.Dispose(); $ms.Dispose()
                if ($out.Length -gt 0) { return $out.ToArray() }
            } catch { }
        }
        return $null
    }

    # Decode a PDF string token (including its () or <> delimiters) to readable text.
    # Handles literal-string escapes, hex strings, and UTF-16 BOMs (FE FF / FF FE).
    function ConvertFrom-PdfString {
        param([string]$Token)
        if ([string]::IsNullOrWhiteSpace($Token)) { return '' }
        $t = $Token.Trim()
        [byte[]]$bytes = @()

        if ($t.StartsWith('<')) {
            $hex = ($t.Trim('<', '>')) -replace '[^0-9A-Fa-f]', ''
            if ($hex.Length % 2 -ne 0) { $hex += '0' }
            $list = New-Object System.Collections.Generic.List[byte]
            for ($i = 0; $i -lt $hex.Length; $i += 2) {
                $list.Add([Convert]::ToByte($hex.Substring($i, 2), 16))
            }
            $bytes = $list.ToArray()
        }
        elseif ($t.StartsWith('(')) {
            $inner = $t.Substring(1, $t.Length - 2)
            $list = New-Object System.Collections.Generic.List[byte]
            for ($i = 0; $i -lt $inner.Length; $i++) {
                $c = $inner[$i]
                if ($c -eq '\' -and $i + 1 -lt $inner.Length) {
                    $n = $inner[$i + 1]
                    $ni = [int]$n
                    if ($ni -eq 13 -or $ni -eq 10) {
                        # backslash + EOL (CR / LF / CRLF) is a line continuation:
                        # per the PDF spec it emits NO character. Both the backslash and
                        # the EOL are discarded (otherwise a stray byte corrupts UTF-16 pairing).
                        $i++
                        if ($ni -eq 13 -and ($i + 1) -lt $inner.Length -and [int]$inner[$i + 1] -eq 10) { $i++ }
                    }
                    else { switch ($n) {
                        'n' { $list.Add(10); $i++ }
                        'r' { $list.Add(13); $i++ }
                        't' { $list.Add(9);  $i++ }
                        'b' { $list.Add(8);  $i++ }
                        'f' { $list.Add(12); $i++ }
                        '(' { $list.Add(40); $i++ }
                        ')' { $list.Add(41); $i++ }
                        '\' { $list.Add(92); $i++ }
                        default {
                            if ($n -match '[0-7]') {
                                $oct = ''; $j = $i + 1
                                while ($j -lt $inner.Length -and $oct.Length -lt 3 -and $inner[$j] -match '[0-7]') {
                                    $oct += $inner[$j]; $j++
                                }
                                # high-order overflow is ignored per spec (mod 256),
                                # so mask to a byte -- \400..\777 must not throw.
                                $list.Add([byte]([Convert]::ToInt32($oct, 8) -band 0xFF)); $i = $j - 1
                            } else {
                                $list.Add([byte][char]$n); $i++
                            }
                        }
                    } }
                } else {
                    $list.Add([byte][char]$c)
                }
            }
            $bytes = $list.ToArray()
        }
        else { return $t }

        if ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) {
            return ([System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)).Trim()
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
            return ([System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)).Trim()
        } else {
            return ($Latin1.GetString($bytes)).Trim()
        }
    }

    function Get-DecodedPdfText {
        param([byte[]]$Bytes)
        $raw = $Latin1.GetString($Bytes)
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append($raw)
        # Inflate every stream and append the decoded text so annotations living in
        # compressed object streams are visible to the searches below.
        $streamRx = [regex]'(?s)stream\r?\n(.*?)endstream'
        foreach ($m in $streamRx.Matches($raw)) {
            $chunk = $m.Groups[1].Value
            # trim a single trailing EOL that belongs to the "endstream" keyword line
            $chunkBytes = $Latin1.GetBytes($chunk)
            $inflated = Expand-FlateStream -Data $chunkBytes
            if ($inflated) { [void]$sb.Append("`n"); [void]$sb.Append($Latin1.GetString($inflated)) }
        }
        return $sb.ToString()
    }

    function Test-OnePdf {
        param([string]$File)
        try {
            $bytes = [System.IO.File]::ReadAllBytes($File)
        } catch {
            Write-Host "ERROR  " -ForegroundColor Red -NoNewline
            Write-Host "$File -- cannot read: $($_.Exception.Message)"
            $script:hadError = $true
            return
        }

        $text = Get-DecodedPdfText -Bytes $bytes

        # Count markup subtypes.
        $found = [ordered]@{}
        foreach ($st in $MarkupSubtypes) {
            $c = ([regex]::Matches($text, "/Subtype\s*/$st\b")).Count
            if ($c -gt 0) { $found[$st] = $c }
        }

        # A PDF string token: literal (...) with escapes, or hex <...>.
        # \\[\s\S] (not \\.) so a backslash-escape captures ANY next char, incl. a
        # CR/LF line-continuation, without depending on Singleline mode.
        $strTok = '(?:\((?:[^()\\]|\\[\s\S])*\)|<[0-9A-Fa-f\s]+>)'
        $comments = foreach ($m in [regex]::Matches($text, "/Contents\s*($strTok)")) {
            $v = ConvertFrom-PdfString $m.Groups[1].Value
            if ($v) { $v }
        }
        $authors = foreach ($m in [regex]::Matches($text, "/T\s*($strTok)")) {
            $v = ConvertFrom-PdfString $m.Groups[1].Value
            if ($v) { $v }
        }
        $authors = $authors | Sort-Object -Unique

        $markupCount = ($found.Values | Measure-Object -Sum).Sum
        if (-not $markupCount) { $markupCount = 0 }

        if ($markupCount -gt 0) {
            $script:anyFindings = $true
            Write-Host "DIRTY  " -ForegroundColor Red -NoNewline
            Write-Host $File
            $summary = ($found.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
            Write-Host "       markup annotations: $summary"
            if ($found.Contains('Redact')) {
                Write-Host "       !! Redact annotations present -- redactions may NOT be burned in. Apply them (Tools > Redact > Apply) before filing." -ForegroundColor Yellow
            }
            if (-not $Quiet) {
                if ($authors) { Write-Host "       authors: $($authors -join '; ')" -ForegroundColor Cyan }
                $i = 0
                foreach ($cm in $comments) {
                    $i++
                    $one = ($cm -replace '\s+', ' ').Trim()
                    if ($one.Length -gt 200) { $one = $one.Substring(0, 197) + '...' }
                    Write-Host "       [$i] $one"
                }
            }
        } else {
            Write-Host "CLEAN  " -ForegroundColor Green -NoNewline
            Write-Host "$File (no markup annotations found)"
        }

        if ($IncludeMetadata) {
            $auth = [regex]::Match($text, "/Author\s*($strTok)")
            if ($auth.Success) {
                $a = ConvertFrom-PdfString $auth.Groups[1].Value
                if ($a) { Write-Host "       (info) document Author metadata: $a" -ForegroundColor DarkGray }
            }
        }
    }

    # Expand a single path (file / directory / wildcard) into concrete .pdf files.
    # Test-Path based so it behaves identically on Windows PowerShell 5.1 and 7.
    function Expand-OnePath {
        param([string]$p)
        if (Test-Path -LiteralPath $p -PathType Container) {
            Get-ChildItem -LiteralPath $p -Filter *.pdf -File -Recurse:$Recurse -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName }
        }
        elseif (Test-Path -LiteralPath $p -PathType Leaf) {
            if ([System.IO.Path]::GetExtension($p) -ieq '.pdf') { (Get-Item -LiteralPath $p).FullName }
            else { Write-Host "SKIP    $p -- not a .pdf" -ForegroundColor DarkGray }
        }
        else {
            # Not a literal path -- try wildcard expansion, then recurse per match.
            $matched = @(Resolve-Path -Path $p -ErrorAction SilentlyContinue)
            if ($matched.Count -eq 0) {
                Write-Host "ERROR   $p -- path not found" -ForegroundColor Red
                $script:hadError = $true
            } else {
                foreach ($m in $matched) { Expand-OnePath -p $m.Path }
            }
        }
    }

    $collected = New-Object System.Collections.Generic.List[string]
}

process {
    # Collect raw paths whether they arrive positionally or through the pipeline.
    if ($Path) { foreach ($p in $Path) { [void]$collected.Add($p) } }
}

end {
    # Fallback: if the process block did not run (some hosts skip it when a
    # ValueFromPipeline parameter is bound positionally via -File), use $Path.
    if ($collected.Count -eq 0 -and $Path) { foreach ($p in $Path) { [void]$collected.Add($p) } }

    $targets = $collected | ForEach-Object { Expand-OnePath -p $_ } | Sort-Object -Unique
    if (-not $targets) {
        Write-Host "No PDF files to check." -ForegroundColor Yellow
        exit 2
    }
    foreach ($t in $targets) { Test-OnePdf -File $t }

    Write-Host ''
    if ($hadError -and -not $anyFindings) {
        Write-Host "Completed with read errors." -ForegroundColor Yellow
        exit 2
    }
    if ($anyFindings) {
        Write-Host "RESULT: markup/comments found -- DO NOT FILE until sanitized." -ForegroundColor Red
        exit 1
    }
    Write-Host "RESULT: no markup annotations detected." -ForegroundColor Green
    exit 0
}
