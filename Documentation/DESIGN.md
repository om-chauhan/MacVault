# MacVault Visual Direction

This describes MacVault's visual language. It was distilled from four third-party reference shots (Dribbble and UI kits) that are **not distributed with this repository**, because they aren't ours to license. The table below records what was taken from each, and the notes refer to them as refs 01–04. Match the language, never the content, brands or data of the originals.

| Reference | What to take from it |
|---|---|
| 01: light dashboard cards | Light theme baseline. White cards with large radius on a soft grey canvas. Card header: coloured icon, bold title, info glyph, actions grouped in a subtle pill (expand · edit · more). Huge bold numbers with small units ("94–127 BPM"), quiet grey labels above. Delta pills ("↑12% vs last year"). Bar chart with one highlighted bar, a value bubble and a dotted average line with a black "Avg" tag. Thin, light gridlines and axis labels. |
| 02: dark glow report | Dark theme. Near-black cards on a dark canvas with soft shadows. Monospaced tabular numbers. Vivid gradient data shapes that glow against black. Value labels in black pills on the chart. Clean table rows with hairline separators below the chart. |
| 03: bold colour tiles | Bold tile mix: dark tiles next to saturated accent tiles (lime, violet, peach) with very large radius. Uppercase pill tags ("EXPENSES", "PERFORMANCE"). A segmented ring around a giant number. Legend rows: coloured dot, label, right-aligned percentage. Rounded bars with percentage labels on top. A weekly/monthly segmented switch inside the card. |
| 04: widget grid | Apple widget grid: small, medium and large tiles in a strict grid, consistent padding, system font, coloured tiles for single-purpose info, activity rings, compact lists with secondary lines. |

## Design language for MacVault

- **Canvas and cards.** Content sits on a quiet canvas (light: soft grey; dark: near-black) in cards with large continuous corner radius (about 16–20 pt), generous inner padding (16–24 pt), no heavy borders (hairline at most) and a soft shadow in light mode. Cards align to a widget grid: small (1×1), medium (2×1) and large (2×2) tiles that reflow with window width.
- **Card anatomy.** Header row: tinted SF Symbol, bold title, optional info button (`.help` popover), and a trailing actions pill (refresh, open, more). Then a hero number, its label, an optional delta pill, and a chart or list.
- **Numbers are the hero.** Big, bold, rounded digits (`.system(size:, weight: .bold, design: .rounded)` with `.monospacedDigit()`), units smaller and secondary ("412 GB" with the unit at about 50% size). Labels small, secondary, sentence case; pill tags uppercase.
- **Colour.** A small palette of accent hues: one per feature, used for its icon, chart and tile (e.g. Storage: blue/indigo, Cleaner: green, Developer: violet, Apps: orange, Duplicates: teal, warnings: amber, errors: red). Exact values are defined once in `DesignSystem.swift`, with light and dark variants checked for contrast. Saturated "bold tiles" (ref. 03) are for at most one or two hero tiles per screen, not everything.
- **Charts (Swift Charts).** Rounded bars, one highlighted bar with a value bubble, dotted average rule with an "Avg" tag, gradient area fills, rings/donuts with gaps between segments, minimal axes and gridlines. Dark mode may use a soft glow/gradient (ref. 02); light mode stays crisp (ref. 01).
- **Pills and badges.** Delta pills (↑/↓ with green/red tint and a symbol), status pills, uppercase tag pills, value bubbles on charts, and segmented switches styled as pills.
- **Lists inside cards.** Legend-style rows (dot · label · right-aligned value) with hairline separators, as in refs 02 and 03.
- **Native, not a web page.** System font (SF Pro / SF Rounded / SF Mono), SF Symbols, standard controls where people expect them (tables, sheets, menus, settings forms), full light and dark support, Reduce Motion, VoiceOver labels on every card and chart (`.accessibilityChartDescriptor` or summary labels), and no colour-only meaning.

## Real data only

The references use decorative sample data. MacVault never shows invented numbers. Every card and chart must be driven by real observations, and hidden or replaced by an honest empty state when there is no data yet. Mapping:

| Reference pattern | MacVault use (real data) |
|---|---|
| Hero number with label and delta pill (01, 03) | Available space on a volume; delta pill = change since the oldest snapshot in the last 7 days, shown only when two snapshots exist |
| Segmented ring around a big number (03), activity rings (04) | Volume used vs available; Storage Analyzer composition of the scanned folder (top folders as segments plus "Other") |
| Bar chart with highlighted bar, value bubble and Avg rule (01) | Available space over time from storage snapshots, latest bar highlighted, dotted average line |
| Legend rows with dot and percentage (03) | Breakdown of the largest folders / categories in the last scan |
| Rounded bars with percentage labels (03) | Cleaner and Developer Tools: size per rule/category found |
| Small tiles (04) | Overview: last scan, items reviewed and moved to the Trash, duplicate groups found, apps listed — each from the database, each opening its screen |
| Table rows under a chart (02) | Largest files, history and activity lists |
| Uppercase tag pills (03) | Section tags and risk/status labels (sentence-case text stays for anything long) |
