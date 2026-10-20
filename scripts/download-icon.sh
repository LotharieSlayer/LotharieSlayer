#!/usr/bin/env bash
#
# download-icon.sh - fetch Iconify icons into assets/ for use in README.md
#
# The api.iconify.design SVG endpoint currently returns 404 for every icon,
# so this script builds the SVGs from the official @iconify-json packages on
# jsDelivr instead (same data, same rendering: height, colour, flips).
#
# Examples:
#   ./scripts/download-icon.sh simple-icons:abletonlive
#   ./scripts/download-icon.sh simple-icons:python akar-icons:typescript-fill
#   ./scripts/download-icon.sh --color '#ff0000' --height 32 simple-icons:rust
#   ./scripts/download-icon.sh 'https://api.iconify.design/simple-icons:python.svg?color=%23AF80FD&height=26'
#   ./scripts/download-icon.sh --readme README.md      # repair every remote icon URL in the README
#
set -euo pipefail

DEF_COLOR="#AF80FD"
DEF_HEIGHT=26
DEF_OUT="assets"

COLOR="$DEF_COLOR"
HEIGHT="$DEF_HEIGHT"
OUT="$DEF_OUT"
FORCE=0
REFRESH=0
README_FILE=""

usage() {
  cat <<'EOF'
Download Iconify icons into assets/.

Usage:
  scripts/download-icon.sh [options] <icon> [<icon>...]
  scripts/download-icon.sh [options] --readme [FILE]

Icons:
  prefix:name                      e.g. simple-icons:abletonlive
  https://api.iconify.design/...   a full Iconify SVG URL (query string honoured)

Options:
  --color <hex>     icon colour, with or without '#'   (default: #AF80FD)
  --height <px>     rendered height in px              (default: 26)
  --out <dir>       output directory                   (default: assets)
  --readme [FILE]   download every api.iconify.design URL found in FILE
                    (defaults to README.md)
  -f, --force       overwrite files that already exist
  --refresh         re-download the cached icon sets
  -h, --help        show this help

Files are written as <prefix>-<name>.svg. When --color/--height differ from the
defaults, they are baked into the name too (e.g. simple-icons-rust-ff0000-h32.svg).

Requires: bash, curl, python3
EOF
}

# ---------------------------------------------------------------- parse args --
ICONS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    --color)      [ $# -ge 2 ] || { echo "error: --color needs a value" >&2; exit 2; }; COLOR="$2"; shift 2 ;;
    --height)     [ $# -ge 2 ] || { echo "error: --height needs a value" >&2; exit 2; }; HEIGHT="$2"; shift 2 ;;
    --out)        [ $# -ge 2 ] || { echo "error: --out needs a value" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --readme)     if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then README_FILE="$2"; shift 2; else README_FILE="README.md"; shift; fi ;;
    -f|--force)   FORCE=1; shift ;;
    --refresh)    REFRESH=1; shift ;;
    --)           shift; while [ $# -gt 0 ]; do ICONS+=("$1"); shift; done ;;
    -*)           echo "error: unknown option '$1' (see --help)" >&2; exit 2 ;;
    *)            ICONS+=("$1"); shift ;;
  esac
done

if [ -z "$README_FILE" ] && [ ${#ICONS[@]} -eq 0 ]; then
  usage
  exit 2
fi

command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 2; }
command -v curl    >/dev/null 2>&1 || { echo "error: curl is required"    >&2; exit 2; }

# ---------------------------------------------------------------- run python --
ICON_COLOR="$COLOR" ICON_HEIGHT="$HEIGHT" ICON_OUT="$OUT" \
ICON_FORCE="$FORCE" ICON_REFRESH="$REFRESH" ICON_README="$README_FILE" \
python3 - ${ICONS[@]+"${ICONS[@]}"} <<'PY'
import json, os, re, subprocess, sys

DEF_COLOR  = "#AF80FD"
DEF_HEIGHT = 26

COLOR   = os.environ["ICON_COLOR"].strip()
HEIGHT  = os.environ["ICON_HEIGHT"].strip()
OUT     = os.environ["ICON_OUT"]
FORCE   = os.environ["ICON_FORCE"] == "1"
REFRESH = os.environ["ICON_REFRESH"] == "1"
README  = os.environ["ICON_README"]

errors = 0
def fail(msg):
    global errors
    errors += 1
    print(f"  \u2717 {msg}", file=sys.stderr)

# colour: accept 'af80fd', '#AF80FD', '%23AF80FD'
COLOR = COLOR.replace("%23", "#")
if not re.fullmatch(r"#?[0-9a-fA-F]{6}", COLOR):
    print(f"error: invalid colour '{COLOR}' (expected e.g. #AF80FD)", file=sys.stderr); sys.exit(2)
COLOR = "#" + COLOR.lstrip("#").upper()

try:
    HEIGHT = int(HEIGHT)
    assert HEIGHT > 0
except Exception:
    print(f"error: invalid height '{os.environ['ICON_HEIGHT']}'", file=sys.stderr); sys.exit(2)

# ------------------------------------------------------------------- targets --
URL_RE  = re.compile(r"https?://api\.iconify\.design/([A-Za-z0-9-]+):([A-Za-z0-9._-]+)\.svg(?:\?[^\"'\s)>]*)?")
REF_RE  = re.compile(r"^([A-Za-z0-9-]+):([A-Za-z0-9._-]+)$")

def from_query(q):
    """-> (colour, height) pulled out of an iconify query string, else defaults."""
    c, h = COLOR, HEIGHT
    for part in q.split("&"):
        if "=" not in part:
            continue
        k, v = part.split("=", 1)
        if k == "color" and v:
            v = v.replace("%23", "#")
            if re.fullmatch(r"#?[0-9a-fA-F]{6}", v):
                c = "#" + v.lstrip("#").upper()
        elif k == "height" and v.isdigit() and int(v) > 0:
            h = int(v)
    return c, h

targets = []          # (prefix, name, colour, height)
seen = set()

def add(prefix, name, color, height):
    key = (prefix, name, color, height)
    if key not in seen:
        seen.add(key)
        targets.append(key)

if README:
    if not os.path.isfile(README):
        print(f"error: no such file: {README}", file=sys.stderr); sys.exit(2)
    text = open(README, encoding="utf-8").read()
    found = 0
    for m in URL_RE.finditer(text):
        c, h = from_query(m.group(0).split("?", 1)[1]) if "?" in m.group(0) else (COLOR, HEIGHT)
        add(m.group(1), m.group(2), c, h)
        found += 1
    if not targets:
        print(f"{README}: no api.iconify.design URLs found - nothing to do")
        sys.exit(0)
    print(f"{README}: {found} remote icon URL(s) found")
else:
    for arg in sys.argv[1:]:
        m = URL_RE.fullmatch(arg)
        if m:
            c, h = from_query(arg.split("?", 1)[1]) if "?" in arg else (COLOR, HEIGHT)
            add(m.group(1), m.group(2), c, h)
            continue
        m = REF_RE.match(arg)
        if not m:
            print(f"error: '{arg}' is not an icon (expected prefix:name or an api.iconify.design URL)",
                  file=sys.stderr); sys.exit(2)
        add(m.group(1), m.group(2), COLOR, HEIGHT)

# ------------------------------------------------------------------ icon sets --
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "iconify-json")
os.makedirs(CACHE, exist_ok=True)
sets = {}

def load_set(prefix):
    if prefix in sets:
        return sets[prefix]
    path = os.path.join(CACHE, prefix + ".json")
    if REFRESH or not os.path.isfile(path):
        url = f"https://cdn.jsdelivr.net/npm/@iconify-json/{prefix}@latest/icons.json"
        tmp = path + ".part"
        if subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", tmp, url]).returncode != 0:
            if os.path.exists(tmp):
                os.remove(tmp)
            raise RuntimeError(f"cannot download icon set '{prefix}'")
        os.replace(tmp, path)
    data = json.load(open(path, encoding="utf-8"))
    sets[prefix] = data
    return data

def resolve(prefix, name):
    """-> (body, w, h, left, top, hflip, vflip, rot) or None if the icon is unknown."""
    data = load_set(prefix)
    icons, aliases = data.get("icons", {}), data.get("aliases", {})
    hflip = vflip = False
    rot = 0
    chain = set()
    while True:
        if name in chain:
            return None
        chain.add(name)
        if name in icons:
            body = icons[name]["body"]
            w = icons[name].get("width",  data.get("width",  24))
            h = icons[name].get("height", data.get("height", 24))
            left = icons[name].get("left", 0)
            top  = icons[name].get("top",  0)
            rot = (rot + int(icons[name].get("rotate", 0) or 0)) % 4
            break
        if name in aliases:
            a = aliases[name]
            hflip ^= a.get("hFlip", False)
            vflip ^= a.get("vFlip", False)
            rot = (rot + int(a.get("rotate", 0) or 0)) % 4
            name = a["parent"]
            continue
        return None
    return body, w, h, left, top, hflip, vflip, rot

def filename(prefix, name, color, height):
    base = f"{prefix}-{name}"
    if color.upper() == DEF_COLOR.upper() and height == DEF_HEIGHT:
        return base + ".svg"
    tag = color.lstrip("#").lower()
    if height != DEF_HEIGHT:
        tag += f"-h{height}"
    return f"{base}-{tag}.svg"

def build_svg(prefix, name, color, height):
    res = resolve(prefix, name)
    if res is None:
        raise LookupError(f"{prefix}:{name} does not exist (browse: https://iconify.design/icons/)")
    body, w, h, left, top, hflip, vflip, rot = res

    body = body.replace("currentColor", color)
    tf = []
    if rot:
        tf.append(f"rotate({rot * 90} {left + w / 2:g} {top + h / 2:g})")
    if hflip:
        tf.append(f"translate({2 * left + w:g} 0) scale(-1 1)")
    if vflip:
        tf.append(f"translate(0 {2 * top + h:g}) scale(1 -1)")
    if tf:
        body = f'<g transform="{" ".join(tf)}">{body}</g>'

    out_w = round(height * w / h)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{left:g} {top:g} {w:g} {h:g}" '
            f'width="{out_w}" height="{height}" fill="{color}">{body}</svg>\n')

# --------------------------------------------------------------------- write --
os.makedirs(OUT, exist_ok=True)
downloaded = skipped = 0

for prefix, name, color, height in targets:
    rel = os.path.join(OUT, filename(prefix, name, color, height))
    if os.path.exists(rel) and not FORCE:
        print(f"  = {rel} (exists, --force to overwrite)")
        skipped += 1
        continue
    try:
        svg = build_svg(prefix, name, color, height)
    except LookupError as e:
        fail(str(e))
        continue
    except Exception as e:
        fail(f"{prefix}:{name} - {e}")
        continue
    with open(rel, "w", encoding="utf-8") as f:
        f.write(svg)
    print(f"  \u2713 {rel}")
    downloaded += 1

print(f"{downloaded} downloaded, {skipped} skipped, {errors} failed")
sys.exit(1 if errors else 0)
PY
