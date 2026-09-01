# commandos-1080p-fix

Rozjeďte **Commandos: Behind Enemy Lines** a **Commandos: Beyond the Call of Duty** v nativním rozlišení monitoru na Windows 10 a 11 — bez roztahování, bez rozmazání a bez ručního editování v hex editoru.

🇬🇧 **[English version of this document →](README.md)**

---

## K čemu to je

Obě hry jsou z let 1998–1999 a jejich steamovská reedice se pořád zastaví na **1280×720**. Na monitoru s Full HD a větším to znamená buď malé okno, nebo měkký přeškálovaný obraz — a k tomu myš, která se táhne jako v medu.

Komunita si s tím poradila, ale po částech a v průběhu let: tady návod na hex editaci, tam resolution hacker, jinde sada grafik rozhraní a oprava map na Google Sites, která už soubory nevydává. Projít to všechno znamená najít šest věcí, z toho tři na mrtvých odkazech, a udělat u každé hry tucet ručních kroků.

**Tenhle repozitář to udělá jedním příkazem na hru — a umí to celé vrátit zpět.**

### Co dostanete

- Hru běžící v **nativním rozlišení monitoru** — ve výchozím stavu 1920×1080.
- **Plynulou myš** a stabilní snímkování (díky DDrawCompat).
- Hlavní menu a herní panely vykreslené ve správné velikosti místo černé obrazovky.
- Rozlišení správně vypsané v herních Volbách.
- **Čistě černé okraje** u těch pár map, které jsou menší než dnešní obrazovka, místo blikajícího smetí z videopaměti.
- **Úplnou odinstalaci**, která vrátí každý původní bajt.

### Pro koho to není

Pokud máte verzi z GOGu nebo spustitelný soubor z „Ultimate Fixu" / „Ammo Packu", použijte radši [Commandos Resolution Hack od stevenh](https://modelrail.otenko.com/electronics/commandos-behind-enemy-lines-resolution-fix) — ten cílí právě na tyhle buildy. Tenhle repozitář je dělaný **konkrétně na steamovské buildy z roku 2016**, které starší nástroj vůbec nerozpozná.

---

## Obsah

- [Rychlý start](#rychlý-start)
- [Co skripty mění](#co-skripty-mění)
- [Odinstalace](#odinstalace)
- [Známá omezení](#známá-omezení)
- [Řešení problémů](#řešení-problémů)
- [Jak to funguje](#jak-to-funguje)
- [Poděkování](#poděkování)
- [Licence](#licence)

---

## Rychlý start

1. **Zavřete hru** a počkejte, až Steam dostahuje, co má. Skripty přepisují soubory ve složce hry.
2. Stáhněte repozitář (zelené tlačítko **Code** → **Download ZIP**) a rozbalte kamkoliv.
3. Spusťte **`Run-Fix.cmd`** a vyberte hru, nebo pusťte skript přímo:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Fix-BehindEnemyLines.ps1
```

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Fix-BeyondTheCallOfDuty.ps1
```

4. Spusťte hru ze Steamu jako obvykle. Kdyby se přesto otevřela v malém, jděte do **Voleb** a vyberte poslední rozlišení v seznamu.

Skripty si hru najdou podle konfigurace steamovské knihovny. Pokud ji máte na netypickém místě, ukažte na ni:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Fix-BehindEnemyLines.ps1 -GameDir "D:\Steam\steamapps\common\Commandos Behind Enemy Lines"
```

### Přepínače

| Přepínač | Význam |
|---|---|
| `-Width` / `-Height` | Cílové rozlišení. Výchozí je hlavní monitor. Grafiky rozhraní jsou přibalené jen pro 1920×1080 — viz [Známá omezení](#známá-omezení). |
| `-NoDDrawCompat` | Přeskočí DirectDraw wrapper. Oprava rozlišení se provede tak jako tak. |
| `-GameDir` | Cesta ke složce hry, když automatické hledání selže. |
| `-Uninstall` | Vrátí všechno do původního stavu. |

Práva správce jsou potřeba jen tehdy, když máte steamovskou složku uzamčenou. Skript to pozná a rovnou skončí, místo aby práci nedodělal.

---

## Co skripty mění

Všechno níže se před zásahem zazálohuje do `_Commandos1080Fix_Backup\` uvnitř složky hry.

**1. Spustitelný soubor** — pět nebo šest čtyřbajtových konstant.

Steamovský build z roku 2016 má natvrdo zakompilovaná právě čtyři rozlišení: 640×480, 800×600, 1024×768 a 1280×720. Skript najde všechna místa, která zmiňují to čtvrté, a přepíše je na vaše rozlišení. Místa se hledají podle bajtového vzoru, ne podle napevno zapsaných offsetů, a skript nic nezapíše, dokud nenajde přesně tolik výskytů, kolik očekává.

**2. Herní archiv** — přidají se dva soubory.

`MENU1920.BMP` (pozadí hlavního menu) a `1920X1080.WAD` (horní a boční panel) se vloží dovnitř `WARGAME.DIR` / `WAR_MP.DIR`. Volně ležící kopie na disku engine u těchto dvou zdrojů ignoruje, takže musí být uvnitř archivu. Vkládání jen připojuje data na konec a přesouvá jeden adresářový blok — nic stávajícího se nehýbe, a právě proto zůstane případný fanouškovský překlad nedotčený.

**3. Mapy menší než obrazovka.**

Devět z třiatřiceti map v obou hrách je užších nebo nižších než 1920×1080. Engine zbylý pruh nevykreslí, takže v něm vidíte, co zrovna zbylo ve videopaměti. Každá taková mapa dostane jeden polygon navíc, který pruh překryje dlaždicemi terénu na minimálním jasu — a ten se vykreslí jako plná černá.

**4. Popisky ve Volbách** — řetězce `OVI1`…`OVI4` v `GLOBAL.STR` se přepíšou **na místě a na stejnou délku v bajtech**, takže přeložený archiv zůstane platný.

**5. Konfigurace a nastavení Windows**
- `Dokumenty\Commandos - …\OUTPUT\COMANDO.CFG` → `.SIZE [ .INITSIZE 4 ]`, čímž se předvolí nové rozlišení.
- `ddraw.dll` — [DDrawCompat](https://github.com/narzoul/DDrawCompat) se stáhne z jeho GitHub releases a položí vedle spustitelného souboru.
- `DDrawCompat.ini` s `DisplayResolution = app`. **Tenhle řádek není volitelný**: s výchozím nastavením DDrawCompatu se hra ukončí do Windows ve chvíli, kdy se pustí úvodní video.
- Příznak kompatibility `HIGHDPIAWARE` pro spustitelný soubor, aby Windows nepřidávaly ještě jedno, rozmazanější přeškálování navrch.

Režim kompatibility s Windows XP se záměrně **nenastavuje**. Doporučují ho starší návody psané pro buildy z roku 1999; na buildech z roku 2016 způsobuje náhodná zamrznutí a ztrátu zvuku.

---

## Odinstalace

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Fix-BehindEnemyLines.ps1 -Uninstall
```

Obnoví se původní spustitelný soubor bajt po bajtu, archiv se vrátí na původní délku i adresářové rozvržení, obnoví se konfigurační soubory, smaže se `ddraw.dll` a `DDrawCompat.ini` (jen pokud je nainstaloval skript) a zruší se příznak kompatibility.

Ověření integrity souborů ve Steamu udělá totéž — stáhne původní spustitelný soubor i archiv. Je to naprosto použitelná záchranná brzda, kdyby se někdy něco pokazilo. Potom stačí skript spustit znovu.

---

## Známá omezení

**Bez dalších souborů funguje jen 1920×1080.** Každé rozlišení potřebuje vlastní soubor rozhraní `<šířka>X<výška>.WAD` a veřejně existuje jen ten pro 1920×1080. Zadání `-Width`/`-Height` na cokoliv jiného skončí chybou — raději než hrou, která spadne při načítání první mise. Pokud odpovídající `.WAD` a `MENU<šířka>.BMP` máte, dejte je do složky `assets\` a skript je použije.

**Malé mapy pořád nevyplní obrazovku.** Černý okraj je uklizení, ne léčba: grafika těch map prostě končí tam, kde končí. Dotčených map je devět:

| Hra | Mapa | Rozměr | Poznámka |
|---|---|---|---|
| Behind Enemy Lines | MAPA0000 | 1453 × 2450 | 1. mise, „Křest ohněm" |
| Behind Enemy Lines | MAPA0001 | 1828 × 1490 | |
| Behind Enemy Lines | MAPA0013 | 1682 × 1720 | |
| Behind Enemy Lines | MAPA0016 | 1800 × 1995 | |
| Behind Enemy Lines | MAPA0021 | 1040 × 950 | výcvik |
| Behind Enemy Lines | MAPA0022 | 2100 × 950 | výcvik, jen na výšku |
| Behind Enemy Lines | MAPA0023 | 1650 × 1150 | výcvik |
| Behind Enemy Lines | MAPA0024 | 1000 × 745 | výcvik |
| Beyond the Call of Duty | MAPA0008 | 1851 × 1015 | |

V těchto misích stiskněte <kbd>+</kbd> pro přiblížení a obraz dosáhne k okrajům. Zbývajících čtyřiadvacet map je větších než Full HD a nic se jich netýká.

**Multiplayer zůstává nedotčený.** Skripty mění jen slot rozlišení pro hru jednoho hráče.

---

## Řešení problémů

**Hra se pár vteřin po spuštění sama ukončí.**
Vedle spustitelného souboru chybí `DDrawCompat.ini`, nebo v něm není `DisplayResolution = app`. Spusťte skript znovu, nebo řádek doplňte ručně.

**„This executable does not look like the 2016 Steam build."**
Soubor už něco jiného upravilo. Ověřte integritu souborů ve Steamu (Knihovna → pravé tlačítko → Vlastnosti → Nainstalované soubory → Ověřit integritu) a pak skript spusťte znovu.

**Hra pořád startuje v 1024×768.**
Otevřete ve hře Volby a vyberte poslední rozlišení v seznamu. Skript nastavení zapisuje do `Dokumenty\Commandos - …\OUTPUT\COMANDO.CFG`, ale hra si tenhle soubor při ukončení přepisuje, takže stará hodnota může jedno spuštění přežít.

**Myš je pořád trhaná.**
Zkontrolujte, jestli je ve složce hry `ddraw.dll`. Když se stahování nepovedlo (bez internetu, nedostupný GitHub), stáhněte ho z [releases DDrawCompatu](https://github.com/narzoul/DDrawCompat/releases) a položte vedle spustitelného souboru ručně.

**Po aktualizaci Steamu se všechno vrátilo zpátky.**
To se čeká. Spusťte skript znovu.

---

## Jak to funguje

Steamovské buildy z roku 2016 mají čtyři volitelná rozlišení uložená jako obyčejné konstanty přímo v kódu, každé na třech až čtyřech místech: nastavovače video režimu, tabulka index → rozlišení, mapa rozlišení → index použitá při zápisu konfigurace a — v *Beyond the Call of Duty* — ještě mapa rozlišení → zdroj pozadí menu. Všechna místa se musí shodovat, jinak hra sáhne po špatné grafice menu nebo si zapíše konfiguraci, kterou pak neumí přečíst.

Archivy `.DIR` jsou plochý strom 44bajtových záznamů: 32 bajtů jméno, bajt typu (0 = soubor, 1 = adresář, 0xFF = konec adresáře), velikost a offset. Přidat soubor znamená připojit jeho data, připojit přestavěnou kopii adresářového bloku rodiče s jedním záznamem navíc a přesměrovat rodiče na nový blok. Nahradit obsah souboru je ještě jednodušší: připojit nová data a přepsat v záznamu velikost a offset. Obojí jen připojuje, takže odinstalace je otázkou obnovení několika čtyřbajtových polí a zkrácení souboru na původní délku.

Oprava map pochází z `ResolutionFix_VOLfix` od Ferdinanda Zeppelina: blok `POLY "WIDESCREENFIX"`, jehož dlaždice se kreslí s jasem `-20`, což je minimum enginu a vykreslí se jako plná černá. Skript si geometrii dlaždic odvodí z deklarace `MAPDIMXY` každé mapy a půjčí si texturu terénu, kterou už daná mapa načítá.

---

## Poděkování

Tenhle repozitář je jen lepidlo. Těžkou práci odvedli jiní:

- **[stevenh (otenko)](https://modelrail.otenko.com/electronics/commandos-behind-enemy-lines-resolution-fix)** — původní Commandos Resolution Hack a rozbor, který dokumentuje, která místa ve spustitelném souboru spolu musí souhlasit.
- **Ferdinand Zeppelin** — `MENU1920.BMP`, `1920X1080.WAD` a metoda `ResolutionFix_VOLfix` použitá pro černé okraje map.
- **[Kruulos](https://steamcommunity.com/sharedfiles/filedetails/?id=395264353)** — steamovský návod, který jednotlivé kousky spojuje dohromady, a hostování balíku souborů.
- **[commandosmod](https://sites.google.com/site/commandosmod/tutorials/bel_widescreen)** — původní návod na širokoúhlou hex editaci.
- **[narzoul](https://github.com/narzoul/DDrawCompat)** — DDrawCompat, díky kterému jsou tyhle hry na moderních Windows vůbec příjemné.

Dva soubory ve složce `assets/` jsou komunitní práce, přiložená sem proto, aby skripty fungovaly bez lovení mrtvých odkazů; viz [assets/CREDITS.md](assets/CREDITS.md). Commandos je © Pyro Studios / Eidos. Tento projekt s nimi nemá nic společného a neobsahuje žádný herní kód.

## Licence

Skripty jsou pod licencí MIT — viz [LICENSE](LICENSE). Soubory ve složce `assets/` pod ni nespadají, patří svým autorům.
