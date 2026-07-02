#!/usr/bin/env python3
"""Generate the test PDFs used by Run-Tests.ps1.

These are deliberately tiny, hand-built PDFs. They exercise the exact code paths
that mattered on the real filing that motivated this tool:

  * clean.pdf            - a Link annotation only (a live TOC/hyperlink). MUST be
                           reported CLEAN: the gate must not flag legitimate links.
  * dirty-cr.pdf         - an uncompressed Text (sticky-note) annotation whose
                           /Contents is UTF-16BE and is split by a backslash+CR
                           line-continuation mid-character (the real-world bug).
  * dirty-lf-compressed  - a Text annotation living inside a FlateDecode stream,
                           with a backslash+LF continuation, to exercise both the
                           in-process inflate path and LF-style continuations.

Run:  python3 make-fixtures.py
"""
import struct
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent / "fixtures"
OUT.mkdir(exist_ok=True)


def utf16be_literal(text, split_after=None, eol=b"\r"):
    """Return the *bytes* of a PDF literal string (including parentheses) holding
    `text` as UTF-16BE with a leading BOM. If split_after is set, a backslash+EOL
    line-continuation is inserted in the MIDDLE of the character at that index,
    i.e. between its two UTF-16 bytes -- reproducing the wrap that corrupted the
    real document. Bytes that are special in literal strings are escaped."""
    raw = b"\xfe\xff" + text.encode("utf-16-be")
    if split_after is not None:
        # byte position between the two bytes of the target char (after BOM)
        pos = 2 + split_after * 2 + 1
        raw = raw[:pos] + b"\\" + eol + raw[pos:]
    # escape (, ), \ -- but leave our intentional continuation backslash alone.
    # Simplest correct approach: escape everything, then un-escape the marker.
    out = bytearray(b"(")
    i = 0
    while i < len(raw):
        b = raw[i]
        if b == 0x5C and i + 1 < len(raw) and raw[i + 1] in (0x0D, 0x0A):
            out += b"\\" + bytes([raw[i + 1]])  # keep continuation as-is
            i += 2
            continue
        if b in (0x28, 0x29, 0x5C):
            out += b"\\" + bytes([b])
        else:
            out += bytes([b])
        i += 1
    out += b")"
    return bytes(out)


def build_pdf(objects):
    """objects: list of raw bytes for objects 1..N. Returns a byte-valid-enough PDF.
    Our scanner does not parse xref, so a loose trailer is fine."""
    buf = bytearray(b"%PDF-1.5\n")
    for n, body in enumerate(objects, start=1):
        buf += f"{n} 0 obj\n".encode() + body + b"\nendobj\n"
    buf += b"trailer<</Root 1 0 R>>\n%%EOF\n"
    return bytes(buf)


def flate_stream(inner):
    comp = zlib.compress(inner)
    return (b"<</Filter/FlateDecode/Length %d>>\nstream\n" % len(comp)
            + comp + b"\nendstream")


# --- clean.pdf : link annotation only -------------------------------------
clean = build_pdf([
    b"<</Type/Catalog/Pages 2 0 R>>",
    b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
    b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Annots[4 0 R]>>",
    b"<</Type/Annot/Subtype/Link/Rect[72 700 300 720]"
    b"/A<</S/URI/URI(https://example.com/toc)>>>>",
])
(OUT / "clean.pdf").write_bytes(clean)

# --- dirty-cr.pdf : uncompressed Text annot, CR continuation ---------------
contents_cr = utf16be_literal("Remove before filing.", split_after=8, eol=b"\r")
annot_cr = (b"<</Type/Annot/Subtype/Text/Rect[100 500 120 520]"
            b"/T(\xfe\xff\x00R\x00e\x00v\x00i\x00e\x00w\x00e\x00r)"
            b"/Contents " + contents_cr + b">>")
dirty_cr = build_pdf([
    b"<</Type/Catalog/Pages 2 0 R>>",
    b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
    b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Annots[4 0 R]>>",
    annot_cr,
])
(OUT / "dirty-cr.pdf").write_bytes(dirty_cr)

# --- dirty-lf-compressed.pdf : Text annot inside a Flate stream, LF cont. --
contents_lf = utf16be_literal("Delete this note.", split_after=6, eol=b"\n")
annot_lf = (b"<</Type/Annot/Subtype/Text/Rect[100 400 120 420]"
            b"/T(\xfe\xff\x00K\x00a\x00t\x00h\x00r\x00y\x00n)"
            b"/Contents " + contents_lf + b">>")
buf = bytearray(b"%PDF-1.5\n")
buf += b"1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n"
buf += b"2 0 obj\n<</Type/Pages/Kids[3 0 R]/Count 1>>\nendobj\n"
buf += b"3 0 obj\n<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Annots[4 0 R]>>\nendobj\n"
buf += b"4 0 obj\n" + flate_stream(annot_lf) + b"\nendobj\n"
buf += b"trailer<</Root 1 0 R>>\n%%EOF\n"
(OUT / "dirty-lf-compressed.pdf").write_bytes(bytes(buf))

for p in ("clean.pdf", "dirty-cr.pdf", "dirty-lf-compressed.pdf"):
    print("wrote", (OUT / p))
