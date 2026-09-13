#!/usr/bin/env python3
# build_skillhub_zip.py -- build a SkillHub-compliant distribution package.
#
# SkillHub (skillhub.cn, iflytek) rejects BINARY files on upload -- the
# validator's message names them ("禁止上传二进制文件"), even though the written
# whitelist (docs/07-skill-protocol.md section 8.3) lists .png/.jpg/.svg. The
# written whitelist lags the implementation; empirically only text files pass
# (tidy-data's text-only upload passed; a png in ours was rejected).
# So the hub package ships text files ONLY.
#
# The GitHub repo keeps the FULL kit (vendored fonts, PDF report, Quarto
# template); this script derives a whitelist-compliant zip for the hub:
#   SKILL.md + root docs + references/ + scripts/ + assets/ (showcase png)
#
# Empirical note: the written whitelist has NO .R entry, and SkillHub
# explicitly rejected scripts/verify_snippets.R by name (round 3) -- while the
# sister skill tidy-data once passed with .R files. Validator is inconsistent
# across uploads; treat .R as NOT shippable. Hub package = text docs only.
#
# Usage: python scripts/build_skillhub_zip.py   (from anywhere)
# Output: dist/data-cleaning-skillhub.zip

import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "dist", "data-cleaning-skillhub.zip")

ALLOWED_EXT = {".md", ".txt", ".json", ".yaml", ".yml"}
# .py/.R excluded too: .py packaging tooling is meaningless without the repo,
# and .R got named in a rejection. Hub package = pure documentation.
EXCLUDE_DIRS = {"_extensions", "templates", "examples", "output", ".git",
                "dist", ".quarto", ".github", "scripts"}
# root files to ship. LICENSE is excluded: the hub validator rejects license
# files (it bans them despite tidy-data having passed with one earlier --
# validator inconsistent). The MIT license lives in the GitHub repo; hub
# listings link there via README.
ROOT_FILES = ["SKILL.md", "README.md", "README.en.md", "CHANGELOG.md",
              "test-prompts.json"]
def collect():
    """Yield (archive_path, source_path) pairs for the compliant package."""
    for name in ROOT_FILES:
        p = os.path.join(ROOT, name)
        if os.path.isfile(p):
            yield name, p
    for dirpath, dirnames, filenames in os.walk(ROOT):
        rel_dir = os.path.relpath(dirpath, ROOT).replace(os.sep, "/")
        # prune excluded dirs at any depth (top-level and nested)
        keep = []
        for d in dirnames:
            rel = os.path.normpath(os.path.join(rel_dir, d)).replace(os.sep, "/")
            if rel.split("/")[0] not in EXCLUDE_DIRS and rel not in EXCLUDE_DIRS:
                keep.append(d)
        dirnames[:] = keep
        if rel_dir == ".":
            continue
        for fn in filenames:
            src = os.path.join(dirpath, fn)
            rel = os.path.relpath(src, ROOT).replace(os.sep, "/")
            ext = os.path.splitext(fn)[1].lower()
            if ext not in ALLOWED_EXT:
                print("  skip (type):", rel)
                continue
            yield rel, src
def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    entries = list(collect())
    total = 0
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for arc, src in sorted(entries):
            size = os.path.getsize(src)
            if size > 1024 * 1024:
                print("FAIL: single file over 1MB:", arc)
                sys.exit(1)
            total += size
            z.write(src, arc)
            print("  +", arc, "({} KB)".format(size // 1024))
    n = len(entries)
    print("\nPackage: {} ({} files, {} KB total)".format(
        os.path.relpath(OUT, ROOT), n, total // 1024))
    if n > 100:
        print("FAIL: over 100 files")
        sys.exit(1)
    if total > 10 * 1024 * 1024:
        print("FAIL: over 10MB total")
        sys.exit(1)
    print("SkillHub limits OK (single<=1MB, total<=10MB, files<=100).")


if __name__ == "__main__":
    main()
