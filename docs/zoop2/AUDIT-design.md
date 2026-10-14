# Zoop 2.0 design audit (iOS, simulator, German)

Method: `ZoopiOS` built for the iOS Simulator, launched with `--demo-seed -AppleLanguages "(de)"` on iPhone 18 Pro. Walked Heute, Training, Einblicke, Mehr, the ring detail pages (Schlaf, Erholung, Belastung), Stress, Energiekonto, Gesundheitsmonitor, Fitnessalter, Settings, Coach sheet, Devices sheet and the "+" quick-actions sheet.

Themes actually seen: Pastell dark, Klassisch dark, Klassisch light, Pastell light. Pastell dark, Klassisch dark and Klassisch light were walked page by page, but only Home and Stress (Klassisch) and Home and Training (Pastell light) were seen in the light variants. Not every screen was checked in every theme.

Screenshots: `/private/tmp/claude-501/-Users-ben-Documents-Github-zoop/8f4927f2-d0e2-4842-81ce-a2ede45f1833/scratchpad/audit-shots/`

Naming: the `pdark-*.png` files are Pastell dark. This is because the first launch started in Pastell, even though I asked for classic. The `classic-*`/`cdark-*` files are Klassisch dark (`cdark-*` only for Home, Sleep and Stress). `cLight-*` is Klassisch light and `pLight-*` is Pastell light.

Caveat on demo data: much of the emptiness is the demo seed. Sleep, Energiekonto and Gesundheitsmonitor have no data for "today", and the latest data is 6 Oct while the simulator date is 14 Oct. Items below that depend on seed data are marked (seed).

Note on theme switching: the plist trick did not take effect (cfprefsd rewrote it). I switched themes in the app UI (avatar sheet, Erscheinungsbild).

## Cross-cutting problems (fix these first, they hit many screens)

| # | Issue | Evidence | File / fix | Effort |
|---|---|---|---|---|
| X1 | Decimal separator is a dot in German. "45.2 /100", "52.5 / 200.0", "75.0 kg", "27.8" (workout list), "7.2 h", "-1.5%", "1.0" step calibration, while other places correctly show "25,5", "3,0" | `pdark-strainA.png`, `pdark-train2.png`, `pdark-train4.png`, `pdark-home2.png`, `pdark-sleepE.png`, `pdark-set3.png` | There are about 96 `String(format: "%.1f", ...)` call sites in `Strand/`, for example `Strand/Screens/TrainingLoadCard.swift:99` and `Strand/Screens/MetricExplorerView.swift:1657/1685`. The metric formatter `metric.format(...)` used by `MetricExplorerView.fmt` (`:784`) also emits dots. Add one `ZoopNumber.format(_:fractionDigits:)` that uses `FormatStyle` (`.number.precision(.fractionLength(n))`), then replace all call sites. Add a test that greps for `String(format: "%.` in the UI layer. | M (mechanical, many files) |
| X2 | Untranslated English in a German UI | "Coach runs on an AI provider with your own key..." (`pdark-coach.png`); picker values "Line", "WHOOP Blue", "Ocean"; "Pearson r ... n >= 10" jargon | `StrandiOS/App/CoachChatSheet.swift:600` (a plain `String` in a ternary, so it bypasses localization; wrap in `String(localized:)`). Appearance settings in `Strand/Screens/SettingsView.swift` for Line, Ocean and WHOOP Blue. Run `Tools/i18n_audit.py`. | S |
| X3 | One detail-page template shows the same fact two or three times. Erholung/Belastung: nav title "Erholung", overline "ERHOLUNG", card title "Erholung", chart title "Erholung" (four times). "Stand 6 Okt. 2026" and "30 Messwerte · Monat" appear in both the hero card and the chart header. "Aktuellste 9 %" appears in the stat row at the top (FENSTER / PUNKTE / AKTUELLSTE), the chart header, and the Min/Max/Aktuellste tiles. | `pdark-sleep1.png`, `pdark-rec2.png`, `pdark-rec3.png`, `pdark-strainA.png` | `Strand/Screens/MetricExplorerView.swift` (`hero` around `:1602`, `StatTile` rows around `:1659/1681`). Keep the nav title and the ring. Delete the overline, the duplicate chart header, and the FENSTER/PUNKTE/AKTUELLSTE row. | M |
| X4 | Stats that state the same value two ways and can contradict each other: tile "Δ vs. vorher -1 %" next to chip "-1.5%". Also "vs. vorherige Monat" (wrong German case). | `pdark-rec4.png` | `MetricExplorerView.swift:1657-1690`. Show one delta (percent or points), fix the string ("vs. vorherigem Monat"). The chip is also a tinted pill (violates "no badges"): make it plain text. | S |
| X5 | Charts without units or baseline. Home Wochentrends (Erholung, HRV) are empty boxes with day columns and no y-axis, unit or caption; Sleep "Bilanz" bar chart, Sleep "Beste Schlafenszeit" and "Schlaf für Erholung" show grey placeholder blocks that read as broken; Einblicke mini-charts are unlabelled. | `pdark-home4.png`, `pdark-home5.png`, `pdark-sleepE.png`, `pdark-sleepF.png`, `pdark-ins1.png` | Home trend cards in `Strand/Liquid/LiquidTodayView.swift`; sleep cards in `Strand/Screens/SleepInsightsSection.swift`, `SleepDebtLedgerCard.swift`, `HoursVsNeededCard.swift`. Rule: when there is no data, show one line of text instead of an empty chart frame; when there is data, show a labelled baseline and the unit in the header. | M |
| X6 | "Empty" states that look broken: dash plus "Noch keine Messwerte" (Energiekonto), a card with "-" and nothing else (Gesundheitsmonitor on Home), Gesundheitsmonitor vitals showing a faded sparkline AND "Keine Daten" AND an empty ring AND "-" together. | `pdark-home1b.png`, `pdark-energyA.png`, `pdark-healthA.png` | `Strand/Liquid/HomeMonitorTiles.swift` (`:183-199`), `Strand/Liquid/EnergyBankViews.swift`, `Strand/Screens/HealthView.swift`. One empty-state: a single sentence saying what is needed ("Trage den Strap im Schlaf, dann erscheint dein Energiekonto"). No placeholder sparkline, ring or dash. | M |
| X7 | Tinted capsule badges still present, against the project rule. "Kostenlos" capsule in the Coach provider list; "Aktiv"/"Gekoppelt" in the Devices sheet; "↗ +11" / "↘ -15" trend chips on Stress markers; source chips "Whoop"/"Apple" in the workout list; the "Optimal" label on the Cardio gauge. | `pdark-coach.png`, `pdark-bolt.png`, `pdark-stressA.png`, `pdark-train4.png` | `StrandiOS/App/CoachChatSheet.swift:667-672` (explicit `Capsule()`), `Strand/Screens/DevicesView.swift`, `Strand/Screens/StressView.swift` (marker tiles). Replace with plain secondary text. | S |
| X8 | Section header styles are mixed. Cards use title case ("Schlaf für heute Nacht"), the Home heart-rate card uses a spaced uppercase "SCHLÄGE PRO MINUTE", others use an uppercase overline ("DATENQUELLEN", "ERHOLUNG", "SITZUNGEN"), and page titles switch between a floating nav title (Erholung/Belastung) and a large left title (Stress, Energiekonto, Gesundheitsmonitor, Einstellungen). | `pdark-home4.png`, `pdark-rec2.png`, `pdark-stressA.png` | Pick one. Remove `.strandOverline()` from card titles; pick one page title scheme in `Strand/Screens/ScreenScaffold.swift` and make the metric detail page use it. | M |
| X9 | The floating back button overlaps content. On scroll, content slides under the round back button (clips "Schlafphase" label, "22:40" heading, chart tops). On Stress, the title "Stress" is only about 25 pt below the button, and the live-data card label ("Jetzt", `StressDayHero.headerLabel`, `Strand/Screens/StressDayHero.swift:65`) lands on the same row as the button on shorter or larger-text devices. | `pdark-sleepC.png`, `pdark-sleepE.png`, `pdark-stressA.png` | `ScreenScaffold.swift:54-55` uses `.padding(.top, 24)` as the only clearance. Add an explicit top inset equal to the back-button height plus a gap (about 56 pt) on screens that are pushed (not tab roots), and a soft top fade/material under the button so scrolling content does not run beneath it. | S/M |
| X10 | Theme parity: Pastell uses circular rings, Klassisch uses squircle rings (the design direction wants squircles everywhere). Greeting ("Guten Abend, BenBen") exists only in Pastell (`LiquidTodayView.swift:2700 pastelGreeting`). In Klassisch light the ring tracks are nearly invisible on the white-grey canvas. | `pdark-home1.png`, `classic-dark-home.png`, `cLight-home.png` | `Packages/StrandDesign` ring component (the ring shape is theme-switched); ring track colour token in `Palette.swift` for classic light needs a darker track. | S |
| X11 | Duplicate navigation/info: "Sicherung" is in Mehr > Daten and again in Einstellungen > Daten; Einblicke repeats the Gesundheitsmonitor content (Vitalwerte + Hauttemperatur/Zyklus) that Home links to; Sleep shows "Schlafdefizit" in three places (Schlaffaktoren, Bilanz, tag); Home "Schlaf für heute Nacht" also appears in Sleep ("Heute Nacht 22:57 -> 07:00"); Devices appear in the bolt sheet and in Mehr. | `pdark-more2.png`, `pdark-set1.png`, `pdark-ins2.png`, `pdark-sleepD.png` | Mehr/Settings in `Strand/Screens/SettingsView.swift` and the iOS Mehr list in `StrandiOS/App/RootTabView.swift`; Einblicke in `Strand/Screens/InsightsHubView.swift`. Remove one of each pair. | M |

## Per screen, ranked fix list

### Heute (Home)
1. **Greeting "BenBen"**. The name is duplicated. Check demo profile name in `Strand/Data/DemoDayHarness.swift`/`Profile.swift`; if the first-name split is wrong for the real profile, fix `pastelGreeting` (`LiquidTodayView.swift:2700`). (seed?) S.
2. **Layout jump**: a "Strap nicht verbunden" banner appears after a few seconds and pushes the whole page down about 58 pt (`classic-dark-home` vs the first screenshot), which also moves tap targets. Reserve the space or overlay it. `LiquidTodayView.swift`. S.
3. **Rings inconsistent with detail**: Home shows "--%" for Sleep but the Sleep page shows 89 (6 Oct, with a "not synchronised" banner). Belastung ring shows "--" with a visible arc and "Ziel 19-48" with no scale, while the detail page says "/100" and Training says "/200". Pick one scale and show the unit. `LiquidTodayView.swift`, `MetricExplorerView.swift`, `TrainingLoadCard.swift`. M.
4. **Tile text sizes**: "Gesundheitsmonitor" title renders smaller than "Stress-Monitor" (`HomeMonitorTiles.swift:189` vs `:223` use the same font, so the label is probably shrinking to fit; shorten the label or drop the auto-shrink). S.
5. Stress tile "3,0 / 3 · Hoch · heute Morgen": a 3.0 of 3 reads as the maximum with no baseline. Drop "Hoch · heute Morgen" or give one sentence. S.
6. "Mein Dashboard": Weight "75.0 kg" (dot), Steps "-", Kalorien "- / Ø 604 kcal" (a dash plus an unexplained average). Hide rows without data. `DashboardCards.swift`. S.
7. Heart-rate card "SCHLÄGE PRO MINUTE": huge empty box with "Strap nicht verbunden" plus an instruction; use the shared card header style and cut the height. `Strand/Screens/TodayView.swift`/`HostedCards.swift`. S.
8. Wochentrends: empty frames, no axis (see X5). M.
9. "Datenquellen: Synchronisiert aus / Quellen ansehen" with no source named (`pdark-home5.png`). S.

### Erholung / Belastung (metric detail)
See X3, X4. Extra:
1. Chart drops to 0 at the start and the end (spurious zero points drawn as cliffs, y-axis shows 20-60 but the line reaches 0). Filter missing days instead of plotting zero (`MetricExplorerView` series build, `exploreSeries`). (seed?) M.
2. Hero shows "Stand 6 Okt. 2026" while today is 14 Oct. Say "Letzte Messung vor 8 Tagen". S.
3. Range chips: "1J" is disabled/greyed with no explanation. S.
4. "Was korreliert: Pearson r über den sichtbaren Bereich · |r| ≥ 0,30, n ≥ 10" is jargon and the tile layout leaves an orphan; replace with one sentence ("Diese Werte bewegen sich mit deiner Erholung") and drop "n = 30" per row (`MetricExplorerView.swift:1846`). S.
5. "Woher deine Erholung kommt": +/-0 columns have no meaning; show the value vs baseline in words. Also "Aktuellste" is misspelled-looking German; use "Zuletzt". S.
6. Belastung header wraps: "45.2 /100 · Stand 6 Okt. / 2026" breaks across two lines. S.

### Schlaf
1. Banner "Schlaf der letzten Nacht wurde nicht synchronisiert" above a score of 89 for a different night; the score has no date next to it. `SleepView.swift`. S.
2. The page title is a large centered "Schlaf" while the other detail pages use the nav title. See X8. S.
3. Nested cards: Schlaffaktoren tiles sit inside another card with an orphan third tile. `SleepFactorGrid.swift`. S.
4. "Schlafdauer" shows "7.2 h Ø" in the header AND "Ø 7.2 h" in the footer, with a dot decimal. S.
5. Grey placeholder blocks in "Schlaf für Erholung", "Beste Schlafenszeit" (X5). M.
6. "Werte der Nacht: -15 ms / +11 bpm" in tinted colours with no meaning for the colour (is +11 bpm bad?). Add "vs. dein Durchschnitt". S.
7. The end of the page is very long (nine cards); cut to four. L (product decision).

### Stress
1. Title/back button spacing (X9). S.
2. "Ruhezeit" tile truncates its caption ("Tage mit wenig Stress ·..."), and the layout leaves a single tile alone on the last row. `StressView.swift`. S.
3. The three "Marker" tiles carry trend chips ("↗ +11"); make them plain text. S.
4. "Wie das berechnet wird" is a long paragraph (line 721); one sentence. S.
5. The chart shows "3,0 / 1,5 Durchschnitt" and "Tage 30" in uppercase mini-labels; fine but add the baseline line at 1.5. S.

### Energiekonto
Blank page with a dash and one sentence; looks broken. Duplicates the Home tile's empty message. `EnergyBankViews.swift`. See X6. S.

### Gesundheitsmonitor
1. Five tiles each showing ring, dash, "Keine Daten" and a sparkline at the same time (contradiction). `HealthView.swift`. M.
2. Whole-page text: three disclaimers ("Keine medizinische Beratung", "Nur zur Orientierung", "Diese Daten verlassen dein Gerät nur...") stacked in one card. Merge into one. S.
3. Content repeats on Einblicke (X11).

### Fitnessalter
1. Gauge touches the screen edges and its end labels "24,5" and "35,0" are rotated and cramped. `FitnessAgeViews.swift`. S.
2. The 90-day chart drops from 34 to 25 in the final days (looks like a bug), with an unlabelled dashed line. S.
3. Different visual language: gradient background and a large centred gauge, while every other detail page is flat cards. S.
4. Row deltas "-1,6 Jahre", "+0,1" use colour only; add the word "besser/schlechter" at most once. S.

### Training
1. **Contradiction (seed)**: Muskelregeneration says "Kein Training in den letzten 7 Tagen" while the header says "5 Sitzungen · letzte 7 Tage". `Strand/Screens/MuscleLoadCard.swift:62` is based on a different 7-day window than `WorkoutsView`. Use one window source. M.
2. Muskelregeneration lists eight muscle groups at "100 % erholt" each with grey figure art; heavy visual noise. Show only the muscles that are not recovered. M.
3. Belastung appears on a 0-100 scale in the "Typische Anstrengung" ring (33,3 von 100), then on a 0-200 gauge ("52.5 / 200.0", with dots). See X1/Home item 3. M.
4. "Whoop-Import" overline (`WorkoutsView.swift:1261` `overline: "Whoop import"`): brand name and English-style phrase. Rename to "Importiert". S.
5. Session list rows truncate ("25m..", "24m ·..") and show "Whoop"/"Apple" source chips. Drop the source or give it its own line. `WorkoutsView.swift`. S.
6. "Typische Anstrengung" and the later "Trainingsbelastung" heading are the same topic; merge. M.

### Einblicke
1. Mini-charts (scatter, bars, zone bar) have no axes or units; the headline numbers ("+0,2 Pkt. je 10 Belastung", "1 Tag", "53 % hart") need a half sentence of meaning each. `InsightsHubView.swift`. M.
2. Includes the Gesundheitsmonitor block (X11). S.
3. Recovery trend chart ends with a drop to 0 and puts the x labels inside the plot. M.

### Mehr and Einstellungen
1. Subtitles truncate ("Alter, Körper, Herzfrequenzzonen, Ein...", "Export, Import, automatische Sicherun..."). Shorten each to about 25 characters. `SettingsView.swift`. S.
2. Profil & Einheiten: "Max. Herzfrequenz" row shows "Auto-matisch" hyphenated across three lines, "Taille (optional)" wraps, age "30" sits beside the date pill, steppers mixed with menus and one-line labels. `SettingsView.swift` profile section. M.
3. Settings screens are walls of grey body text (step calibration, motion, day-cycle background). One sentence per setting. L.
4. Appearance sheet: heading "Erscheinungsbild" twice (title and card header). S.
5. Mehr icons inconsistent (Sicherung & Sync uses a stack glyph, Mi Band a runner). S.
6. Settings opens as a sheet from the avatar but as a pushed page from Mehr; two chromes (Fertig vs back button). S.

### Sheets
1. Coach setup: English intro line (X2), "Kostenlos" capsule (X7). `CoachChatSheet.swift:600,667`. S.
2. Devices sheet: dense paragraphs with asterisks ("HRV (live)*", "Hauttemp.*"), "Aktiv" and "Gekoppelt" badges, Polar and WHOOP both described with 3 sentences each. `DevicesView.swift`. M.
3. Quick actions ("+"): fine, flat. No issues.

## Suggested order

1. X1 decimals (S per file, M total; visible everywhere).
2. X2 English strings and X7 capsules (S).
3. X9 back-button overlap and Stress spacing (S/M).
4. X6 empty states and the Training 7-day contradiction (M).
5. X3/X4 detail-page de-duplication (M).
6. X5 charts without axes (M).
7. X10 theme parity, then X8 and X11 (M).
