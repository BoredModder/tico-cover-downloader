#!/usr/bin/env python3
"""
tico-covers: auto-download SteamGridDB cover art for every game in your tico ROM folders.

It scans <RomsRoot>/<console>/ for ROM files, searches SteamGridDB for each game,
downloads the top portrait (box-art) cover, and saves it next to tico's other covers
using the ROM's base filename so tico picks it up automatically.

Downloads run concurrently (a thread pool) so large libraries finish quickly.
Stdlib only -- no pip install needed.

Usage:
    python tico-covers.py --roms "E:\\tico\\roms" --api-key YOUR_KEY
    setx STEAMGRIDDB_API_KEY YOUR_KEY   (then just: python tico-covers.py --roms "E:\\tico\\roms")

Get a free API key at https://www.steamgriddb.com/profile/preferences/api
"""
import argparse
import json
import os
import sys
import re
import threading
import time
import urllib.parse
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed

API_BASE = "https://www.steamgriddb.com/api/v2"
# Portrait/box-art dimensions, in order of preference.
PORTRAIT_DIMS = "600x900,342x482,660x930"
# Image extensions tico-covers writes; used to detect an already-present cover.
COVER_EXTS = (".jpg", ".jpeg", ".png", ".webp")
# Extensions that are NOT game ROMs (assets, saves, patches, metadata).
SKIP_EXTS = {
    ".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp",            # images
    ".txt", ".nfo", ".dat", ".xml", ".json", ".jsonc", ".db",     # metadata
    ".sav", ".srm", ".state", ".st0", ".rtc",                     # saves
    ".ips", ".bps", ".ups", ".xdelta", ".bak", ".tmp",           # patches / junk
}
DISC_TRACK_EXTS = (".bin", ".img", ".iso")
# Leading articles (No-Intro stores "Legend of Zelda, The") to flip back to the front.
ARTICLES = ["the", "a", "an", "le", "la", "les", "el", "los", "las", "die", "der", "das"]

_print_lock = threading.Lock()


def log(msg):
    with _print_lock:
        print(msg, flush=True)

# ----------------------------------------------------------------------------- helpers

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
                time.sleep(wait)
                continue
            raise
        except urllib.error.URLError:
            time.sleep(2 ** attempt)
    return None


def search_game(term, api_key):
    url = f"{API_BASE}/search/autocomplete/{urllib.parse.quote(term)}"
    data = http_get_json(url, api_key)
    if not data or not data.get("success") or not data.get("data"):
        return None
    return data["data"][0]  # {id, name, ...}


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
        grids = [g for g in (data.get("data") or []) if g.get("url")]

        def score(g):
            portrait = 1 if (g.get("height", 0) >= g.get("width", 1)) else 0
            jp = 1 if str(g.get("url", "")).lower().endswith((".jpg", ".jpeg", ".png")) else 0
            return (portrait, jp, g.get("upvotes", 0))

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
        if os.path.exists(os.path.join(covers_dir, stem + ext)):
            return True
    return False


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


def is_disc_track(name, files_in_dir):
    """A .bin/.img/.iso referenced by a sibling .cue/.m3u (skip to avoid duplicate covers)."""
    ext = os.path.splitext(name)[1].lower()
    if ext not in DISC_TRACK_EXTS:
        return False
    stem = os.path.splitext(name)[0].lower()
    return (stem + ".cue") in files_in_dir or (stem + ".m3u") in files_in_dir

# ------------------------------------------------------------------ worklist + worker

def build_worklist(roms_root, covers_root, only):
    """Walk ROM folders (no network) and return the games that still need a cover."""
    work = []
    stats = {"skipped": 0, "subfolder": 0}
    consoles = sorted(d for d in os.listdir(roms_root)
                      if os.path.isdir(os.path.join(roms_root, d))
                      and (only is None or d.lower() in only))
    for console in consoles:
        rom_dir = os.path.join(roms_root, console)
        covers_dir = os.path.join(covers_root, console)
        entries = sorted(os.listdir(rom_dir))
        files_lower = {e.lower() for e in entries}
        for entry in entries:
            full = os.path.join(rom_dir, entry)
            if os.path.isdir(full):
                stats["subfolder"] += 1
                continue
            ext = os.path.splitext(entry)[1].lower()
            if not ext or ext in SKIP_EXTS or is_disc_track(entry, files_lower):
                continue
            stem = os.path.splitext(entry)[0]
            if existing_cover(covers_dir, stem):
                stats["skipped"] += 1
                continue
            work.append({"console": console, "covers_dir": covers_dir,
                         "stem": stem, "term": clean_name(stem)})
    return work, stats, consoles


def process_item(item, api_key, dry_run):
    """Fetch + save one cover. Returns a result dict; never raises."""
    console, stem, term = item["console"], item["stem"], item["term"]
    try:
        game = search_game(term, api_key)
        if not game:
            return {"status": "miss", "console": console, "stem": stem,
                    "msg": f"no match for '{term}'"}
        url = best_cover_url(game.get("id"), api_key)
        if not url:
            return {"status": "miss", "console": console, "stem": stem,
                    "msg": f"game '{game.get('name')}' has no portrait cover"}
        cover_ext = os.path.splitext(urllib.parse.urlparse(url).path)[1].lower()
        if cover_ext not in COVER_EXTS:
            cover_ext = ".jpg"
        if dry_run:
            return {"status": "ok", "console": console, "stem": stem,
                    "msg": f"would get <- '{game.get('name')}'  {url}"}
        os.makedirs(item["covers_dir"], exist_ok=True)
        download(url, os.path.join(item["covers_dir"], stem + cover_ext))
        return {"status": "ok", "console": console, "stem": stem,
                "msg": f"<- '{game.get('name')}'"}
    except Exception as e:
        return {"status": "err", "console": console, "stem": stem, "msg": str(e)}

# ------------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="Auto-download SteamGridDB covers for tico.")
    ap.add_argument("--roms", required=True, help=r"ROMs root, e.g. E:\tico\roms")
    ap.add_argument("--covers", help="Covers root (default: auto-detect tico layout)")
    ap.add_argument("--api-key", default=os.environ.get("STEAMGRIDDB_API_KEY"),
                    help="SteamGridDB API key (or set STEAMGRIDDB_API_KEY)")
    ap.add_argument("--consoles", help="Comma-separated console folders to limit to (default: all)")
    ap.add_argument("--workers", type=int, default=6, help="Concurrent downloads (default 6)")
    ap.add_argument("--dry-run", action="store_true", help="Show what would happen, download nothing")
    args = ap.parse_args()

    if not args.api_key:
        raise SystemExit("ERROR: no API key. Pass --api-key or set STEAMGRIDDB_API_KEY.\n"
                         "Get one at https://www.steamgriddb.com/profile/preferences/api")
    if not os.path.isdir(args.roms):
        raise SystemExit(f"ERROR: ROMs root not found: {args.roms}")
    workers = max(1, args.workers)

    covers_root = resolve_covers_root(args.roms, args.covers)
    only = {c.strip().lower() for c in args.consoles.split(",")} if args.consoles else None

    log(f"ROMs root   : {os.path.normpath(args.roms)}")
    log(f"Covers root : {covers_root}")
    log(f"Mode        : {'DRY RUN' if args.dry_run else 'download'}  (workers: {workers})\n")

    work, pre, consoles = build_worklist(args.roms, covers_root, only)
    if not consoles:
        raise SystemExit("No console subfolders found under the ROMs root.")
    log(f"{len(work)} game(s) need covers; {pre['skipped']} already have one; "
        f"{pre['subfolder']} subfolder game(s) skipped.\n")
    if not work:
        log("Nothing to do.")
        return

    stats = {"downloaded": 0, "miss": 0, "err": 0}
    not_found, done = [], 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(process_item, it, args.api_key, args.dry_run): it for it in work}
        for fut in as_completed(futures):
            r = fut.result()
            done += 1
            tag = f"[{done}/{len(work)}]"
            if r["status"] == "ok":
                stats["downloaded"] += 1
                log(f"  {tag} [ok] {r['console']}/{r['stem']}  {r['msg']}")
            elif r["status"] == "miss":
                stats["miss"] += 1
                not_found.append(f"{r['console']}/{r['stem']}  ({r['msg']})")
                log(f"  {tag} [miss] {r['console']}/{r['stem']}  ({r['msg']})")
            else:
                stats["err"] += 1
                log(f"  {tag} [err] {r['console']}/{r['stem']}: {r['msg']}")

    log("\n--------------------------------------------------")
    log(f"Downloaded : {stats['downloaded']}")
    log(f"Skipped    : {pre['skipped']} (already had a cover)")
    log(f"Not found  : {stats['miss']}")
    log(f"Subfolders : {pre['subfolder']} (not handled in v1)")
    log(f"Errors     : {stats['err']}")
    if not_found:
        log("\nGames with no cover (fix these manually in tico, +Select -> Find Cover):")
        for nf in not_found:
            log(f"  - {nf}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("\nInterrupted.")
