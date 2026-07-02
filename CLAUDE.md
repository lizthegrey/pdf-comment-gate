# CLAUDE.md — pdf-comment-gate

Repo-specific guidance. This is a small, self-contained tool; keep it that way.

## What it is
A **report-only** pre-filing gate that detects review comments / markup
annotations left in a PDF. It prints findings and sets an exit code. It runs on
stock Windows.

## Invariants — do not break these
- **Never modify the PDF.** Detection only. Auto-stripping an official document is
  out of scope by design; remediation is a human step in Acrobat.
- **Never flag `/Link` annotations.** Interactive TOC / cross-reference links are
  legitimate and some workflows require them; flagging them is a bug.
- **No dependencies.** Pure .NET / PowerShell only — no modules (no Pester, no
  iTextSharp), no Acrobat, no Ghostscript. It must run on **Windows PowerShell
  5.1** and **PowerShell 7+**.
- **Exit codes are the contract:** `0` = clean, `1` = markup found, `2` = error /
  no PDFs. Callers depend on these.

## Gotchas in the parser
- Annotations may live in **Flate-compressed object streams**; the script inflates
  all streams in-process (zlib header skipped for `DeflateStream`) before scanning.
- Comment text is often **UTF-16BE with a BOM**, and long literal strings get
  **wrapped with backslash + CR/LF line-continuations** that must decode to
  *nothing*. The string-token regex uses `\\[\s\S]` (not `\\.`) so an escaped
  char across a newline is captured; the decoder drops `\`+EOL. There is a test
  fixture for each. Don't "simplify" these away.

## Testing
```powershell
pwsh -File tests/Run-Tests.ps1        # dependency-free; must stay green
```
Fixtures are regenerated (not hand-edited) via:
```bash
python3 tests/make-fixtures.py
```
If you change parsing/decoding, add or extend a fixture rather than only asserting
on the current output.

## Repo conventions
- Commits in this repo use committer `Liz Fong-Jones <liz@endharassment.net>`
  (set as repo-local git config).
- Licensed **CC0 1.0** (public-domain dedication). Keep new files license-clean.
- Keep `.ps1` sources **pure ASCII** so Windows PowerShell 5.1 (no BOM) parses
  them correctly; build any non-ASCII sentinels from code points at runtime.
- On release: add a `CHANGELOG.md` section and tag `vX.Y.Z` (SemVer). CI must be
  green on Linux pwsh + Windows pwsh + Windows PowerShell 5.1 before tagging.
