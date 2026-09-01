<#
.SYNOPSIS
    Adds a native high-resolution mode (1920x1080 by default) to the Steam release of
    Commandos: Behind Enemy Lines, and makes it behave on Windows 10/11.

.DESCRIPTION
    The 2016 Steam build of Commandos: Behind Enemy Lines ships with four hard-coded
    resolutions: 640x480, 800x600, 1024x768 and 1280x720. This script repoints the
    fourth slot at your monitor's native resolution and supplies the matching menu
    and interface graphics, so the game runs full-screen without stretching.

    Everything it changes is backed up first and can be undone with -Uninstall.

.PARAMETER GameDir
    Path to the game folder. Auto-detected from your Steam libraries if omitted.

.PARAMETER Width
    Target width. Defaults to your primary monitor's width.

.PARAMETER Height
    Target height. Defaults to your primary monitor's height.

.PARAMETER NoDDrawCompat
    Skip installing the DDrawCompat DirectDraw wrapper (which fixes the sluggish
    mouse and low frame rate). The resolution patch is applied either way.

.PARAMETER Uninstall
    Undo everything this script did and put the original files back.

.EXAMPLE
    .\Fix-BehindEnemyLines.ps1
    Detect the game, patch it to your monitor's native resolution, install DDrawCompat.

.EXAMPLE
    .\Fix-BehindEnemyLines.ps1 -Width 2560 -Height 1440
    Use a specific resolution instead of the detected one.

.EXAMPLE
    .\Fix-BehindEnemyLines.ps1 -Uninstall
    Restore the original game files.

.NOTES
    Project: https://github.com/Thominho/commandos-1080p-fix
    License: MIT (the script). Bundled game graphics are community work - see assets/CREDITS.md.
#>
[CmdletBinding()]
param(
    [string] $GameDir,
    [int]    $Width,
    [int]    $Height,
    [switch] $NoDDrawCompat,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  Game-specific facts. This is the only block that differs between the two
#  scripts in this repository.
# ---------------------------------------------------------------------------
$GAME = @{
    Title        = 'Commandos: Behind Enemy Lines'
    SteamAppId   = 6800
    InstallDir   = 'Commandos Behind Enemy Lines'
    ExeName      = 'Comandos.exe'
    ArchiveName  = 'WARGAME.DIR'
    DocsDir      = 'Commandos - Behind Enemy Lines'   # under \Documents
    KnownExeSize = 2568192                            # 2016 Steam build
    # Every place in the executable that mentions the 4th resolution slot.
    # {W} / {H} expand to the little-endian DWORD of the width / height.
    Patterns     = @(
        @{ Name = 'video mode setters';      Spec = 'BB {H} BF {W}';                          Expect = 3 }
        @{ Name = 'slot -> resolution table'; Spec = 'C7 45 60 {W} C7 45 64 {H}';              Expect = 1 }
        @{ Name = 'resolution -> slot map';   Spec = '81 F9 {W} 75 05 B8 04 00 00 00';         Expect = 1 }
    )
}

$STOCK_W = 1280       # what the untouched Steam build has in slot 4
$STOCK_H = 720
$INITSIZE = 4         # slot 4, 1-based, as the game writes it into COMANDO.CFG
$BACKUP_DIR_NAME = '_Commandos1080Fix_Backup'
$DDC_API = 'https://api.github.com/repos/narzoul/DDrawCompat/releases'

# ---------------------------------------------------------------------------
#  Output helpers
# ---------------------------------------------------------------------------
function Write-Step ($m) { Write-Host "  $m" }
function Write-Ok   ($m) { Write-Host "  [ok]   $m"   -ForegroundColor Green }
function Write-Info ($m) { Write-Host "  [info] $m"   -ForegroundColor Cyan }
function Write-Warn2($m) { Write-Host "  [warn] $m"   -ForegroundColor Yellow }
function Write-Head ($m) {
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkGray
    Write-Host "  $m" -ForegroundColor White
    Write-Host ('=' * 74) -ForegroundColor DarkGray
}
function Fail ($m) { Write-Host ''; Write-Host "  ERROR: $m" -ForegroundColor Red; Write-Host ''; exit 1 }

# ---------------------------------------------------------------------------
#  Byte-pattern helpers. Searching is done on a Latin-1 string so that .NET's
#  native IndexOf does the work - a byte-by-byte loop in PowerShell would take
#  the better part of a minute on a 2.5 MB executable.
# ---------------------------------------------------------------------------
$Latin1 = [System.Text.Encoding]::GetEncoding(28591)

function ConvertTo-PatternBytes {
    param([string]$Spec, [int]$W, [int]$H)
    $list = New-Object System.Collections.Generic.List[byte]
    foreach ($tok in ($Spec -split '\s+' | Where-Object { $_ })) {
        switch ($tok) {
            '{W}'   { $list.AddRange([BitConverter]::GetBytes([int]$W)) }
            '{H}'   { $list.AddRange([BitConverter]::GetBytes([int]$H)) }
            default { $list.Add([Convert]::ToByte($tok, 16)) }
        }
    }
    return ,$list.ToArray()
}

function Find-AllBytes {
    param([string]$Haystack, [byte[]]$Needle)
    $n = $Latin1.GetString($Needle)
    $hits = @()
    $i = $Haystack.IndexOf($n, [StringComparison]::Ordinal)
    while ($i -ge 0) {
        $hits += $i
        $i = $Haystack.IndexOf($n, $i + 1, [StringComparison]::Ordinal)
    }
    return ,$hits
}

# Does the executable match every pattern for this (w,h), with the expected counts?
function Test-ExeResolution {
    param([string]$Text, [int]$W, [int]$H)
    foreach ($p in $GAME.Patterns) {
        $bytes = ConvertTo-PatternBytes -Spec $p.Spec -W $W -H $H
        $hits  = Find-AllBytes -Haystack $Text -Needle $bytes
        if ($hits.Count -ne $p.Expect) { return $false }
    }
    return $true
}

# ---------------------------------------------------------------------------
#  .DIR archive support
#
#  Layout: a tree of 44-byte records.
#     [0..31]  name, NUL-terminated, 0xCD padded
#     [32]     type: 0 = file, 1 = directory, 0xFF = end-of-directory marker
#     [36..39] size (files) / 0 (directories)
#     [40..43] offset of the data (files) / of the child record block (directories)
#
#  To add a file we append its data at the end of the archive, copy the parent
#  directory's record block to the end as well with one extra record spliced in,
#  and repoint the parent at the new block. Nothing existing moves, so every
#  other offset in the archive stays valid.
# ---------------------------------------------------------------------------
$ENTRY_SIZE = 44

function Read-DirRecord {
    param([System.IO.FileStream]$Fs, [long]$Offset)
    $buf = New-Object byte[] $ENTRY_SIZE
    $Fs.Position = $Offset
    if ($Fs.Read($buf, 0, $ENTRY_SIZE) -ne $ENTRY_SIZE) { return $null }
    $nul = [Array]::IndexOf($buf, [byte]0, 0, 32)
    if ($nul -lt 0) { $nul = 32 }
    return [pscustomobject]@{
        Name       = [System.Text.Encoding]::ASCII.GetString($buf, 0, $nul)
        Type       = $buf[32]
        Size       = [BitConverter]::ToUInt32($buf, 36)
        DataOffset = [BitConverter]::ToUInt32($buf, 40)
        RecordAt   = $Offset
    }
}

# Walk the tree and return the record for one path, e.g. 'DATOS\RECURSOS\BMPS\SYSTEM\MISC'
function Find-DirRecord {
    param([System.IO.FileStream]$Fs, [string]$Path)
    $parts = $Path -split '\\'
    $blockStart = [long]0          # the root record block starts at offset 0
    $found = $null
    foreach ($part in $parts) {
        $found = $null
        $cursor = $blockStart
        while ($true) {
            $rec = Read-DirRecord -Fs $Fs -Offset $cursor
            if ($null -eq $rec -or $rec.Type -eq 0xFF) { break }
            if ($rec.Name -ieq $part) { $found = $rec; break }
            $cursor += $ENTRY_SIZE
        }
        if ($null -eq $found) { return $null }
        if ($found.Type -eq 1) { $blockStart = [long]$found.DataOffset }
    }
    return $found
}

function Get-BlockLength {
    param([System.IO.FileStream]$Fs, [long]$BlockStart)
    $cursor = $BlockStart
    while ($true) {
        $rec = Read-DirRecord -Fs $Fs -Offset $cursor
        if ($null -eq $rec) { throw 'Malformed archive: no end-of-directory marker.' }
        $cursor += $ENTRY_SIZE
        if ($rec.Type -eq 0xFF) { break }
    }
    return [int]($cursor - $BlockStart)
}

function New-DirRecord {
    param([string]$Name, [byte]$Type, [uint32]$Size, [uint32]$DataOffset)
    $rec = New-Object byte[] $ENTRY_SIZE
    for ($i = 0; $i -lt $ENTRY_SIZE; $i++) { $rec[$i] = 0xCD }
    $nb = [System.Text.Encoding]::ASCII.GetBytes($Name)
    if ($nb.Length -ge 32) { throw "Name too long for a .DIR record: $Name" }
    [Array]::Copy($nb, 0, $rec, 0, $nb.Length)
    $rec[$nb.Length] = 0
    $rec[32] = $Type
    [Array]::Copy([BitConverter]::GetBytes($Size),       0, $rec, 36, 4)
    [Array]::Copy([BitConverter]::GetBytes($DataOffset), 0, $rec, 40, 4)
    return ,$rec
}

# Returns $null when the file was already there, otherwise the parent's old block offset
# (needed by -Uninstall to put the directory back the way it was).
function Add-FileToArchive {
    param([string]$Archive, [string]$DirPath, [string]$FileName, [string]$SourceFile)

    $fs = [System.IO.File]::Open($Archive, 'Open', 'ReadWrite')
    try {
        $dir = Find-DirRecord -Fs $fs -Path $DirPath
        if ($null -eq $dir)      { throw "Directory '$DirPath' not found inside $Archive." }
        if ($dir.Type -ne 1)     { throw "'$DirPath' is not a directory inside $Archive." }

        $blockStart = [long]$dir.DataOffset
        $blockLen   = Get-BlockLength -Fs $fs -BlockStart $blockStart

        # already present?
        for ($o = $blockStart; $o -lt $blockStart + $blockLen - $ENTRY_SIZE; $o += $ENTRY_SIZE) {
            $rec = Read-DirRecord -Fs $fs -Offset $o
            if ($rec.Name -ieq $FileName) { return $null }
        }

        $block = New-Object byte[] $blockLen
        $fs.Position = $blockStart
        [void]$fs.Read($block, 0, $blockLen)

        # 1. append the file data (4-byte aligned)
        $data = [System.IO.File]::ReadAllBytes($SourceFile)
        $fs.Position = $fs.Length
        while ($fs.Position % 4 -ne 0) { $fs.WriteByte(0) }
        $dataOffset = [uint32]$fs.Position
        $fs.Write($data, 0, $data.Length)

        # 2. append the rebuilt record block: existing records + ours + terminator
        while ($fs.Position % 4 -ne 0) { $fs.WriteByte(0) }
        $newBlockOffset = [uint32]$fs.Position
        $fs.Write($block, 0, $blockLen - $ENTRY_SIZE)
        $newRec = New-DirRecord -Name $FileName -Type 0 -Size ([uint32]$data.Length) -DataOffset $dataOffset
        $fs.Write($newRec, 0, $ENTRY_SIZE)
        $fs.Write($block, $blockLen - $ENTRY_SIZE, $ENTRY_SIZE)   # original terminator

        # 3. repoint the parent directory record at the new block
        $fs.Position = $dir.RecordAt + 40
        $fs.Write([BitConverter]::GetBytes($newBlockOffset), 0, 4)

        return [pscustomobject]@{
            DirPath        = $DirPath
            RecordAt       = $dir.RecordAt
            OldBlockOffset = [uint32]$blockStart
        }
    }
    finally { $fs.Close() }
}

function Get-ArchiveFile {
    param([string]$Archive, [string]$Path)
    $fs = [System.IO.File]::Open($Archive, 'Open', 'Read')
    try {
        $rec = Find-DirRecord -Fs $fs -Path $Path
        if ($null -eq $rec -or $rec.Type -ne 0) { return $null }
        $buf = New-Object byte[] $rec.Size
        $fs.Position = $rec.DataOffset
        [void]$fs.Read($buf, 0, $rec.Size)
        return [pscustomobject]@{ Offset = [long]$rec.DataOffset; Bytes = $buf }
    }
    finally { $fs.Close() }
}

function Set-ArchiveBytes {
    param([string]$Archive, [long]$Offset, [byte[]]$Bytes)
    $fs = [System.IO.File]::Open($Archive, 'Open', 'ReadWrite')
    try { $fs.Position = $Offset; $fs.Write($Bytes, 0, $Bytes.Length) }
    finally { $fs.Close() }
}

# ---------------------------------------------------------------------------
#  Widescreen map fix
#
#  A handful of missions use maps that are smaller than a modern screen. The
#  engine simply leaves the leftover strip unpainted, which shows up as a black
#  or garbage-filled band along the right and/or bottom edge.
#
#  The cure (devised by Ferdinand Zeppelin for his ResolutionFix_VOLfix) is to
#  add one extra polygon to the map that covers the leftover strip with ground
#  tiles set to brightness -20, the minimum, which renders as solid black. The
#  band becomes a clean, stable border instead of leftover video memory.
#
#  The map itself cannot be made bigger - the artwork for it does not exist -
#  so on those few missions the picture still does not reach the screen edge.
#  Zoom in with + and it will.
# ---------------------------------------------------------------------------
function Repair-MapVolumes {
    param([string]$Archive, [int]$W, [int]$H)
    $changed = @()
    $fs = [System.IO.File]::Open($Archive, 'Open', 'ReadWrite')
    try {
        $dir = Find-DirRecord -Fs $fs -Path 'DATOS\MISIONES'
        if ($null -eq $dir -or $dir.Type -ne 1) { return ,$changed }

        $recs = @()
        $cursor = [long]$dir.DataOffset
        while ($true) {
            $r = Read-DirRecord -Fs $fs -Offset $cursor
            if ($null -eq $r -or $r.Type -eq 0xFF) { break }
            if ($r.Type -eq 0 -and $r.Name -match '^MAPA\d+\.VOL$') { $recs += $r }
            $cursor += $ENTRY_SIZE
        }

        foreach ($r in $recs) {
            $buf = New-Object byte[] $r.Size
            $fs.Position = $r.DataOffset
            [void]$fs.Read($buf, 0, $r.Size)
            $txt = $Latin1.GetString($buf)
            if ($txt -match 'WIDESCREENFIX') { continue }

            $m = [regex]::Match($txt, 'MAPDIMXY\s+(\d+)\s*,\s*(\d+)')
            if (-not $m.Success) { continue }
            $mw = [int]$m.Groups[1].Value
            $mh = [int]$m.Groups[2].Value
            if ($mw -ge $W -and $mh -ge $H) { continue }

            # any ground texture the map already uses will do - it is drawn black
            $counts = @{}
            foreach ($t in [regex]::Matches($txt, '"([A-Za-z0-9_\-]+\.BMP)"', 'IgnoreCase')) {
                $k = $t.Groups[1].Value.ToUpper()
                if ($counts.ContainsKey($k)) { $counts[$k]++ } else { $counts[$k] = 1 }
            }
            if ($counts.Count -eq 0) { continue }
            $tex = ($counts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1).Key

            $anchor = [regex]::Match($txt, 'MAPTABPOLYS\s*\r?\n\{\r?\n')
            if (-not $anchor.Success) { continue }

            $tiles = @()
            if ($mw -lt $W) { $tiles += ,@($mw, 0, ($W - $mw), $H) }
            if ($mh -lt $H) { $tiles += ,@(0, $mh, $mw, ($H - $mh)) }

            $lines = @(
                "`t; added by commandos-1080p-fix - these five lines are comments only"
                "`t; map_width     = $mw"
                "`t; map_height    = $mh"
                "`t; screen_width  = $W"
                "`t; screen_height = $H"
                "`tPOLY `"WIDESCREENFIX`",0,0,0,0,0,$($tiles.Count)"
                "`tRADIO`t`t0"
            )
            foreach ($t in $tiles) {
                $lines += ("`tTILE   {0,9},{1,4},{2,4},{3,4},   0,   0,-20,`"{4}`",`"   `"" -f $t[0], $t[1], $t[2], $t[3], $tex)
            }
            $lines += ''
            $block = ($lines -join "`r`n") + "`r`n"

            $cut = $anchor.Index + $anchor.Length
            $data = $Latin1.GetBytes($txt.Substring(0, $cut) + $block + $txt.Substring($cut))

            $fs.Position = $fs.Length
            while ($fs.Position % 4 -ne 0) { $fs.WriteByte(0) }
            $newOff = [uint32]$fs.Position
            $fs.Write($data, 0, $data.Length)
            $fs.Position = $r.RecordAt + 36
            $fs.Write([BitConverter]::GetBytes([uint32]$data.Length), 0, 4)
            $fs.Write([BitConverter]::GetBytes($newOff), 0, 4)

            $changed += ,@{ File = $r.Name; RecordAt = $r.RecordAt; OldSize = [uint32]$r.Size; OldOffset = [uint32]$r.DataOffset }
            Write-Ok ("{0}  map is {1}x{2} - black border added" -f $r.Name, $mw, $mh)
        }
    }
    finally { $fs.Close() }
    return ,$changed
}

# ---------------------------------------------------------------------------
#  Menu labels (GLOBAL.STR)
#
#  The options screen reads its four resolution captions from tokens OVI1..OVI4.
#  They live inside the archive, so the replacement has to be exactly as long as
#  the original - we try progressively more compact spellings until one fits and
#  pad the remainder with spaces.
# ---------------------------------------------------------------------------
function Build-OviBlock {
    param([int]$OriginalLength, [int]$W, [int]$H)
    $variants = @(
        @('640 X 480', '800 X 600', '1024 X 768', "$W X $H"),
        @('640 X 480', '800 X 600', '1024X768',   "$W X $H"),
        @('640X480',   '800X600',   '1024X768',   "$W X $H"),
        @('640X480',   '800X600',   '1024X768',   "${W}X${H}")
    )
    foreach ($v in $variants) {
        $text = ''
        for ($i = 0; $i -lt 4; $i++) { $text += ('OVI{0} {1}' -f ($i + 1), $v[$i]) + "`r`n" }
        $bytes = $Latin1.GetBytes($text)
        if ($bytes.Length -le $OriginalLength) {
            if ($bytes.Length -lt $OriginalLength) {
                # pad the last caption with spaces so the block keeps its size
                $pad  = $OriginalLength - $bytes.Length
                $text = $text.Substring(0, $text.Length - 2) + (' ' * $pad) + "`r`n"
                $bytes = $Latin1.GetBytes($text)
            }
            if ($bytes.Length -eq $OriginalLength) { return ,$bytes }
        }
    }
    return $null
}

# Keep only the entries that describe the *original* archive: one per record,
# and never one that points into data appended by an earlier run (that data is
# thrown away by the truncate, so restoring a pointer to it would corrupt the
# directory). This also repairs a state file polluted by an earlier version.
function Select-StateEntries {
    param($Entries, [long]$OriginalLength, [string]$OffsetField)
    $out = @(); $seen = @{}
    foreach ($e in @($Entries)) {
        if (-not $e -or $null -eq $e.RecordAt) { continue }
        if ([long]$e.$OffsetField -ge $OriginalLength) { continue }
        $k = [string]$e.RecordAt
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $out += ,$e
    }
    return ,$out
}

# ---------------------------------------------------------------------------
#  Locating the game
# ---------------------------------------------------------------------------
function Get-SteamLibraries {
    $steam = $null
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try {
            $v = (Get-ItemProperty -Path $k -ErrorAction Stop)
            if ($v.SteamPath)    { $steam = $v.SteamPath }
            elseif ($v.InstallPath) { $steam = $v.InstallPath }
            if ($steam) { break }
        } catch { }
    }
    $libs = @()
    if ($steam) {
        $steam = $steam -replace '/', '\'
        $libs += (Join-Path $steam 'steamapps\common')
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($line in (Get-Content $vdf)) {
                if ($line -match '"path"\s+"(.+?)"') {
                    $libs += (Join-Path ($Matches[1] -replace '\\\\', '\') 'steamapps\common')
                }
            }
        }
    }
    $libs += 'C:\Program Files (x86)\Steam\steamapps\common'
    return ($libs | Select-Object -Unique)
}

function Resolve-GameDir {
    if ($GameDir) {
        if (-not (Test-Path (Join-Path $GameDir $GAME.ExeName))) {
            Fail "$($GAME.ExeName) not found in '$GameDir'."
        }
        return (Resolve-Path $GameDir).Path
    }
    foreach ($lib in (Get-SteamLibraries)) {
        $candidate = Join-Path $lib $GAME.InstallDir
        if (Test-Path (Join-Path $candidate $GAME.ExeName)) { return $candidate }
    }
    Fail "Could not find $($GAME.Title). Pass the folder explicitly: -GameDir 'D:\Steam\steamapps\common\$($GAME.InstallDir)'"
}

function Test-Writable {
    param([string]$Dir)
    $probe = Join-Path $Dir ('.write_test_{0}' -f ([guid]::NewGuid().ToString('N')))
    try { New-Item -ItemType File -Path $probe -ErrorAction Stop | Out-Null; Remove-Item $probe -Force; return $true }
    catch { return $false }
}

# ---------------------------------------------------------------------------
#  DDrawCompat
# ---------------------------------------------------------------------------
function Install-DDrawCompat {
    param([string]$Dir)
    $dll = Join-Path $Dir 'ddraw.dll'
    if (Test-Path $dll) {
        Write-Info 'ddraw.dll already present - leaving it alone.'
    } else {
        Write-Step 'Downloading DDrawCompat from GitHub...'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $rels = Invoke-RestMethod -Uri $DDC_API -Headers @{ 'User-Agent' = 'commandos-1080p-fix' }
            $asset = $null
            foreach ($r in $rels) {
                $asset = $r.assets | Where-Object { $_.name -match '^DDrawCompat-v[\d.]+\.zip$' } | Select-Object -First 1
                if ($asset) { break }
            }
            if (-not $asset) { throw 'No suitable release asset found.' }
            $tmp = Join-Path $env:TEMP ('ddc_{0}' -f ([guid]::NewGuid().ToString('N')))
            New-Item -ItemType Directory -Path $tmp | Out-Null
            $zip = Join-Path $tmp $asset.name
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            Copy-Item (Join-Path $tmp 'ddraw.dll') $dll -Force
            Remove-Item $tmp -Recurse -Force
            Write-Ok "DDrawCompat installed ($($asset.name))."
        }
        catch {
            Write-Warn2 "Could not install DDrawCompat: $($_.Exception.Message)"
            Write-Warn2 'The resolution patch still works; the mouse may just feel sluggish.'
            return
        }
    }

    # Without this the game quits to the desktop as soon as an AVI plays, because
    # DDrawCompat emulates the video mode change the movie player asks for.
    $ini = Join-Path $Dir 'DDrawCompat.ini'
    if (-not (Test-Path $ini)) {
        Set-Content -Path $ini -Encoding ascii -Value @(
            '# Required for Commandos: the intro and briefing movies switch video mode,',
            '# and the game exits if DDrawCompat emulates that switch instead of doing it.',
            'DisplayResolution = app'
        )
        Write-Ok 'DDrawCompat.ini written (DisplayResolution = app).'
    } else {
        Write-Info 'DDrawCompat.ini already exists - not overwriting.'
    }
}

function Set-DpiFlag {
    param([string]$ExePath, [switch]$Remove)
    $key = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    try {
        if ($Remove) {
            if (Test-Path $key) { Remove-ItemProperty -Path $key -Name $ExePath -ErrorAction SilentlyContinue }
            return
        }
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        $existing = $null
        try { $existing = (Get-ItemProperty -Path $key -Name $ExePath -ErrorAction Stop).$ExePath } catch { }
        if ($existing) { Write-Info "Compatibility flags already set: $existing" ; return }
        Set-ItemProperty -Path $key -Name $ExePath -Value '~ HIGHDPIAWARE' -Type String
        Write-Ok 'High-DPI scaling override enabled for the game.'
    }
    catch { Write-Warn2 "Could not set compatibility flags: $($_.Exception.Message)" }
}

# ===========================================================================
#  MAIN
# ===========================================================================
Write-Head "$($GAME.Title) - high resolution fix"

$dir = Resolve-GameDir
Write-Step "Game folder : $dir"

if (-not (Test-Writable -Dir $dir)) {
    Fail "No write access to '$dir'. Right-click the script and choose 'Run as administrator', or run: powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`""
}

$exe       = Join-Path $dir $GAME.ExeName
$archive   = Join-Path $dir $GAME.ArchiveName
$backupDir = Join-Path $dir $BACKUP_DIR_NAME
$stateFile = Join-Path $backupDir 'state.json'
$docsCfg   = Join-Path ([Environment]::GetFolderPath('MyDocuments')) (Join-Path $GAME.DocsDir 'OUTPUT\COMANDO.CFG')
$localCfg  = Join-Path $dir 'OUTPUT\Comando.cfg'

# ------------------------------------------------------------------ uninstall
if ($Uninstall) {
    if (-not (Test-Path $stateFile)) { Fail "Nothing to undo - '$stateFile' does not exist." }
    $state = Get-Content $stateFile -Raw | ConvertFrom-Json
    $state.ArchiveDirs = Select-StateEntries $state.ArchiveDirs $state.ArchiveLength 'OldBlockOffset'
    $state.MapVols     = Select-StateEntries $state.MapVols     $state.ArchiveLength 'OldOffset'

    Write-Step 'Restoring the executable...'
    Copy-Item (Join-Path $backupDir $GAME.ExeName) $exe -Force
    Write-Ok 'Executable restored.'

    Write-Step 'Restoring the archive...'
    foreach ($d in $state.ArchiveDirs) {
        if (-not $d -or $null -eq $d.RecordAt) { continue }
        $fs = [System.IO.File]::Open($archive, 'Open', 'ReadWrite')
        try { $fs.Position = $d.RecordAt + 40; $fs.Write([BitConverter]::GetBytes([uint32]$d.OldBlockOffset), 0, 4) }
        finally { $fs.Close() }
    }
    foreach ($v in $state.MapVols) {
        if (-not $v -or $null -eq $v.RecordAt) { continue }
        $fs = [System.IO.File]::Open($archive, 'Open', 'ReadWrite')
        try {
            $fs.Position = $v.RecordAt + 36
            $fs.Write([BitConverter]::GetBytes([uint32]$v.OldSize), 0, 4)
            $fs.Write([BitConverter]::GetBytes([uint32]$v.OldOffset), 0, 4)
        }
        finally { $fs.Close() }
    }
    if ($state.OviOffset -gt 0) {
        Set-ArchiveBytes -Archive $archive -Offset ([long]$state.OviOffset) -Bytes ([Convert]::FromBase64String($state.OviOriginal))
    }
    $fs = [System.IO.File]::Open($archive, 'Open', 'ReadWrite')
    try { if ($fs.Length -gt [long]$state.ArchiveLength) { $fs.SetLength([long]$state.ArchiveLength) } }
    finally { $fs.Close() }
    Write-Ok "Archive restored to $($state.ArchiveLength) bytes."

    foreach ($f in 'ddraw.dll', 'DDrawCompat.ini') {
        $p = Join-Path $dir $f
        if ((Test-Path $p) -and $state.InstalledDDrawCompat) { Remove-Item $p -Force; Write-Ok "Removed $f." }
    }
    Get-ChildItem $dir -Filter 'DDrawCompat-*.log' -ErrorAction SilentlyContinue | Remove-Item -Force

    foreach ($cfg in @($docsCfg, $localCfg)) {
        $name = Split-Path $cfg -Leaf
        $bak  = Join-Path $backupDir $name
        if ((Test-Path $bak) -and (Test-Path (Split-Path $cfg -Parent))) {
            Copy-Item $bak $cfg -Force; Write-Ok "Restored $cfg."
        }
    }

    Set-DpiFlag -ExePath $exe -Remove
    Write-Host ''
    Write-Ok 'Done. The game is back to its stock state.'
    Write-Info "The backup folder was left in place: $backupDir"
    Write-Host ''
    exit 0
}

# ------------------------------------------------------------------ target res
if (-not $Width -or -not $Height) {
    Add-Type -AssemblyName System.Windows.Forms
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if (-not $Width)  { $Width  = $b.Width }
    if (-not $Height) { $Height = $b.Height }
}
Write-Step "Target      : ${Width}x${Height}"
if ($Width -gt 1920 -or $Height -gt 1920) {
    Write-Warn2 'Above 1920x1920 the bundled interface graphics will not cover the screen.'
}

# ------------------------------------------------------------------ read exe
$exeBytes = [System.IO.File]::ReadAllBytes($exe)
$exeText  = $Latin1.GetString($exeBytes)
if ($exeBytes.Length -ne $GAME.KnownExeSize) {
    Write-Warn2 "Unexpected executable size ($($exeBytes.Length) bytes, expected $($GAME.KnownExeSize)). Continuing on pattern matches alone."
}

$sourceW = $null; $sourceH = $null
if (Test-ExeResolution -Text $exeText -W $STOCK_W -H $STOCK_H) {
    $sourceW = $STOCK_W; $sourceH = $STOCK_H
    Write-Info "Found the stock ${STOCK_W}x${STOCK_H} slot."
}
elseif (Test-ExeResolution -Text $exeText -W $Width -H $Height) {
    Write-Info "The executable is already patched to ${Width}x${Height}."
}
elseif ((Test-Path $stateFile)) {
    $prev = Get-Content $stateFile -Raw | ConvertFrom-Json
    if (Test-ExeResolution -Text $exeText -W $prev.Width -H $prev.Height) {
        $sourceW = $prev.Width; $sourceH = $prev.Height
        Write-Info "Found a previous patch at $($prev.Width)x$($prev.Height); re-pointing it."
    }
}
if (-not $sourceW -and -not (Test-ExeResolution -Text $exeText -W $Width -H $Height)) {
    Fail @"
This executable does not look like the 2016 Steam build of $($GAME.Title).

  Expected to find the 1280x720 resolution slot and could not.
  If you patched it with another tool, verify the game files in Steam first:
  Library -> right-click the game -> Properties -> Installed Files -> Verify integrity.
"@
}

# ------------------------------------------------------------------ backups
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
if (-not (Test-Path (Join-Path $backupDir $GAME.ExeName))) {
    Copy-Item $exe (Join-Path $backupDir $GAME.ExeName) -Force
    Write-Ok "Backed up $($GAME.ExeName)."
}
foreach ($cfg in @($docsCfg, $localCfg)) {
    if (Test-Path $cfg) {
        $bak = Join-Path $backupDir (Split-Path $cfg -Leaf)
        if (-not (Test-Path $bak)) { Copy-Item $cfg $bak -Force }
    }
}

$state = @{
    Width                = $Width
    Height               = $Height
    ArchiveLength        = (Get-Item $archive).Length
    ArchiveDirs          = @()
    MapVols              = @()
    OviOffset            = 0
    OviOriginal          = ''
    InstalledDDrawCompat = $false
}
if (Test-Path $stateFile) {
    $old = Get-Content $stateFile -Raw | ConvertFrom-Json
    $state.ArchiveLength        = $old.ArchiveLength
    $state.ArchiveDirs          = @($old.ArchiveDirs | Where-Object { $_ -and $null -ne $_.RecordAt })
    $state.MapVols              = @($old.MapVols     | Where-Object { $_ -and $null -ne $_.RecordAt })
    $state.OviOffset            = $old.OviOffset
    $state.OviOriginal          = $old.OviOriginal
    $state.InstalledDDrawCompat = $old.InstalledDDrawCompat
}

# ------------------------------------------------------------------ patch exe
Write-Head 'Step 1 of 5  -  executable'
if ($sourceW) {
    $total = 0
    foreach ($p in $GAME.Patterns) {
        $from = ConvertTo-PatternBytes -Spec $p.Spec -W $sourceW -H $sourceH
        $to   = ConvertTo-PatternBytes -Spec $p.Spec -W $Width   -H $Height
        $hits = Find-AllBytes -Haystack $exeText -Needle $from
        foreach ($h in $hits) { [Array]::Copy($to, 0, $exeBytes, $h, $to.Length) }
        $total += $hits.Count
        Write-Step ("{0,-24} {1} site(s) at {2}" -f $p.Name, $hits.Count, (($hits | ForEach-Object { '0x{0:x}' -f $_ }) -join ', '))
    }
    [System.IO.File]::WriteAllBytes($exe, $exeBytes)
    Write-Ok "Patched $total locations: ${sourceW}x${sourceH} -> ${Width}x${Height}."
} else {
    Write-Info 'Nothing to do.'
}

# ------------------------------------------------------------------ graphics
Write-Head 'Step 2 of 5  -  menu and interface graphics'
$assetDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
$bmpName  = "MENU$Width.BMP"
$wadName  = "${Width}X${Height}.WAD"
$bmpSrc   = Join-Path $assetDir $bmpName
$wadSrc   = Join-Path $assetDir $wadName

if (-not (Test-Path $bmpSrc) -or -not (Test-Path $wadSrc)) {
    Write-Warn2 "No $bmpName / $wadName in '$assetDir'."
    Write-Warn2 'The game needs both: without a matching .WAD it exits right after launch.'
    Write-Warn2 'Only 1920x1080 ships with this repository. Use -Width 1920 -Height 1080, or add the files yourself.'
    Fail 'Missing interface graphics for the requested resolution.'
}

$targets = @(
    @{ Dir = 'DATOS\RECURSOS\BMPS\SYSTEM\MISC';   File = $bmpName; Src = $bmpSrc }
    @{ Dir = 'DATOS\RECURSOS\BMPS\SYSTEM\GLOBAL'; File = $wadName; Src = $wadSrc }
)
foreach ($t in $targets) {
    $res = Add-FileToArchive -Archive $archive -DirPath $t.Dir -FileName $t.File -SourceFile $t.Src
    if ($null -eq $res) {
        Write-Info "$($t.File) is already in $($GAME.ArchiveName)."
    } else {
        $state.ArchiveDirs += ,@{ DirPath = $res.DirPath; RecordAt = $res.RecordAt; OldBlockOffset = $res.OldBlockOffset }
        Write-Ok "Added $($t.File) to $($GAME.ArchiveName)\$($t.Dir)."
    }
}

# ------------------------------------------------------------------ menu text
# ------------------------------------------------------------------ map fix
Write-Head 'Step 3 of 5  -  maps smaller than the screen'
$vols = Repair-MapVolumes -Archive $archive -W $Width -H $Height
if ($vols.Count -eq 0) {
    Write-Info 'No map needed a border (or they were fixed on an earlier run).'
} else {
    foreach ($v in $vols) { $state.MapVols += ,$v }
    Write-Ok "$($vols.Count) map(s) given a clean black border."
}

# ------------------------------------------------------------------ menu text
Write-Head 'Step 4 of 5  -  resolution names in the options menu'
$gs = Get-ArchiveFile -Archive $archive -Path 'DATOS\MISIONES\GLOBAL.STR'
if ($null -eq $gs) {
    Write-Warn2 'GLOBAL.STR not found - the options menu will keep its old captions.'
} else {
    $text = $Latin1.GetString($gs.Bytes)
    $m = [regex]::Match($text, 'OVI1 [^\r\n]*\r\nOVI2 [^\r\n]*\r\nOVI3 [^\r\n]*\r\nOVI4 [^\r\n]*\r\n')
    if (-not $m.Success) {
        Write-Warn2 'Could not locate the OVI1..OVI4 block - captions left untouched.'
    } elseif ($m.Value -match ("OVI4 .*$Width")) {
        Write-Info 'Captions already updated.'
    } else {
        $newBlock = Build-OviBlock -OriginalLength $m.Length -W $Width -H $Height
        if ($null -eq $newBlock) {
            Write-Warn2 'The new captions do not fit in the space available - left untouched.'
        } else {
            if ($state.OviOffset -eq 0) {
                $state.OviOffset   = $gs.Offset + $m.Index
                $state.OviOriginal = [Convert]::ToBase64String($Latin1.GetBytes($m.Value))
            }
            Set-ArchiveBytes -Archive $archive -Offset ($gs.Offset + $m.Index) -Bytes $newBlock
            Write-Ok "Options menu now lists ${Width} X ${Height}."
        }
    }
}

# ------------------------------------------------------------------ config
Write-Head 'Step 5 of 5  -  configuration and Windows settings'
foreach ($cfg in @($docsCfg, $localCfg)) {
    if (-not (Test-Path $cfg)) { continue }
    $raw = Get-Content $cfg -Raw
    if ($raw -match '\.SIZE\s*\[\s*\.INITSIZE\s+\d+\s*\]') {
        $new = [regex]::Replace($raw, '\.SIZE\s*\[\s*\.INITSIZE\s+\d+\s*\]', ".SIZE [ .INITSIZE $INITSIZE ]")
    } else {
        $new = $raw.TrimEnd("`r", "`n") + "`r`n.SIZE [ .INITSIZE $INITSIZE ]`r`n"
    }
    if ($new -ne $raw) {
        Set-Content -Path $cfg -Value $new -Encoding ascii -NoNewline
        Write-Ok "$cfg -> .INITSIZE $INITSIZE"
    } else {
        Write-Info "$cfg already selects slot $INITSIZE."
    }
}

if (-not $NoDDrawCompat) {
    if (-not (Test-Path (Join-Path $dir 'ddraw.dll'))) { $state.InstalledDDrawCompat = $true }
    Install-DDrawCompat -Dir $dir
} else {
    Write-Info 'Skipping DDrawCompat (-NoDDrawCompat).'
}
Set-DpiFlag -ExePath $exe

$state.ArchiveDirs = Select-StateEntries $state.ArchiveDirs $state.ArchiveLength 'OldBlockOffset'
$state.MapVols     = Select-StateEntries $state.MapVols     $state.ArchiveLength 'OldOffset'
$state | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFile -Encoding utf8

# ------------------------------------------------------------------ summary
Write-Head 'Done'
Write-Host "  $($GAME.Title) now runs at ${Width}x${Height}." -ForegroundColor Green
Write-Host ''
Write-Host '  Start the game from Steam as usual. If it opens at a lower resolution,'
Write-Host "  pick the last entry in Options -> the one that reads ${Width} X ${Height}."
Write-Host ''
Write-Host '  Two things worth knowing:' -ForegroundColor White
Write-Host '   - A few small maps (the first mission among them) are narrower than your'
Write-Host '     screen, so a black strip appears on the right. Press + to zoom in and it'
Write-Host '     fills the screen. This is a limit of the 1998 engine, not of this patch.'
Write-Host '   - Verifying the game files in Steam undoes everything. Just run this'
Write-Host '     script again afterwards.'
Write-Host ''
Write-Host "  Undo everything:  .\$(Split-Path $PSCommandPath -Leaf) -Uninstall" -ForegroundColor DarkGray
Write-Host "  Backups:          $backupDir" -ForegroundColor DarkGray
Write-Host ''
