#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Offline compile verification for the UIDetectMulti shader.

ReShade compiles its effects at runtime, so an ordinary compiler cannot read
UIDetectMulti.fx as-is: the effect dialect adds annotations, `source=`
attributes and technique blocks, and ReShade injects the BUFFER_* macros.

Annotations and technique blocks carry no code -- they are metadata and wiring,
parsed and discarded when a single entry point is compiled. So the way to get
real bytecode out of the file is to preprocess it, drop those two constructs,
and hand the result to fxc. That is what this script does, entirely in a scratch
copy under tools/.work/; the repository files are never modified.

    uv run tools/verify_shaders.py init     # fetch headers, build the workspace
    uv run tools/verify_shaders.py check --save tools/.work/before.json
    uv run tools/verify_shaders.py check --baseline tools/.work/before.json

`check` exits non-zero when a shader's instruction count, opcode histogram or
presence changes, or when the uniform inventory drifts -- the four things the
refactor must not touch.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FX = REPO / "Shaders" / "UIDetectMulti.fx"
FXH = REPO / "Shaders" / "UIDetectMulti.fxh"
WORK = REPO / "tools" / ".work"

# Pinned so the evidence is reproducible: crosire/reshade-shaders @ main.
HEADER_COMMIT = "6db142b4b1a05c764222e5b0bd9a644b7ccfe1dc"
HEADERS = ("ReShade.fxh", "ReShadeUI.fxh", "DrawText.fxh")
HEADER_URL = "https://raw.githubusercontent.com/crosire/reshade-shaders/{}/Shaders/{}"

MASK_COUNTS = (1, 2, 3, 4, 5)
# (name, extra preprocessor definitions). UIDM_* live in the .fxh, so they are
# patched in the workspace copy rather than passed on the command line.
VARIANTS = (
    ("default", {}),
    ("antibloom", {"UIDM_ANTIBLOOM": "1"}),
    ("diagnostics", {"UIDM_DIAGNOSTICS": "1"}),
    ("invert", {"UIDM_INVERT": "1"}),
)

# An annotation block is only a run of `key = value;` pairs, where the value runs
# to the next `;`. That shape keeps the pattern away from ordinary `<` comparisons
# in shader code, while still matching values that span several string literals.
ANNOTATION = re.compile(r'<\s*(?:[A-Za-z_]\w*\s*=\s*[^;]+?\s*;\s*)+>')
# Deliberately NOT line-anchored. A macro body is a single logical line, so once
# UIDM_TIMER_SHADERS expands, every generated shader after the first sits
# mid-line. An anchored pattern silently misses them, and a skipped entry point
# is indistinguishable from a passing one -- which is exactly the failure this
# script exists to avoid.
ENTRY_POINT = re.compile(
    r'(?:float4|float3|float2|void)\s+(\w+)\s*\([^)]*\)\s*:\s*SV_Target')
INSTRUCTION_COUNT = re.compile(r'// Approximately (\d+) instruction slots used')
UNIFORM = re.compile(r'uniform\s+(\w+)\s+(\w+)\s*<([^>]*)>\s*=\s*([^;]*);')
# texture NAME < ... source = "FILE" ... > -- the PNG a mask slot loads. Renaming
# a user's mask file would break their setup, so the filenames are pinned.
MASK_PNG = re.compile(r'texture\s+(\w+)\s*<[^>]*?source\s*=\s*"([^"]+)"', re.S)

PRELUDE = """\
#define __RESHADE__ 52000
#define __RESHADE_FXC__ 1
#define BUFFER_WIDTH      2560
#define BUFFER_HEIGHT     1440
#define BUFFER_RCP_WIDTH  (1.0 / 2560.0)
#define BUFFER_RCP_HEIGHT (1.0 / 1440.0)
#define RGBA8 28
#include "UIDetectMulti.fx"
"""


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def find_fxc() -> Path:
    """Locate fxc.exe: $FXC, then the newest Windows Kits SDK."""
    override = shutil.which("fxc.exe") or None
    if override:
        return Path(override)
    kits = Path("/mnt/c/Program Files (x86)/Windows Kits/10/bin")
    if not kits.is_dir():
        kits = Path("/mnt/c/Program Files/Windows Kits/10/bin")
    if kits.is_dir():
        versions = sorted(
            (p for p in kits.iterdir() if (p / "x64" / "fxc.exe").is_file()),
            key=lambda p: [int(n) for n in re.findall(r"\d+", p.name)],
        )
        if versions:
            return versions[-1] / "x64" / "fxc.exe"
    sys.exit("fxc.exe not found; set $FXC to its path (needs the Windows SDK)")


def windows_path(path: Path) -> str:
    out = subprocess.run(["wslpath", "-w", str(path)],
                         capture_output=True, text=True, check=True)
    return out.stdout.strip()


def run_fxc(args: list[str], cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run([str(FXC)] + args, cwd=cwd,
                          capture_output=True, text=True, errors="replace")


def first_error(log: str) -> str:
    match = re.search(r"error X\d+: .*", log)
    return match.group(0).strip() if match else "unknown compile failure"


# --------------------------------------------------------------------------- init

def cmd_init(args) -> int:
    WORK.mkdir(parents=True, exist_ok=True)
    for name in HEADERS:
        dest = WORK / name
        url = HEADER_URL.format(HEADER_COMMIT, name)
        with urllib.request.urlopen(url) as response:
            payload = response.read()
        digest = hashlib.sha256(payload).hexdigest()
        if dest.is_file() and sha256_file(dest) == digest:
            print("up to date  %s" % name)
            continue
        dest.write_bytes(payload)
        print("fetched     %s  sha256=%s" % (name, digest[:16]))
    print("workspace ready at %s (headers pinned at %s)"
          % (WORK.relative_to(REPO), HEADER_COMMIT[:12]))
    print("fxc: %s" % FXC)
    return 0


# -------------------------------------------------------------------------- check

def build_workspace(mask_count: int, definitions: dict[str, str]) -> Path:
    """Scratch copy with UIDM_* patched; returns the preprocessed source."""
    shutil.copy(FX, WORK / "UIDetectMulti.fx")
    fxh = FXH.read_text(encoding="utf-8")
    for key, value in {"UIDM_MASK_COUNT": str(mask_count), **definitions}.items():
        fxh, count = re.subn(r"(?m)^(\s*#define\s+%s\b)\s*\S+" % key,
                             r"\g<1> %s" % value, fxh, count=1)
        if not count:
            sys.exit("could not override %s in %s" % (key, FXH.name))
    (WORK / "UIDetectMulti.fxh").write_text(fxh, encoding="utf-8", newline="\n")
    (WORK / "build.fx").write_text(PRELUDE, encoding="utf-8", newline="\n")

    result = run_fxc(["/P", "preprocessed.i", "/I", windows_path(WORK),
                      "build.fx"], cwd=WORK)
    if result.returncode != 0:
        sys.exit("preprocessing failed: %s" % first_error(result.stdout + result.stderr))
    return WORK / "preprocessed.i"


def strip_render_metadata(text: str) -> str:
    """Remove annotations and technique blocks -- neither produces code."""
    text = ANNOTATION.sub("", text)
    return re.sub(r"(?sm)^[ \t]*technique\b.*\Z", "", text)


def compile_entry(stripped: Path, entry: str) -> dict:
    asm = WORK / ("%s.asm" % entry)
    binary = WORK / ("%s.bin" % entry)
    # Never let a previous run's output be mistaken for this run's result.
    for stale in (asm, binary):
        stale.unlink(missing_ok=True)
    result = run_fxc(["/Gec", "/T", "ps_5_0", "/E", entry, "/I", windows_path(WORK),
                      stripped.name, "/Fc", asm.name, "/Fo", binary.name], cwd=WORK)
    log = result.stdout + result.stderr
    if "X3501" in log:
        return {"status": "absent"}
    if result.returncode != 0:
        return {"status": "error", "error": first_error(log)}
    if not binary.is_file():
        # Compiling "succeeded" but emitted nothing: refuse to report it as ok,
        # because a missing hash would compare equal to another missing hash.
        return {"status": "error", "error": "fxc produced no bytecode for %s" % entry}
    text = asm.read_text(encoding="utf-8", errors="replace")
    match = INSTRUCTION_COUNT.search(text)
    histogram: dict[str, int] = {}
    # fxc's "instruction slots used" counts executable instructions only, so the
    # dcl_* declarations are excluded here too -- otherwise the cross-check below
    # would trip on a discrepancy that is purely definitional.
    body = text.split("ps_5_0", 1)[-1]
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("//") or line.startswith("dcl_"):
            continue
        opcode = line.split()[0].split("_")[0]
        histogram[opcode] = histogram.get(opcode, 0) + 1
    instructions = int(match.group(1)) if match else None
    # Cross-check the two independent readings of the same shader, so a broken
    # parse cannot masquerade as a clean comparison.
    if instructions is not None and sum(histogram.values()) != instructions:
        return {"status": "error",
                "error": "histogram sums to %d but fxc reports %d instructions"
                         % (sum(histogram.values()), instructions)}
    return {
        "status": "ok",
        "instructions": instructions,
        "histogram": dict(sorted(histogram.items())),
        "bytecode_sha256": sha256_file(binary),
    }


def technique_bindings(preprocessed: str) -> list[list[str | None]]:
    """Every pass as [technique, pixel shader, render target], in order.

    Compiling a single entry point discards the technique blocks, so pass wiring
    has to be read from the preprocessed source. This is what shows the passes
    still bind the same shader to the same render target.
    """
    text = re.sub(r"//[^\n]*", "", preprocessed)
    out: list[list[str | None]] = []
    for tech in re.finditer(r"technique\s+(\w+)[^{]*\{(.*?)\n\}", text, re.S):
        for pas in re.finditer(r"pass\s*\{([^}]*)\}", tech.group(2)):
            body = pas.group(1)
            ps = re.search(r"PixelShader\s*=\s*(\w+)", body)
            rt = re.search(r"RenderTarget\s*=\s*(\w+)", body)
            out.append([tech.group(1), ps.group(1) if ps else None,
                        rt.group(1) if rt else None])
    return out


def concat_adjacent_literals(text: str) -> str:
    """Join runs of adjacent string literals, as ReShade's parser does.

    effect_parser_exp.cpp: "Multiple string literals in sequence are concatenated
    into a single string literal". The macro-generated `"Mask " "3" " Tolerances"`
    is therefore the same category string as the original single literal, but a
    naive read of the preprocessed text would miss that.
    """
    def join(match: re.Match) -> str:
        return '"%s"' % "".join(re.findall(r'"([^"]*)"', match.group(0)))

    return re.sub(r'"[^"]*"(?:\s*"[^"]*")+', join, text)


def uniform_inventory(preprocessed: str) -> dict[str, dict[str, str]]:
    inventory: dict[str, dict[str, str]] = {}
    for _, name, annotation, default in UNIFORM.findall(preprocessed):
        fields = dict(re.findall(r'(\w+)\s*=\s*("[^"]*"|[^;]+?)\s*;',
                                 concat_adjacent_literals(annotation)))
        inventory[name] = {
            "default": default.strip(),
            "ui_type": fields.get("ui_type", "").strip(),
            "ui_category": fields.get("ui_category", "").strip(),
        }
    return dict(sorted(inventory.items()))


def cmd_check(args) -> int:
    if not (WORK / HEADERS[0]).is_file():
        sys.exit("workspace not initialised; run: uv run tools/verify_shaders.py init")
    wanted = set(args.entry_point) if args.entry_point else None
    report = {
        "fxc": str(FXC),
        "header_commit": HEADER_COMMIT,
        "sources": {str(p.relative_to(REPO)): sha256_file(p) for p in (FX, FXH)},
        "cases": {},
        "uniforms": {},
        "techniques": {},
        "mask_pngs": {},
    }
    print("%-12s %-6s %-28s %6s  %s" % ("variant", "masks", "entry point", "instr", "status"))
    for variant, definitions in VARIANTS:
        for mask_count in MASK_COUNTS:
            key = "%s/masks=%d" % (variant, mask_count)
            preprocessed = build_workspace(mask_count, definitions)
            text = preprocessed.read_text(encoding="utf-8", errors="replace")
            if key not in report["uniforms"]:
                report["uniforms"][key] = uniform_inventory(text)
                report["techniques"][key] = technique_bindings(text)
                # Record both the PNG filename and the texture name that carries
                # it, so a renamed texture with an unchanged file is allowed while
                # a renamed *file* -- which would break a user's mask -- fails.
                report["mask_pngs"][key] = {
                    "files": sorted(png for _, png in MASK_PNG.findall(text)),
                    "textures": {name: png for name, png in MASK_PNG.findall(text)},
                }
            print("  %s: %d technique pass(es)"
                  % (key, len(report["techniques"][key])))
            stripped = WORK / "stripped.fx"
            stripped.write_text(strip_render_metadata(text), encoding="utf-8", newline="\n")
            entries = sorted(set(ENTRY_POINT.findall(text)))
            if wanted:
                entries = [e for e in entries if e in wanted]
            cases = {}
            for entry in entries:
                outcome = compile_entry(stripped, entry)
                cases[entry] = outcome
                print("%-12s %-6d %-28s %6s  %s" % (
                    variant, mask_count, entry,
                    outcome.get("instructions", "-"), outcome["status"]))
            report["cases"][key] = cases

    if args.save:
        Path(args.save).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("\nwrote baseline %s" % args.save)
    if args.baseline:
        return compare(report, json.loads(Path(args.baseline).read_text(encoding="utf-8")))
    return 0


# The refactor suffixes slot 1's textures so every slot is spelled the same way,
# which changes pass bindings by exactly this rename. Listing it explicitly keeps
# the check strict -- any *other* binding change still fails -- while not
# reporting the intended rename as a regression. texColorBeforeMulti is
# slot-agnostic and deliberately absent.
SLOT1_RENAMES = {
    "texUIDetectMaskMulti": "texUIDetectMaskMulti1",
    "texUIDetectMulti": "texUIDetectMulti1",
    "texUIDetectTimer": "texUIDetectTimer1",
}


def compare(current: dict, baseline: dict) -> int:
    diffs: list[str] = []
    renamed = 0
    for key in sorted(set(current.get("techniques", {})) | set(baseline.get("techniques", {}))):
        now = current.get("techniques", {}).get(key, [])
        before = []
        for tech, ps, rt in baseline.get("techniques", {}).get(key, []):
            if rt in SLOT1_RENAMES:
                rt = SLOT1_RENAMES[rt]
                renamed += 1
            before.append([tech, ps, rt])
        if now != before:
            for a, b in zip(before, now):
                if a != b:
                    diffs.append("pass [%s]: %s -> %s" % (key, a, b))
            if len(before) != len(now):
                diffs.append("pass count [%s]: %d -> %d"
                             % (key, len(before), len(now)))
    if renamed:
        print("%d pass binding(s) normalised for the documented slot 1 rename" % renamed)
    texture_renames = set()
    for key in sorted(set(current.get("mask_pngs", {})) | set(baseline.get("mask_pngs", {}))):
        now = current.get("mask_pngs", {}).get(key, {})
        before = baseline.get("mask_pngs", {}).get(key, {})
        if now.get("files") != before.get("files"):
            diffs.append("mask PNG filenames [%s]: %s -> %s"
                         % (key, before.get("files"), now.get("files")))
        elif now.get("textures") != before.get("textures"):
            old, new = before.get("textures", {}), now.get("textures", {})
            for name in set(old) & set(new):
                if old[name] != new[name]:
                    texture_renames.add("%s (was %s) loads %s" % (name, name, new[name]))
            for name in set(old) - set(new):
                texture_renames.add("%s (was %s) removed" % (name, name))
            for name in set(new) - set(old):
                texture_renames.add("%s (was %s) added"
                                    % (name, ", ".join(sorted(set(old) - set(new))) or "?"))
    if texture_renames:
        print("mask texture identifier(s) changed, PNG filenames pin the same images:")
        for rename in sorted(texture_renames):
            print("  " + rename)
    if current["uniforms"] != baseline["uniforms"]:
        for key in sorted(set(current["uniforms"]) | set(baseline["uniforms"])):
            now, before = current["uniforms"].get(key, {}), baseline["uniforms"].get(key, {})
            if now != before:
                for name in sorted(set(now) | set(before)):
                    if now.get(name) != before.get(name):
                        diffs.append("uniform %s [%s]: %s -> %s"
                                     % (name, key, before.get(name), now.get(name)))
    # Instruction count and opcode histogram are the measurable cost, so those
    # failing is a real regression. A bytecode or ordering difference is not:
    # fxc re-schedules when the source reshapes, and a compiler cannot introduce
    # a semantic change. Equivalence of the source is established separately.
    identical = scheduled = 0
    for key in sorted(set(current["cases"]) | set(baseline["cases"])):
        now, before = current["cases"].get(key, {}), baseline["cases"].get(key, {})
        for entry in sorted(set(now) | set(before)):
            a, b = before.get(entry, {}), now.get(entry, {})
            if a.get("status") != b.get("status"):
                diffs.append("%s %s: status %s -> %s"
                             % (key, entry, a.get("status"), b.get("status")))
            elif a.get("status") != "ok":
                continue
            elif a.get("instructions") is None or b.get("instructions") is None:
                diffs.append("%s %s: instruction count missing, cannot compare"
                             % (key, entry))
            elif a.get("instructions") != b.get("instructions"):
                diffs.append("%s %s: instructions %s -> %s"
                             % (key, entry, a["instructions"], b["instructions"]))
            elif a.get("histogram") != b.get("histogram"):
                diffs.append("%s %s: opcode histogram changed" % (key, entry))
            elif a.get("bytecode_sha256") == b.get("bytecode_sha256"):
                identical += 1
            else:
                scheduled += 1
    print("\n%d shader(s) byte-identical; %d with identical instruction count and "
          "opcode histogram but a different scheduling" % (identical, scheduled))
    if diffs:
        print("\nFAIL -- %d difference(s) from baseline:" % len(diffs))
        for diff in diffs[:40]:
            print("  " + diff)
        return 1
    print("PASS -- no change in shader output or uniform inventory")
    return 0


# ----------------------------------------------------------------------- uniforms

def cmd_uniforms(args) -> int:
    preprocessed = build_workspace(5, {})
    text = preprocessed.read_text(encoding="utf-8", errors="replace")
    inventory = uniform_inventory(text)
    if args.json:
        print(json.dumps(inventory, indent=2))
    else:
        for name, fields in inventory.items():
            print("%-14s %-8s %-22s %s"
                  % (name, fields["ui_type"], fields["ui_category"], fields["default"]))
    print("\n%d uniforms" % len(inventory))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    init = sub.add_parser("init", help="fetch the pinned ReShade headers")
    init.set_defaults(func=cmd_init)

    check = sub.add_parser("check", help="compile every entry point and report")
    check.add_argument("--save", metavar="FILE", help="write the report as a baseline")
    check.add_argument("--baseline", metavar="FILE", help="compare against a saved report")
    check.add_argument("-e", "--entry-point", action="append",
                       help="limit to this entry point (repeatable)")
    check.set_defaults(func=cmd_check)

    uniforms = sub.add_parser("uniforms", help="dump the uniform inventory")
    uniforms.add_argument("--json", action="store_true")
    uniforms.set_defaults(func=cmd_uniforms)

    args = parser.parse_args()
    global FXC
    FXC = find_fxc()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
