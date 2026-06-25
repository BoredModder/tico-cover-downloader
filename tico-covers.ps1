<#
.SYNOPSIS
    Auto-download SteamGridDB cover art for every game in your tico ROM folders.

.DESCRIPTION
    Scans <RomsRoot>\<console>\ for ROM files, searches SteamGridDB for each game,
    downloads the top portrait (box-art) cover, and saves it next to tico's other
    covers using the ROM's base filename so tico picks it up automatically.

    Pure PowerShell -- no modules to install. Works in Windows PowerShell 5.1 and
    PowerShell 7+.

.PARAMETER RomsRoot
    Path to your tico roms folder, e.g. E:\tico\roms

.PARAMETER ApiKey
    SteamGridDB API key. Defaults to the STEAMGRIDDB_API_KEY environment variable.
    Get a free key at https://www.steamgriddb.com/profile/preferences/api

.PARAMETER CoversRoot
    Where covers are written. Defaults to auto-detected tico layout
    (assets\covers or covers, as a sibling of RomsRoot).

.PARAMETER Consoles
    Optional list of console folders to limit to, e.g. -Consoles snes,gba

.PARAMETER DelayMs
    Milliseconds to wait between API calls (default 150).

.PARAMETER DryRun
    Show what would happen without downloading anything.

.EXAMPLE
    .\tico-covers.ps1 -RomsRoot "E:\tico\roms" -ApiKey YOURKEY

.EXAMPLE
    setx STEAMGRIDDB_API_KEY YOURKEY   # once
    .\tico-covers.ps1 -RomsRoot "E:\tico\roms"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $RomsRoot,
    [string] $ApiKey = $env:STEAMGRIDDB_API_KEY,
    [string] $CoversRoot,
    [string[]] $Consoles,
    [int] $DelayMs = 150,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$ApiBase      = 'https://www.steamgriddb.com/api/v2'
$PortraitDims = '600x900,342x482,660x930'
$CoverExts    = @('.jpg', '.jpeg', '.png', '.webp')
$SkipExts     = @('.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp',
                  '.txt', '.nfo', '.dat', '.xml', '.json', '.jsonc', '.db',
                  '.sav', '.srm', '.state', '.st0', '.rtc',
                  '.ips', '.bps', '.ups', '.xdelta', '.bak', '.tmp')
$Articles     = @('the', 'a', 'an', 'le', 'la', 'les', 'el', 'los', 'las', 'die', 'der', 'das')
$DiscTrackExts = @('.bin', '.img', '.iso')

# ----------------------------------------------------------------------- helpers

function Get-CleanName([string] $stem) {
    $name = [regex]::Replace($stem, '[\(\[].*?[\)\]]', ' ')   # drop (USA), [!], (Rev 1)...
    $name = $name.Replace('_', ' ').Replace('.', ' ')
    $name = [regex]::Replace($name, '\s+', ' ').Trim()
    # No-Intro stores articles after the title: "Zelda, The - ..." -> "The Zelda - ..."
    $m = [regex]::Match($name, ("^(.*?),\s+({0})\b(.*)$" -f ($Articles -join '|')), 'IgnoreCase')
    if ($m.Success) {
        $name = ("{0} {1}{2}" -f $m.Groups[2].Value, $m.Groups[1].Value, $m.Groups[3].Value).Trim()
    }
    return $name
}

function Invoke-Sgdb([string] $Url) {
    $headers = @{ Authorization = "Bearer $ApiKey"; 'User-Agent' = 'tico-covers/1.0' }
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec 30
        } catch {
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -eq 401) { throw "SteamGridDB rejected the API key (401). Check -ApiKey / STEAMGRIDDB_API_KEY." }
            if ($code -eq 404) { return $null }
            if ($code -eq 429 -or $code -ge 500) {
                $wait = [math]::Pow(2, $attempt)
                Write-Host "    rate-limited/$code, waiting $wait s..."
                Start-Sleep -Seconds $wait
                continue
            }
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds ([math]::Pow(2, $attempt))
        }
    }
    return $null
}

function Get-GameMatch([string] $term) {
    $url = "$ApiBase/search/autocomplete/" + [uri]::EscapeDataString($term)
    $data = Invoke-Sgdb $url
    if (-not $data -or -not $data.success -or -not $data.data -or $data.data.Count -eq 0) { return $null }
    return $data.data[0]
}

function Get-BestCoverUrl([int] $gameId) {
    $base = "$ApiBase/grids/game/$gameId"
    $queries = @(
        "?types=static&nsfw=false&humor=false&dimensions=$PortraitDims",
        "?types=static&nsfw=false&humor=false"
    )
    foreach ($q in $queries) {
        $data = Invoke-Sgdb ($base + $q)
        if (-not $data -or -not $data.success) { continue }
        $grids = @($data.data | Where-Object { $_.url })
        if ($grids.Count -eq 0) { continue }
        $ranked = $grids | Sort-Object -Property `
            @{ Expression = { if ($_.height -ge $_.width) { 1 } else { 0 } }; Descending = $true }, `
            @{ Expression = { if ($_.url -match '\.(jpg|jpeg|png)$') { 1 } else { 0 } }; Descending = $true }, `
            @{ Expression = { [int]$_.upvotes }; Descending = $true }
        return $ranked[0].url
    }
    return $null
}

function Get-ExistingCover([string] $coversDir, [string] $stem) {
    foreach ($ext in $CoverExts) {
        $p = Join-Path $coversDir ($stem + $ext)
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Resolve-CoversRoot([string] $roms, [string] $override) {
    if ($override) { return $override }
    $roms = [System.IO.Path]::GetFullPath($roms)
    if ((Split-Path $roms -Leaf).ToLower() -eq 'roms') { $parent = Split-Path $roms -Parent }
    else { $parent = $roms }
    $candidates = @((Join-Path $parent 'assets\covers'), (Join-Path $parent 'covers'))
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c -PathType Container) { return $c } }
    return $candidates[0]
}

# -------------------------------------------------------------------------- main

if (-not $ApiKey) {
    throw "No API key. Pass -ApiKey or set STEAMGRIDDB_API_KEY.`nGet one at https://www.steamgriddb.com/profile/preferences/api"
}
if (-not (Test-Path -LiteralPath $RomsRoot -PathType Container)) {
    throw "ROMs root not found: $RomsRoot"
}

$coversRootResolved = Resolve-CoversRoot $RomsRoot $CoversRoot
Write-Host "ROMs root   : $([System.IO.Path]::GetFullPath($RomsRoot))"
Write-Host "Covers root : $coversRootResolved"
Write-Host ("Mode        : {0}`n" -f $(if ($DryRun) { 'DRY RUN' } else { 'download' }))

$only = $null
if ($Consoles) { $only = $Consoles | ForEach-Object { $_.ToLower() } }

$consoleDirs = Get-ChildItem -LiteralPath $RomsRoot -Directory |
    Where-Object { -not $only -or ($only -contains $_.Name.ToLower()) } |
    Sort-Object Name
if (-not $consoleDirs) { throw "No console subfolders found under the ROMs root." }

$stats = @{ downloaded = 0; skipped = 0; not_found = 0; errors = 0; subfolder = 0 }
$notFound = New-Object System.Collections.Generic.List[string]

foreach ($cdir in $consoleDirs) {
    $console    = $cdir.Name
    $coversDir  = Join-Path $coversRootResolved $console
    $entries    = Get-ChildItem -LiteralPath $cdir.FullName | Sort-Object Name
    $namesLower = @{}
    foreach ($e in $entries) { $namesLower[$e.Name.ToLower()] = $true }
    Write-Host "=== $console ==="

    foreach ($entry in $entries) {
        if ($entry.PSIsContainer) {
            $stats.subfolder++
            Write-Host "  [subfolder] $($entry.Name)  (skipped -- v1 handles single-file ROMs)"
            continue
        }
        $ext  = $entry.Extension.ToLower()
        if (-not $ext -or $SkipExts -contains $ext) { continue }
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($entry.Name)

        # Skip a disc track (.bin/.img/.iso) referenced by a sibling .cue/.m3u.
        if ($DiscTrackExts -contains $ext) {
            if ($namesLower.ContainsKey("$($stem.ToLower()).cue") -or
                $namesLower.ContainsKey("$($stem.ToLower()).m3u")) { continue }
        }

        $have = Get-ExistingCover $coversDir $stem
        if ($have) { $stats.skipped++; Write-Host "  [have] $stem"; continue }

        $term = Get-CleanName $stem
        try {
            $game = Get-GameMatch $term
            Start-Sleep -Milliseconds $DelayMs
            if (-not $game) {
                $stats.not_found++
                $notFound.Add("$console/$stem  (searched: $term)")
                Write-Host "  [miss] $stem  (no match for '$term')"
                continue
            }
            $url = Get-BestCoverUrl ([int]$game.id)
            Start-Sleep -Milliseconds $DelayMs
            if (-not $url) {
                $stats.not_found++
                $notFound.Add("$console/$stem  (game '$($game.name)' has no cover)")
                Write-Host "  [no-art] $stem  ('$($game.name)' -> no portrait cover)"
                continue
            }
            $coverExt = [System.IO.Path]::GetExtension(([uri]$url).AbsolutePath).ToLower()
            if (-not ($CoverExts -contains $coverExt)) { $coverExt = '.jpg' }
            $dest = Join-Path $coversDir ($stem + $coverExt)

            if ($DryRun) {
                Write-Host "  [would get] $stem  <- '$($game.name)'  $url"
                $stats.downloaded++
                continue
            }
            if (-not (Test-Path -LiteralPath $coversDir)) {
                New-Item -ItemType Directory -Force -Path $coversDir | Out-Null
            }
            Invoke-WebRequest -Uri $url -OutFile $dest -TimeoutSec 60 -UseBasicParsing
            $stats.downloaded++
            Write-Host "  [ok] $stem  <- '$($game.name)'"
        } catch {
            $stats.errors++
            Write-Host "  [err] ${stem}: $($_.Exception.Message)"
        }
    }
}

Write-Host "`n--------------------------------------------------"
Write-Host "Downloaded : $($stats.downloaded)"
Write-Host "Skipped    : $($stats.skipped) (already had a cover)"
Write-Host "Not found  : $($stats.not_found)"
Write-Host "Subfolders : $($stats.subfolder) (not handled in v1)"
Write-Host "Errors     : $($stats.errors)"
if ($notFound.Count -gt 0) {
    Write-Host "`nGames with no cover (fix these manually in tico, +Select -> Find Cover):"
    foreach ($nf in $notFound) { Write-Host "  - $nf" }
}
