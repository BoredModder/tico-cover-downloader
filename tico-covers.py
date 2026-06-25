#!/usr/bin/env python3
"""
tico-covers: auto-download SteamGridDB cover art for every game in your tico ROM folders.

It scans <RomsRoot>/<console>/ for ROM files, searches SteamGridDB for each game,
downloads the top portrait (box-art) cover, and saves it next to tico's other covers
using the ROM's base filename so tico picks it up automatically.

Stdlib only -- no pip install needed.

Usage:
    python tico-covers.py --roms "E:\\tico\\roms" --api-key YOUR_KEY
    setx STEAMGRIDDB_API_KEY YOUR_KEY   (then just: python tico-covers.py --roms "E:\\tico\\roms")

Get a free API key at https://www.steamgriddb.com/profile/preferences/api
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import urllib.error

API_BASE = "https://www.steamgriddb.com/api/v2"
# Portrait/box-art dimensions, in order of preference.
PORTRAIT_DIMS = "600x900,342x482,660x930"
# Image extensions tico-covers writes; used to detect an already-present cover.
COVER_EXTS = (".jpg", ".jpeg", ".png", ".webp")
# Extensions that are NOT game ROMs (assets, saves, patches, metadata, disc tracks).
SKIP_EXTS = {
    ".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp",            # images
    ".txt", ".nfo", ".dat", ".xml", ".json", ".jsonc", ".db",     # metadata
    ".sav", ".srm", ".state", ".st0", ".rtc",                     # saves
    ".ips", ".bps", ".ups", ".xdelta",                            # patches
    ".zip.bak", ".bak", ".tmp",                                   # junk
}
# Leading articles (No-Intro stores "Legend of Zelda, The") to flip back to the front.
ARTICLES = {"the", "a", "an", "le", "la", "les", "el", "los", "las", "die", "der", "das"}

# ----------------------------------------------------------------------------- helpers

def log(msg):
    print(msg, flush=True)


def clean_name(stem):
    """Turn a ROM base filename into a SteamGridDB search term."""
    name = re.sub(r"[\(\[].*?[\)\]]", " ", stem)   # drop (USA), [!], (Rev 1), (Disc 1)...
    name = name.replace("_", " ").replace(".", " ")
    name = re.sub(r"\s+", " ", name).strip()
    # No-Intro stores articles after the title: "Zelda, The - ..." -> "The Zelda - ..."
    m = re.match(r"^(.*?),\s+(" + "|".join(ARTICLES) + r")\b(.*)$", name, re.IGNORECASE)
    if m:
        name = f"{m.group(2)} {m.group(1)}{m.group(3)}".strip()
    return name


def http_get_json(url, api_key, retries=4):
    """GET a SteamGridDB API endpoint, with backoff on rate-limit / transient errors."""
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {api_key}",
        "Accept": "application/json",
        "User-Agent": "tico-covers/1.0",
    })
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise SystemExit("ERROR: SteamGridDB rejected the API key (401). "
                                 "Check --api-key / STEAMGRIDDB_API_KEY.")
            if e.code == 404:
                return None
            if e.code == 429 or e.code >= 500:
                wait = int(e.headers.get("Retry-After", 0) or 0) or (2 ** attempt)
                log(f"    rate-limited/{e.code}, waiting {wait}s...")
                time.sleep(wait)
                continue
            raise
        except urllib.error.URLError as e:
            time.sleep(2 ** attempt)
            if attempt == retries - 1:
                raise SystemExit(f"ERROR: network failure talking to SteamGridDB: {e}")
    return None


def search_game_id(term, api_key):
    url = f"{API_BASE}/search/autocomplete/{urllib.parse.quote(term)}"
    data = http_get_json(url, api_key)
    if not data or not data.get("success") or not data.get("data"):
        return None, None
    top = data["data"][0]
    return top.get("id"), top.get("name")


def best_cover_url(game_id, api_key):
    """Return the URL of the best portrait cover for a game id, or None."""
    base = f"{API_BASE}/grids/game/{game_id}"
    queries = [
        f"?types=static&nsfw=false&humor=false&dimensions={PORTRAIT_DIMS}",
        "?types=static&nsfw=false&humor=false",  # fallback: any static grid, filtered below
    ]
    for q in queries:
        data = http_get_json(base + q, api_key)
        if not data or not data.get("success"):
            continue
        grids = data.get("data") or []
        # Prefer true portrait (taller than wide), and prefer jpg/png over webp.
        def score(g):
            portrait = 1 if (g.get("height", 0) >= g.get("width", 1)) else 0
            jp = 1 if str(g.get("url", "")).lower().endswith((".jpg", ".jpeg", ".png")) else 0
            return (portrait, jp, g.get("upvotes", 0))
        grids = [g for g in grids if g.get("url")]
        if grids:
            grids.sort(key=score, reverse=True)
            return grids[0]["url"]
    return None


def download(url, dest):
    req = urllib.request.Request(url, headers={"User-Agent": "tico-covers/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = resp.read()
    tmp = dest + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, dest)


def existing_cover(covers_dir, stem):
    for ext in COVER_EXTS:
        p = os.path.join(covers_dir, stem + ext)
        if os.path.exists(p):
            return p
    return None


def resolve_covers_root(roms_root, override):
    """Pick where covers go, matching tico's layout (assets/covers or covers)."""
    if override:
        return override
    roms_root = os.path.normpath(roms_root)
    parent = os.path.dirname(roms_root) if os.path.basename(roms_root).lower() == "roms" else roms_root
    candidates = [os.path.join(parent, "assets", "covers"), os.path.join(parent, "covers")]
    for c in candidates:
        if os.path.isdir(c):
            return c
    return candidates[0]  # default to assets/covers (created on demand)


def is_disc_track(path, files_in_dir):
    """Skip a .bin/.img/.iso that is referenced by a sibling .cue (avoid duplicate covers)."""
    ext = os.path.splitext(path)[1].lower()
    if ext not in (".bin", ".img", ".iso"):
        return False
    stem = os.path.splitext(os.path.basename(path))[0].lower()
    return (stem + ".cue") in files_in_dir or (stem + ".m3u") in files_in_dir

# ------------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="Auto-download SteamGridDB covers for tico.")
    ap.add_argument("--roms", required=True, help=r"ROMs root, e.g. E:\tico\roms")
    ap.add_argument("--covers", help="Covers root (default: auto-detect tico layout)")
    ap.add_argument("--api-key", default=os.environ.get("STEAMGRIDDB_API_KEY"),
                    help="SteamGridDB API key (or set STEAMGRIDDB_API_KEY)")
    ap.add_argument("--consoles", help="Comma-separated console folders to limit to (default: all)")
    ap.add_argument("--delay", type=float, default=0.15, help="Seconds between API calls")
    ap.add_argument("--dry-run", action="store_true", help="Show what would happen, download nothing")
    args = ap.parse_args()

    if not args.api_key:
        raise SystemExit("ERROR: no API key. Pass --api-key or set STEAMGRIDDB_API_KEY.\n"
                         "Get one at https://www.steamgriddb.com/profile/preferences/api")
    if not os.path.isdir(args.roms):
        raise SystemExit(f"ERROR: ROMs root not found: {args.roms}")

    covers_root = resolve_covers_root(args.roms, args.covers)
    log(f"ROMs root   : {os.path.normpath(args.roms)}")
    log(f"Covers root : {covers_root}")
    log(f"Mode        : {'DRY RUN' if args.dry_run else 'download'}\n")

    only = {c.strip().lower() for c in args.consoles.split(",")} if args.consoles else None
    consoles = sorted(d for d in os.listdir(args.roms)
                      if os.path.isdir(os.path.join(args.roms, d))
                      and (only is None or d.lower() in only))
    if not consoles:
        raise SystemExit("No console subfolders found under the ROMs root.")

    stats = {"downloaded": 0, "skipped": 0, "not_found": 0, "errors": 0, "subfolder": 0}
    not_found = []

    for console in consoles:
        rom_dir = os.path.join(args.roms, console)
        covers_dir = os.path.join(covers_root, console)
        entries = sorted(os.listdir(rom_dir))
        files_lower = {e.lower() for e in entries}
        log(f"=== {console} ===")
        for entry in entries:
            full = os.path.join(rom_dir, entry)
            if os.path.isdir(full):
                stats["subfolder"] += 1
                log(f"  [subfolder] {entry}  (skipped -- v1 handles single-file ROMs)")
                continue
            ext = os.path.splitext(entry)[1].lower()
            if ext in SKIP_EXTS or not ext:
                continue
            if is_disc_track(full, files_lower):
                continue

            stem = os.path.splitext(entry)[0]
            have = existing_cover(covers_dir, stem)
            if have:
                stats["skipped"] += 1
                log(f"  [have] {stem}")
                continue

            term = clean_name(stem)
            try:
                gid, gname = search_game_id(term, args.api_key)
                time.sleep(args.delay)
                if not gid:
                    stats["not_found"] += 1
                    not_found.append(f"{console}/{stem}  (searched: {term})")
                    log(f"  [miss] {stem}  (no match for '{term}')")
                    continue
                url = best_cover_url(gid, args.api_key)
                time.sleep(args.delay)
                if not url:
                    stats["not_found"] += 1
                    not_found.append(f"{console}/{stem}  (game '{gname}' has no cover)")
                    log(f"  [no-art] {stem}  ('{gname}' -> no portrait cover)")
                    continue
                cover_ext = os.path.splitext(urllib.parse.urlparse(url).path)[1].lower() or ".jpg"
                if cover_ext not in COVER_EXTS:
                    cover_ext = ".jpg"
                dest = os.path.join(covers_dir, stem + cover_ext)
                if args.dry_run:
                    log(f"  [would get] {stem}  <- '{gname}'  {url}")
                    stats["downloaded"] += 1
                    continue
                os.makedirs(covers_dir, exist_ok=True)
                download(url, dest)
                stats["downloaded"] += 1
                log(f"  [ok] {stem}  <- '{gname}'")
            except KeyboardInterrupt:
                raise
            except Exception as e:  # keep going on a single bad game
                stats["errors"] += 1
                log(f"  [err] {stem}: {e}")

    log("\n--------------------------------------------------")
    log(f"Downloaded : {stats['downloaded']}")
    log(f"Skipped    : {stats['skipped']} (already had a cover)")
    log(f"Not found  : {stats['not_found']}")
    log(f"Subfolders : {stats['subfolder']} (not handled in v1)")
    log(f"Errors     : {stats['errors']}")
    if not_found:
        log("\nGames with no cover (fix these manually in tico, +Select -> Find Cover):")
        for nf in not_found:
            log(f"  - {nf}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("\nInterrupted.")
