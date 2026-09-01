# commandos-1080p-fix

Run **Commandos: Behind Enemy Lines** and **Commandos: Beyond the Call of Duty** at your monitor's native resolution on Windows 10 and 11 — no stretching, no blur, no manual hex editing.

🇨🇿 **[Česká verze tohoto dokumentu →](README.cs.md)**

---

## What this is for

Both games are from 1998–1999 and their Steam re-releases still top out at **1280×720**. On a 1080p or larger screen that means either a small window or an upscaled, soft picture, plus a mouse that feels like it is dragging through treacle.

The community has solved these problems one at a time over the years — a hex-editing tutorial here, a resolution hacker there, a set of interface graphics somewhere else, a map fix on a Google Sites page that no longer serves downloads. Following all of it means finding six things, three of which are dead links, and doing a dozen manual steps per game.

**This repository does all of it in one command, per game, and can undo every bit of it.**

### What you get

- The game running at your monitor's **native resolution** — 1920×1080 by default.
- A **smooth mouse** and a stable frame rate (via DDrawCompat).
- The main menu and in-game panels drawn at the right size instead of a black screen.
- The resolution listed properly in the in-game Options menu.
- **Clean black borders** on the few maps that are smaller than a modern screen, instead of flickering leftover video memory.
- A **full uninstall** that puts every original byte back.

### Who it is not for

If you own the GOG release, or an "Ultimate Fix"/"Ammo Pack" executable, use [stevenh's Commandos Resolution Hack](https://modelrail.otenko.com/electronics/commandos-behind-enemy-lines-resolution-fix) instead — it targets those builds. This repository targets the **2016 Steam builds specifically**, which the older tool does not recognise.

---

## Table of contents

- [Quick start](#quick-start)
- [What each script changes](#what-each-script-changes)
- [Uninstalling](#uninstalling)
- [Known limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [How it works](#how-it-works)
- [Credits](#credits)
- [License](#license)

---

## Quick start

1. **Close the game and Steam's download activity.** The scripts rewrite files inside the game folder.
2. Download this repository (green **Code** button → **Download ZIP**) and unpack it anywhere.
3. Double-click **`Run-Fix.cmd`** and pick a game, or run a script directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Fix-BehindEnemyLines.ps1
```

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Fix-BeyondTheCallOfDuty.ps1
```

4. Start the game from Steam as normal. If it still opens small, go to **Options** and pick the last resolution in the list.

The scripts find the game through your Steam library configuration. If your library lives somewhere unusual, point them at it:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Fix-BehindEnemyLines.ps1 -GameDir "D:\Steam\steamapps\common\Commandos Behind Enemy Lines"
```

### Options

| Switch | Meaning |
|---|---|
| `-Width` / `-Height` | Target resolution. Defaults to your primary monitor. Only 1920×1080 ships with the interface graphics it needs — see [Known limitations](#known-limitations). |
| `-NoDDrawCompat` | Skip the DirectDraw wrapper. The resolution patch is applied either way. |
| `-GameDir` | Path to the game folder, if auto-detection fails. |
| `-Uninstall` | Put everything back the way it was. |

Administrator rights are only needed if your Steam folder is locked down; the script says so and stops rather than half-finishing.

---

## What each script changes

Everything below is backed up into `_Commandos1080Fix_Backup\` inside the game folder before it is touched.

**1. The executable** — five or six four-byte constants.

The 2016 Steam build has exactly four resolutions compiled into it: 640×480, 800×600, 1024×768 and 1280×720. The script finds every place that mentions the fourth one and rewrites it to your resolution. The places are found by byte pattern, not by hard-coded offsets, and the script refuses to write anything unless it finds the exact number of matches it expects.

**2. The game archive** — two files added.

`MENU1920.BMP` (main menu background) and `1920X1080.WAD` (top and side panels) are inserted into `WARGAME.DIR` / `WAR_MP.DIR`. Loose copies on disk are ignored by the engine for these two resources, so they have to go inside the archive. The insertion appends to the end of the archive and relocates one directory block — nothing that already exists moves, which is what keeps a fan translation intact.

**3. The maps that are smaller than your screen.**

Nine of the thirty-three maps across the two games are narrower or shorter than 1920×1080. The engine leaves the leftover strip unpainted, so you see whatever was in video memory. Each affected map gets one extra polygon covering the strip with ground tiles at minimum brightness, which renders as solid black.

**4. The Options menu captions** — the `OVI1`…`OVI4` strings in `GLOBAL.STR`, rewritten **in place at the same byte length**, so a translated archive stays valid.

**5. Configuration and Windows settings**
- `Documents\Commandos - …\OUTPUT\COMANDO.CFG` → `.SIZE [ .INITSIZE 4 ]`, selecting the new resolution.
- `ddraw.dll` — [DDrawCompat](https://github.com/narzoul/DDrawCompat) is downloaded from its GitHub releases and placed next to the executable.
- `DDrawCompat.ini` with `DisplayResolution = app`. **This line is not optional**: with DDrawCompat's default the game quits to the desktop the moment the intro movie plays.
- The `HIGHDPIAWARE` compatibility flag for the executable, so Windows display scaling does not add a second, blurrier resize on top.

Windows XP compatibility mode is deliberately **not** set. It is recommended by older guides written for the 1999 builds; on the 2016 builds it causes random freezes and audio loss.

---

## Uninstalling

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Fix-BehindEnemyLines.ps1 -Uninstall
```

This restores the original executable byte for byte, rewinds the archive to its original length and directory layout, restores the configuration files, removes `ddraw.dll` and `DDrawCompat.ini` (only if the script installed them) and clears the compatibility flag.

Verifying the game files in Steam also undoes everything — it will re-download the original executable and archive. That is a perfectly good escape hatch if something ever goes wrong. Afterwards, just run the script again.

---

## Known limitations

**Only 1920×1080 works out of the box.** Every resolution needs its own `<width>X<height>.WAD` interface file, and only the 1920×1080 one exists publicly. Passing `-Width`/`-Height` for anything else will stop with an error rather than produce a game that crashes when the first mission loads. If you have the matching `.WAD` and `MENU<width>.BMP`, drop them into `assets\` and the script will use them.

**Small maps still do not fill the screen.** The black border is a tidy-up, not a cure: the artwork for those maps ends where it ends. Nine maps are affected:

| Game | Map | Size | Note |
|---|---|---|---|
| Behind Enemy Lines | MAPA0000 | 1453 × 2450 | mission 1, "Baptism of Fire" |
| Behind Enemy Lines | MAPA0001 | 1828 × 1490 | |
| Behind Enemy Lines | MAPA0013 | 1682 × 1720 | |
| Behind Enemy Lines | MAPA0016 | 1800 × 1995 | |
| Behind Enemy Lines | MAPA0021 | 1040 × 950 | training |
| Behind Enemy Lines | MAPA0022 | 2100 × 950 | training, short only |
| Behind Enemy Lines | MAPA0023 | 1650 × 1150 | training |
| Behind Enemy Lines | MAPA0024 | 1000 × 745 | training |
| Beyond the Call of Duty | MAPA0008 | 1851 × 1015 | |

Press <kbd>+</kbd> to zoom in on those missions and the picture reaches the edges. The other twenty-four maps are larger than 1080p and are unaffected.

**Multiplayer is untouched.** The scripts only change the single-player resolution slot.

---

## Troubleshooting

**The game quits to the desktop a few seconds after starting.**
The `DDrawCompat.ini` next to the executable is missing or does not contain `DisplayResolution = app`. Re-run the script, or add the line yourself.

**"This executable does not look like the 2016 Steam build."**
Something else has already modified it. Verify the game files in Steam (Library → right-click → Properties → Installed Files → Verify integrity), then run the script again.

**The game still starts at 1024×768.**
Open Options in the game and pick the last resolution in the list. The script writes the setting into `Documents\Commandos - …\OUTPUT\COMANDO.CFG`, but the game overwrites that file when it exits, so a stale value can survive one launch.

**The mouse is still sluggish.**
Check that `ddraw.dll` is in the game folder. If the download failed (no internet, GitHub unreachable), grab it from the [DDrawCompat releases](https://github.com/narzoul/DDrawCompat/releases) and drop it next to the executable yourself.

**Everything reverted after a Steam update.**
Expected. Run the script again.

---

## How it works

The 2016 Steam builds keep the four selectable resolutions as plain immediate operands in the code, in three to four places each: the video-mode setters, an index-to-resolution table, a resolution-to-index map used when writing the config file, and — in *Beyond the Call of Duty* — a map from resolution to menu-background resource. All of them have to agree, or the game picks the wrong menu graphic or writes a config it cannot read back.

The `.DIR` archives are a flat tree of 44-byte records: a 32-byte name, a type byte (0 = file, 1 = directory, 0xFF = end of directory), a size and an offset. Adding a file means appending its data, appending a rebuilt copy of the parent directory's record block with one extra record, and repointing the parent at the new block. Replacing a file's contents is even simpler: append the new bytes and rewrite the record's size and offset. Both are append-only operations, so uninstalling is a matter of restoring a handful of four-byte fields and truncating the file back to its original length.

The map fix comes from Ferdinand Zeppelin's `ResolutionFix_VOLfix`: a `POLY "WIDESCREENFIX"` block whose tiles are drawn at brightness `-20`, the engine's minimum, which renders as solid black. The script derives the tile geometry from each map's own `MAPDIMXY` declaration and borrows a ground texture the map already loads.

---

## Credits

This repository is glue. The hard parts were worked out by other people:

- **[stevenh (otenko)](https://modelrail.otenko.com/electronics/commandos-behind-enemy-lines-resolution-fix)** — the original Commandos Resolution Hack, and the write-up that documents which parts of the executable have to be kept in sync.
- **Ferdinand Zeppelin** — `MENU1920.BMP`, `1920X1080.WAD`, and the `ResolutionFix_VOLfix` method used for the map borders.
- **[Kruulos](https://steamcommunity.com/sharedfiles/filedetails/?id=395264353)** — the Steam guide that ties the pieces together and hosts the file bundle.
- **[commandosmod](https://sites.google.com/site/commandosmod/tutorials/bel_widescreen)** — the original widescreen hex-edit tutorial.
- **[narzoul](https://github.com/narzoul/DDrawCompat)** — DDrawCompat, which is what actually makes these games pleasant on modern Windows.

The two files in `assets/` are community work redistributed here so the scripts run without hunting for dead links; see [assets/CREDITS.md](assets/CREDITS.md). Commandos is © Pyro Studios / Eidos. This project is not affiliated with them and contains no game code.

## License

The scripts are MIT licensed — see [LICENSE](LICENSE). The files in `assets/` are not covered by it; they belong to their authors.
