# tico-covers

Auto-download SteamGridDB cover art for every game in your [tico](https://github.com/ticohq/tico)
ROM folders. Comes in two flavors with identical behavior:

- `tico-covers.ps1` — PowerShell (nothing to install; works in Windows PowerShell 5.1 and 7+)
- `tico-covers.py` — Python 3 (standard library only; nothing to `pip install`)

## What it does

For each console folder under your ROMs root, it:

1. Reads every ROM file and turns the filename into a search term
   (stripping tags like `(USA)`, `[!]`, `(Rev 1)` and fixing `Zelda, The` → `The Zelda`).
2. **Skips** any game that already has a cover.
3. Searches SteamGridDB, takes the top game match, and grabs its best **portrait** cover.
4. Saves it as `covers/<console>/<rom base name>.jpg` so tico matches it automatically.

It prints a running log and an end summary, including a list of games it couldn't find
covers for (fix those by hand in tico: hover the game → **+Select → Find Cover**).

## 1. Get a SteamGridDB API key (free)

1. Sign in at <https://www.steamgriddb.com/>
2. Go to <https://www.steamgriddb.com/profile/preferences/api> and generate a key.

Then either pass it with `-ApiKey` / `--api-key`, or set it once as an environment variable:

```powershell
setx STEAMGRIDDB_API_KEY "your-key-here"
```

(open a new terminal after `setx` so it takes effect).

## 2. Point it at your ROMs

The ROMs root is the folder that contains the per-console subfolders, e.g. `E:\tico\roms`
(with `nes\`, `snes\`, `gba\`, … inside). That can be the SD card in your PC, or any
local/network copy. Covers are written, by default, to tico's matching cover layout
next to it (`assets\covers\<console>\` or `covers\<console>\`, whichever already exists),
or you can override with `-CoversRoot` / `--covers`.

## 3. Run it

**PowerShell**

```powershell
# preview first (downloads nothing):
.\tico-covers.ps1 -RomsRoot "E:\tico\roms" -DryRun

# real run:
.\tico-covers.ps1 -RomsRoot "E:\tico\roms"

# only certain consoles:
.\tico-covers.ps1 -RomsRoot "E:\tico\roms" -Consoles snes,gba
```

If PowerShell blocks the script, run it for this session only:
`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`

**Python**

```powershell
# preview first:
python tico-covers.py --roms "E:\tico\roms" --dry-run

# real run:
python tico-covers.py --roms "E:\tico\roms"

# only certain consoles:
python tico-covers.py --roms "E:\tico\roms" --consoles snes,gba
```

## Options

| PowerShell        | Python         | Meaning                                            |
|-------------------|----------------|----------------------------------------------------|
| `-RomsRoot`       | `--roms`       | ROMs root folder (required)                         |
| `-ApiKey`         | `--api-key`    | API key (else `STEAMGRIDDB_API_KEY` env var)        |
| `-CoversRoot`     | `--covers`     | Override where covers are written                   |
| `-Consoles a,b`   | `--consoles a,b` | Limit to these console folders                    |
| `-DelayMs`        | `--delay`      | Throttle between API calls (default 150 ms / 0.15 s) |
| `-DryRun`         | `--dry-run`    | Show what would happen, download nothing            |

## Re-running

Safe to run as often as you like — it **skips games that already have a cover**, so a
second run only fills in the gaps (e.g. after you add more ROMs).

## Known limitations (v1)

- Handles single-file ROMs sitting directly in `roms/<console>/`. Games inside their own
  subfolder are reported and skipped, because tico's cover naming for those isn't certain.
- Auto-match uses SteamGridDB's top result. For ambiguously named games it may pick the
  wrong one; those are easy to redo manually in tico.
- For `.bin`/`.cue` disc games it covers the `.cue` and skips the matching `.bin`.
