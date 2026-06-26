<#
.SYNOPSIS
    Auto-download SteamGridDB cover art for every game in your tico ROM folders.

.DESCRIPTION
    Scans <RomsRoot>\<console>\ for ROM files, searches SteamGridDB for each game,
    downloads the top portrait (box-art) cover, and saves it next to tico's other
    covers using the ROM's base filename so tico picks it up automatically.

    Downloads run concurrently (a runspace pool) so large libraries finish quickly.
    Pure PowerShell -- no modules to install. Works in Windows PowerShell 5.1 and 7+.

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

.PARAMETER Workers
    Number of concurrent downloads (default 6).

.PARAMETER DryRun
    Show what would happen without downloading anything.

.EXAMPLE
    .\tico-covers.ps1 -RomsRoot "E:\tico\roms" -ApiKey YOURKEY

.EXAMPLE
    setx STEAMGRIDDB_API_KEY YOURKEY   # once
    .\tico-covers.ps1 -RomsRoot "E:\tico\roms" -Workers 6
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $RomsRoot,
    [string] $ApiKey = $env:STEAMGRIDDB_API_KEY,
    [string] $CoversRoot,
    [string[]] $Consoles,
    [int] $Workers = 6,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$ApiBase       = 'https://www.steamgriddb.com/api/v2'
$PortraitDims  = '600x900,342x482,660x930'
$SkipExts      = @('.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp',
                   '.txt', '.nfo', '.dat', '.xml', '.json', '.jsonc', '.db',
                   '.sav', '.srm', '.state', '.st0', '.rtc',
                   '.ips', '.bps', '.ups', '.xdelta', '.bak', '.tmp')
$Articles      = @('the', 'a', 'an', 'le', 'la', 'les', 'el', 'los', 'las', 'die', 'der', 'das')
$DiscTrackExts = @('.bin', '.img', '.iso')

# ------------------------------------------------------- helpers (walk, main thread)

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

function Test-ExistingCover([string] $coversDir, [string] $stem) {
    # tico only displays .jpg, so only a .jpg counts as "already done" -- this lets a
    # re-run replace the old, invisible .png files written by earlier versions.
    foreach ($ext in @('.jpg', '.jpeg')) {
        if (Test-Path -LiteralPath (Join-Path $coversDir ($stem + $ext))) { return $true }
    }
    return $false
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

# --------------------------------------------------- worker (runs inside a runspace)

$Worker = {
    param($Item, $ApiKey, $ApiBase, $PortraitDims, $DryRun)
    $ErrorActionPreference = 'Stop'
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.Drawing
    $JpegEncoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
    $JpegParams  = New-Object System.Drawing.Imaging.EncoderParameters 1
    $JpegParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality, [int64]90)

    function Invoke-Sgdb($Url) {
        $headers = @{ Authorization = "Bearer $ApiKey"; 'User-Agent' = 'tico-covers/1.0' }
        for ($attempt = 0; $attempt -lt 4; $attempt++) {
            try {
                return Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec 30
            } catch {
                $code = 0
                if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
                if ($code -eq 401) { throw "API key rejected (401)" }
                if ($code -eq 404) { return $null }
                if ($code -eq 429 -or $code -ge 500) { Start-Sleep -Seconds ([math]::Pow(2, $attempt)); continue }
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds ([math]::Pow(2, $attempt))
            }
        }
        return $null
    }

    $res = [pscustomobject]@{ Status = 'err'; Console = $Item.Console; Stem = $Item.Stem; Game = ''; Msg = '' }
    try {
        $searchUrl = "$ApiBase/search/autocomplete/" + [uri]::EscapeDataString($Item.Term)
        $data = Invoke-Sgdb $searchUrl
        if (-not $data -or -not $data.success -or -not $data.data -or @($data.data).Count -eq 0) {
            $res.Status = 'miss'; $res.Msg = "no match for '$($Item.Term)'"; return $res
        }
        $game = @($data.data)[0]
        $res.Game = $game.name

        # Prefer SteamGridDB's SQUARE art (matches tico's 512x512 tile, no cropping),
        # then portrait, then anything. Only jpg/png -- System.Drawing can't decode webp.
        $url = $null; $picked = ''
        foreach ($spec in @(
                @{ q = "?types=static&nsfw=false&humor=false&dimensions=512x512,1024x1024"; tag = 'square' },
                @{ q = "?types=static&nsfw=false&humor=false&dimensions=$PortraitDims";      tag = 'portrait' },
                @{ q = "?types=static&nsfw=false&humor=false";                               tag = 'any' })) {
            $gr = Invoke-Sgdb ("$ApiBase/grids/game/$($game.id)" + $spec.q)
            if (-not $gr -or -not $gr.success) { continue }
            $grids = @($gr.data | Where-Object { $_.url -and ($_.url -match '\.(jpg|jpeg|png)$') })
            if ($grids.Count -eq 0) { continue }
            $url = ($grids | Sort-Object -Property `
                @{ Expression = { [int]$_.upvotes }; Descending = $true }, `
                @{ Expression = { [int]$_.width };   Descending = $true })[0].url
            $picked = $spec.tag
            break
        }
        if (-not $url) { $res.Status = 'miss'; $res.Msg = "game '$($game.name)' has no usable cover"; return $res }

        # tico displays covers as .jpg, so always write <rom name>.jpg.
        $dest = Join-Path $Item.CoversDir ($Item.Stem + '.jpg')
        if ($DryRun) { $res.Status = 'ok'; $res.Msg = "would get ($picked) <- '$($game.name)'  $url"; return $res }
        if (-not (Test-Path -LiteralPath $Item.CoversDir)) {
            New-Item -ItemType Directory -Force -Path $Item.CoversDir | Out-Null
        }

        # WebClient + System.Drawing/.NET I/O use LITERAL paths, so [ ] in names is safe.
        $wc = New-Object System.Net.WebClient
        $wc.Headers['User-Agent'] = 'tico-covers/1.0'
        try { $bytes = $wc.DownloadData($url) } finally { $wc.Dispose() }

        # Convert to a 512x512 JPEG: scale-to-fill + center-crop (no borders, no distortion).
        $ms = New-Object System.IO.MemoryStream (,$bytes)
        try {
            $img = [System.Drawing.Image]::FromStream($ms)
            $bmp = New-Object System.Drawing.Bitmap 512, 512
            $gfx = [System.Drawing.Graphics]::FromImage($bmp)
            $gfx.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $scale = [Math]::Max((512 / $img.Width), (512 / $img.Height))
            $dw = [int]($img.Width * $scale); $dh = [int]($img.Height * $scale)
            $gfx.DrawImage($img, [int]((512 - $dw) * 0.5), [int]((512 - $dh) * 0.5), $dw, $dh)
            $gfx.Dispose()
            $bmp.Save($dest, $JpegEncoder, $JpegParams)
            $bmp.Dispose(); $img.Dispose()
        } finally { $ms.Dispose() }

        # Drop stale non-jpg covers from earlier versions (tico ignores them).
        foreach ($staleExt in @('.png', '.webp')) {
            $stale = Join-Path $Item.CoversDir ($Item.Stem + $staleExt)
            if ([System.IO.File]::Exists($stale)) { [System.IO.File]::Delete($stale) }
        }
        $res.Status = 'ok'; $res.Msg = "($picked) <- '$($game.name)'"
    } catch {
        $res.Status = 'err'; $res.Msg = $_.Exception.Message
    }
    return $res
}

# -------------------------------------------------------------------------- main

if (-not $ApiKey) {
    throw "No API key. Pass -ApiKey or set STEAMGRIDDB_API_KEY.`nGet one at https://www.steamgriddb.com/profile/preferences/api"
}
if (-not (Test-Path -LiteralPath $RomsRoot -PathType Container)) {
    throw "ROMs root not found: $RomsRoot"
}
if ($Workers -lt 1) { $Workers = 1 }

$coversRootResolved = Resolve-CoversRoot $RomsRoot $CoversRoot
Write-Host "ROMs root   : $([System.IO.Path]::GetFullPath($RomsRoot))"
Write-Host "Covers root : $coversRootResolved"
Write-Host ("Mode        : {0}  (workers: {1})`n" -f $(if ($DryRun) { 'DRY RUN' } else { 'download' }), $Workers)

$only = $null
if ($Consoles) { $only = $Consoles | ForEach-Object { $_.ToLower() } }

$consoleDirs = Get-ChildItem -LiteralPath $RomsRoot -Directory |
    Where-Object { -not $only -or ($only -contains $_.Name.ToLower()) } |
    Sort-Object Name
if (-not $consoleDirs) { throw "No console subfolders found under the ROMs root." }

# --- Phase 1: walk folders (no network), build the worklist of games needing a cover.
$work       = New-Object System.Collections.Generic.List[object]
$skipped    = 0
$subfolder  = 0
foreach ($cdir in $consoleDirs) {
    $console   = $cdir.Name
    $coversDir = Join-Path $coversRootResolved $console
    $entries   = Get-ChildItem -LiteralPath $cdir.FullName | Sort-Object Name
    $namesLower = @{}
    foreach ($e in $entries) { $namesLower[$e.Name.ToLower()] = $true }

    foreach ($entry in $entries) {
        if ($entry.PSIsContainer) { $subfolder++; continue }
        $ext = $entry.Extension.ToLower()
        if (-not $ext -or $SkipExts -contains $ext) { continue }
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($entry.Name)
        if ($DiscTrackExts -contains $ext) {
            if ($namesLower.ContainsKey("$($stem.ToLower()).cue") -or
                $namesLower.ContainsKey("$($stem.ToLower()).m3u")) { continue }
        }
        if (Test-ExistingCover $coversDir $stem) { $skipped++; continue }
        $work.Add([pscustomobject]@{ Console = $console; CoversDir = $coversDir; Stem = $stem; Term = (Get-CleanName $stem) })
    }
}
Write-Host ("{0} game(s) need covers; {1} already have one; {2} subfolder game(s) skipped.`n" -f $work.Count, $skipped, $subfolder)

$downloaded = 0; $notFoundCount = 0; $errors = 0
$notFound = New-Object System.Collections.Generic.List[string]

if ($work.Count -eq 0) {
    Write-Host "Nothing to do."
} else {
    # --- Phase 2: fetch covers concurrently via a runspace pool.
    $pool = [runspacefactory]::CreateRunspacePool(1, $Workers)
    $pool.Open()
    $tasks = New-Object System.Collections.Generic.List[object]
    foreach ($w in $work) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($Worker).
            AddArgument($w).AddArgument($ApiKey).AddArgument($ApiBase).
            AddArgument($PortraitDims).AddArgument([bool]$DryRun)
        $tasks.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Done = $false })
    }

    $total = $tasks.Count
    $completed = 0
    while ($completed -lt $total) {
        foreach ($t in $tasks) {
            if ($t.Done -or -not $t.Handle.IsCompleted) { continue }
            $r = @($t.PS.EndInvoke($t.Handle))[0]
            $t.PS.Dispose(); $t.Done = $true; $completed++
            $tag = "[$completed/$total]"
            switch ($r.Status) {
                'ok'   { $downloaded++;    Write-Host "  $tag [ok] $($r.Console)/$($r.Stem)  $($r.Msg)" }
                'miss' { $notFoundCount++; $notFound.Add("$($r.Console)/$($r.Stem)  ($($r.Msg))"); Write-Host "  $tag [miss] $($r.Console)/$($r.Stem)  ($($r.Msg))" }
                default { $errors++;       Write-Host "  $tag [err] $($r.Console)/$($r.Stem): $($r.Msg)" }
            }
        }
        if ($completed -lt $total) { Start-Sleep -Milliseconds 50 }
    }
    $pool.Close(); $pool.Dispose()
}

Write-Host "`n--------------------------------------------------"
Write-Host "Downloaded : $downloaded"
Write-Host "Skipped    : $skipped (already had a cover)"
Write-Host "Not found  : $notFoundCount"
Write-Host "Subfolders : $subfolder (not handled in v1)"
Write-Host "Errors     : $errors"
if ($notFound.Count -gt 0) {
    Write-Host "`nGames with no cover (fix these manually in tico, +Select -> Find Cover):"
    foreach ($nf in $notFound) { Write-Host "  - $nf" }
}
