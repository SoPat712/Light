# Iron Design System

This is the single source of truth for how Iron looks, moves, sounds and reads.
It is written for engineers **and coding agents**. If you are handed a screenshot of
an unthemed or off-brand screen, follow [§16 Theming a screen from a
screenshot](#16-theming-a-screen-from-a-screenshot) and you should be able to bring
it on-system without asking anyone.

Pending, approved-but-unbuilt work lives in [`DESIGN_BACKLOG.md`](DESIGN_BACKLOG.md).
Visual references live on the design canvas
(<https://claude.ai/artifact/XwxfzWTFvH2PNZWqMRpihv>, pages "Round 3 · Iron blue",
"Round 4 · Live workout", "Round 5 · Exercises"). When this document and a canvas
board disagree, **this document wins**; when this document is silent, match the
board.

Contents

1. [Identity](#1-identity)
2. [Principles](#2-principles)
3. [Color](#3-color)
4. [Typography](#4-typography)
5. [Layout, spacing and shape](#5-layout-spacing-and-shape)
6. [Surfaces, materials and Liquid Glass](#6-surfaces-materials-and-liquid-glass)
7. [Iconography](#7-iconography)
8. [Shared components (code)](#8-shared-components-code)
9. [Recurring patterns](#9-recurring-patterns)
10. [Data visualization](#10-data-visualization)
11. [Motion](#11-motion)
12. [Haptics and sound](#12-haptics-and-sound)
13. [Copy and number formatting](#13-copy-and-number-formatting)
14. [Accessibility](#14-accessibility)
15. [Screen-by-screen reference](#15-screen-by-screen-reference)
16. [Theming a screen from a screenshot](#16-theming-a-screen-from-a-screenshot)
17. [Retired components and banned techniques](#17-retired-components-and-banned-techniques)
18. [Review checklist](#18-review-checklist)

---

## 1. Identity

**"If Apple made a strength-training app."** Iron should be indistinguishable in
quality from Fitness, Health or Activity, while being clearly its own app. It is
*not* Hevy with Liquid Glass on top. Hevy is only a reference for logging density.

What makes Iron recognisably Iron:

| Signature | What it means in practice |
| --- | --- |
| **Iron blue** | One accent, `systemBlue`. It means action, workouts, selection and *completed sets*. |
| **One color per metric** | Sets = orange, Volume = green, Time = cyan, Effort = pink, Records = yellow, Body = purple. A number's color tells you what it measures, on every screen. |
| **Bold fixed-width numerals** | Every number is SF Pro **bold** (or semibold in dense rows) with `.monospacedDigit()`. Never SF Rounded: the owner rejected it as cartoonish. |
| **Things fill** | Completing a set sweeps a fill across the row left to right. Rest drains a ring. Effort fills rising bars. Progress fills, it doesn't tick. |
| **Rest lives inside the exercise** | The rest timer appears under the set that started it, not in a modal. |
| **Native chrome** | System navigation bars, tab bar, sheets, lists, toggles and pickers. Iron never repaints system chrome. |

## 2. Principles

1. **Native first.** Reach for the SwiftUI control before an Iron-specific one. A custom control
   must beat the native one for a measurable reason. Today that means the set row, the rest
   strip and ruler, the effort graph, the session strip and the muscle-map tooltip.
2. **Semantic colors only.** Use `IronTheme` roles, which map to adaptive UIKit colors. Never
   hard-code a hex value, `Color.black`, `.white` or `.gray` for chrome.
3. **The system owns chrome.** Never set `toolbarBackground`, `presentationBackground`,
   `scrollContentBackground(.hidden)` with a custom fill, or a custom modal corner radius.
4. **Glass is depth, not decoration.** Liquid Glass is only for layers that float above
   changing content (see §6).
5. **Tint carries meaning.** If a color does not mean "action", "this metric" or "this status",
   it is not allowed.
6. **Dense, not cramped.** A workout screen shows a lot of data. Native does not mean sparse.
7. **Every animation explains something:** navigation, continuity or a state change.
   Decorative motion is banned.
8. **Accessible by construction:** Dynamic Type, VoiceOver, Reduce Motion, 44 pt targets
   and 4.5:1 text contrast.

## 3. Color

All roles live in `Shared/UI/SwiftUI/IronStyle.swift` (`IronPalette` → `IronTheme`).
Screens use **only** `IronTheme.*` and a few system colors named below.

### 3.1 Core roles

The hex values below are what the system color resolves to. They are listed so you can match
screenshots and canvas boards; never write them in code.

| `IronTheme` role | System color | Light | Dark | Means |
| --- | --- | --- | --- | --- |
| `accent` | `systemBlue` | `#007AFF` | `#0A84FF` | Actions, selection, workouts, **completed sets**, primary chart series |
| `accentSoft` | systemBlue @ 0.12 | — | — | Soft accent chips, icon wells, selected pills |
| `accentPressed` | systemBlue @ 0.72 | — | — | Pressed state of custom accent fills |
| `metricSets` | `systemOrange` | `#FF9500` | `#FF9F0A` | Set counts, warm-up sets |
| `metricVolume` | `systemGreen` | `#34C759` | `#30D158` | Volume (weight × reps), positive deltas |
| `metricTime` | `systemCyan` | `#32ADE6` | `#64D2FF` | Durations, elapsed time, rest |
| `metricEffort` | `systemPink` | `#FF2D55` | `#FF375F` | RPE, session effort |
| `metricRecord` | `systemYellow` | `#FFCC00` | `#FFD60A` | Personal records, trophies |
| `metricHeartRate` | `systemRed` | — | — | Live Watch heart rate |
| `metricEnergy` | `systemOrange` | — | — | Estimated active energy in kcal |
| `metricBody` | `systemPurple` | `#AF52DE` | `#BF5AF2` | Body measurements |
| `*Container` (one per metric) | hue @ 0.18 | — | — | Soft backgrounds for metric chips and badges |
| `success` | `systemGreen` | | | Sync status dots and success messages **only** |
| `warning` | `systemOrange` | | | Attention, overtime, paused rest |
| `danger` | `systemRed` | `#FF3B30` | `#FF453A` | Destructive actions, errors, the delete swipe |
| `primaryText` | `label` | `#000000` | `#FFFFFF` | Body text, titles, values |
| `secondaryText` | `secondaryLabel` | rgba(60,60,67,.60) | rgba(235,235,245,.60) | Captions, units, metadata |
| `tertiaryText` | `tertiaryLabel` | rgba(60,60,67,.30) | rgba(235,235,245,.30) | Placeholders, disabled text |
| `background` | `systemGroupedBackground` | `#F2F2F7` | `#000000` | Full-screen editors that cannot be a `List` |
| `surface` | `secondarySystemGroupedBackground` | `#FFFFFF` | `#1C1C1E` | Card surfaces where a `Section` is impossible |
| `raisedSurface` | `tertiarySystemGroupedBackground` | `#F2F2F7` | `#2C2C2E` | Nested low-emphasis surfaces |
| `field` | `secondarySystemFill` | rgba(120,120,128,.16) | rgba(120,120,128,.32) | Input and compact control backgrounds |
| `tertiaryFill` | `tertiarySystemFill` | rgba(118,118,128,.12) | rgba(118,118,128,.24) | Current-set fields, ring tracks, inactive pills |
| `outline` | `separator` | rgba(60,60,67,.29) | rgba(84,84,88,.60) | Hairlines only, never card borders |
| `onAccent` | white | | | Text and glyphs on solid accent |
| `diagramCanvas` | white (fixed) | | | Background behind exercise diagrams in both modes |

`Color(.quaternarySystemFill)` is allowed for inactive bars in graphs, as in the effort graph.

### 3.2 Rules for using metric colors

- Metric colors go on **numbers, short labels, icons and soft containers**. Never on body copy
  or long text.
- Cyan and yellow on a light background must be **semibold or bold** (contrast).
- Units ("lb", "kg", "sets") are smaller and `secondaryText`, even when the number is colored.
- One metric, one color, everywhere: Home, History, logger, finish, widgets, Watch and Live Activity.
- **Green never paints completed sets.** Completion is blue. Green only ever means volume or success.
- Muscle-group text tags are **neutral** (`secondarySystemFill` with `secondaryLabel`). Muscles are
  never color-coded by group. The anatomical muscle map uses accent only (§8.9).

### 3.3 Set-state colors (live logger)

| State | Row fill | Badge | Values | Check |
| --- | --- | --- | --- | --- |
| Upcoming | none | neutral filled circle (`tertiaryFill`), secondary number | `secondaryText` | neutral ring |
| Current (focused) | raised card (§15.6) | accent ring | primary, large | accent "Log Set" button |
| Completed, normal | accent sweep to **0.12** settled (peak 0.24) | `accentSoft` + accent number | primary bold, no field fill | `checkmark.circle.fill` accent |
| Completed, warm-up | **soft** orange sweep, settled 0.14 | "W" in `metricSets` on `metricSetsContainer` | primary | same check, accent |
| Completed, drop set | **soft** indigo (`systemIndigo`) sweep, settled 0.14 | "D" in indigo on indigo @ 0.18 | primary | accent |
| Completed, failure | **soft** red (`systemRed`) sweep, settled 0.12 | "F" in red on red @ 0.16 | primary | accent |

The owner likes the current blue fill on normal completed sets. **Do not change it.** Set-type
fills must be *softer* than the blue, never saturated slabs with white text. Use
`IronTheme.setFill(for:)` once it exists (backlog B4).

### 3.4 Muscle map colors

These are copied exactly from the live-workout map. Every `BodyView` in the app uses this
`BodyViewStyle`:

```swift
BodyViewStyle(
    defaultFillColor: Color(.tertiaryLabel).opacity(0.35),
    strokeColor: Color(.separator),
    strokeWidth: 0.5,
    selectionColor: IronTheme.accent,
    selectionStrokeColor: IronTheme.accent,
    selectionStrokeWidth: 1,
    headColor: Color(.tertiaryLabel).opacity(0.45),
    hairColor: Color(.quaternaryLabel)
)
// primary muscles:   .highlight(primary,   color: IronTheme.accent)
// secondary muscles: .highlight(secondary, color: IronTheme.accent, opacity: 0.42)
```

Always render front and back side by side (`gender: .male`, `side: .front` / `.back`). Map
catalog muscle names with `ironMapMuscle(_:)` (`Iron/UI/SwiftUISupport.swift`). Never write a
second mapping table.

## 4. Typography

San Francisco only, through SwiftUI text styles so Dynamic Type works. Sizes are at the
default "Large" content size.

| Style | pt / weight | Used for |
| --- | --- | --- |
| `.largeTitle.bold()` | 34 bold | Root tab titles (Home, History, Workout, Exercises, Settings) |
| `.title.bold()` | 28 bold | Hero headers (finish screen workout name, exercise detail title) |
| `.title2` | 22 | Big standalone numbers (`ironMetric(.title2)`) |
| `.title3.weight(.semibold)` | 20 semibold | Card titles inside screens ("Session", "How hard was it?", "Target") |
| `.headline` | 17 semibold | Row titles, inline navigation titles, exercise names in the logger |
| `.body` | 17 | Body copy, list rows |
| `.callout` | 16 | Secondary rows |
| `.subheadline` | 15 | Metadata lines, watch-sync banner |
| `.footnote` | 13 | Captions, section footers, chart axis labels |
| `.caption` | 12 | Legends, compact metadata, badges |
| `.caption2` | 11 | Tiny labels under charts and figures |

### 4.1 Numbers

Every metric number (weights, reps, volume, durations, timers, counts, RPE and percentages) uses:

```swift
Text("185").font(.ironMetric(.title2))                    // bold, fixed-width digits
Text("8").font(.ironMetric(.body, weight: .semibold))     // dense rows
```

`Font.ironMetric(_:weight:)` = `.system(style).weight(weight).monospacedDigit()`. Default weight
is `.bold`.

| Context | Style |
| --- | --- |
| Hero metric (exercise headline 1RM, finish grid values) | `ironMetric(.largeTitle)` or `.title` |
| Card metric values (Home week numbers, summary columns) | `ironMetric(.title2)` |
| Rest countdown in the rest strip | `ironMetric(.title3)` in `metricTime` |
| Focused-set weight and reps | `ironMetric(.largeTitle)` (≈34 pt) |
| Compact set row values | `ironMetric(.title3, weight: .bold)` |
| Inline metric lines ("1h 02m · 14 sets · 9,860 lb") | `ironMetric(.subheadline, weight: .semibold)` |
| Badges ("RPE 8", "2 PRs") | `ironMetric(.caption, weight: .bold)` |

- **Units** sit after the number in a smaller style (`.footnote`/`.caption`, semibold) in
  `secondaryText`, baseline-aligned: `HStack(alignment: .firstTextBaseline, spacing: 2)`.
- Use `IronMetricValue` for number/unit readouts and `IronWorkoutMetricLine` for inline
  workout summaries. Home, History, Workout and logger must share these roles rather than
  choosing local weights and unit treatments. Data-row names use `.headline`; normal form
  labels and body copy remain `.body`. Native section headers keep the system hierarchy.
- Values that change animate with `.contentTransition(.numericText())` (countdowns use
  `.numericText(countsDown: true)`), driven by `IronMotion.snappy`.
- Never use `design: .rounded` for anything.

### 4.2 Text color hierarchy

Primary for titles and values, secondary for metadata, units and captions, tertiary for
placeholders. Metric color is for the number only, never its label. The exception is labels that
*are* metric identifiers, such as the "Duration / Volume / Sets" labels in the logger summary,
which take their metric color.

## 5. Layout, spacing and shape

### 5.1 Tokens (`IronTheme`)

| Token | Value | Use |
| --- | ---: | --- |
| `horizontalPadding` | 16 | Screen gutter for custom layouts (List provides its own) |
| `controlHeight` | 44 | Minimum height for every interactive control |
| `iconButtonSize` | 44 | Icon-only buttons (44 × 44 hit area, glyph may be smaller) |
| `pillCornerRadius` | 22 | Capsule controls at 44 pt |
| `cornerRadius` | 12 | Generic rounded rectangles |
| `compactCornerRadius` | 10 | Set rows, completion fill, fields |
| `heroCornerRadius` | 22 | Hero/summary glass clusters, the rest strip |
| `floatingWorkoutBottomClearance` | 152 | Bottom inset so content clears the tab bar and workout accessory |
| `activeWorkoutPillHorizontalPadding` | 20 | Fallback floating workout pill |

### 5.2 Spacing scale

Use only **2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 32**.

- Between a label and its value: 2–4.
- Inside a card: 12–16 padding, 10–14 between rows of content.
- Between cards or sections: 12–20 (List handles this itself).
- Icon to text in a chip or label: 5–6.

### 5.3 Shapes

- Always `RoundedRectangle(cornerRadius:, style: .continuous)`. Never non-continuous corners.
- **Capsule** is reserved for: compact status chips (RPE, PR, streak), segmented and range pills,
  prominent toolbar buttons, the floating workout accessory, the rest strip controls, the
  focused-set "Log Set" button, steppers, and tooltips.
- Compact set data (Previous, weight, reps, duration, historical set results) uses
  `compactCornerRadius` (10 pt), including read-only values. Use the same continuous
  rounded-rectangle shape throughout; metadata/status chips keep their own roles.
- Grouped content uses `List`/`Form` `Section`s, whose corners come from the system. Custom
  cards (hero, progress card, target card) use `heroCornerRadius` (22). Canvas boards show 26;
  use 22 in code.
- No borders around cards. No drop shadows on cards. Shadows are only for floating glass
  (system-provided) and the tooltip.

### 5.4 Touch targets

Minimum 44 × 44 pt, always. A visually smaller glyph gets a padded `contentShape`.

## 6. Surfaces, materials and Liquid Glass

| Layer | Implementation |
| --- | --- |
| Screen background | System (`List`, `Form`, `NavigationStack`); never painted |
| Grouped content | `List` `.insetGrouped` sections. One section holds related rows; never wrap each row in its own card, never nest cards |
| Custom card | `IronTheme.surface` fill, `heroCornerRadius`, used only when the content cannot be rows (charts, the muscle map, the logger's exercise card) |
| Floating chrome | Liquid Glass: `.ironLiquidGlassPill(tint:)` (capsule) or `.ironLiquidGlassSurface(cornerRadius:tint:)`; on iOS 26 it is `glassEffect(.regular.tint().interactive())`, with an `.ultraThinMaterial` + hairline fallback |
| Buttons floating over content | `.ironGlassButtonStyle()` (secondary) and `.ironProminentGlassButtonStyle()` (the one primary action) |

**Glass is allowed only on:** the active-workout tab accessory, the logger's collapsed summary
pill, floating action buttons (Add Exercises), the LightToast result capsule, Watch toolbar
vitals and action buttons, and tooltips (material).
Glass never sits on glass. Glass never replaces a List section.

## 7. Iconography

SF Symbols only, using the semantic style and weight of the adjacent text. Never put every
symbol in a colored tile. Icon wells (32 pt soft circles) are only for metric chips and record
lists. Settings is the exception: its rows use the icon-tile anatomy in §15.8.

| Concept | Symbol |
| --- | --- |
| Workout / start | `dumbbell.fill` (filled when prominent), `figure.strengthtraining.traditional` |
| History | `clock.arrow.circlepath` |
| Exercises tab | `figure.strengthtraining.traditional` |
| Rest timer | `timer` (chips), `stopwatch` (duration sets) |
| Add | `plus` |
| Edit | `pencil` |
| Delete | `trash` (menus), `trash.fill` (swipe action) |
| More | `ellipsis.circle` (toolbar), `ellipsis` (inline) |
| Record / PR | `trophy.fill` in `metricRecord`; `medal.fill` for "best" lists |
| Warm-up / drop / failure | `flame`, `arrow.down.right`, `bolt.fill` |
| Effort | `gauge.with.dots.needle.50percent` |
| Progress chart | `chart.xyaxis.line` |
| Repeat workout | `arrow.clockwise` |
| Share / export / import | `square.and.arrow.up`, `square.and.arrow.down` |
| Sync | `arrow.triangle.2.circlepath`; device: `iphone`, `applewatch` |
| Collapse / expand | `chevron.up` / `chevron.down` |
| Streak | `flame.fill` |
| Plate calculator | `plusminus` |

Symbol effects: `.symbolEffect(.bounce)` for confirmations (check, trophy) and
`.contentTransition(.symbolEffect(.replace))` for state swaps (play ↔ pause, circle ↔
checkmark). Gate both on Reduce Motion.

## 8. Shared components (code)

Before building anything custom, check this list. File paths are relative to the repo root.

### 8.1 Tokens: `Shared/UI/SwiftUI/IronStyle.swift`
`IronPalette`, `IronTheme`, `IronMotion`. `Font.ironMetric` lives in the lightweight sibling
`IronMetricFont.swift`, shared by app, widget and Siri UI targets. This file is shared with the widget
extension, so keep it free of app-only imports.

### 8.2 Glass helpers: `Iron/UI/SwiftUISupport.swift`
`ironLiquidGlassPill(tint:)`, `ironLiquidGlassSurface(cornerRadius:tint:)`,
`ironGlassButtonStyle()`, `ironProminentGlassButtonStyle()`.

`IronMetricValue(value:unit:style:weight:unitStyle:tint:)` and
`IronWorkoutMetricLine(duration:sets:volume:unit:)` also live here. The former defaults to a
bold title2 value with a secondary semibold footnote unit; dense data rows use body semibold.
The latter fixes the inline summary at subheadline semibold, with caption units. Both wrap
instead of shrinking whole rows at accessibility sizes.

### 8.3 `ironSetCompletion(isComplete:feedbackEnabled:)`
Leading-anchored fill sweep behind a row: `scaleEffect(x:)` from 0 to 1 at opacity 0.24 using
`IronMotion.collapse`, then after 420 ms it fades to 0.12. It fires the `.success` haptic.
Existing completed rows appear already settled and do not replay. Reduce Motion uses a fade and
keeps the haptic. Apply it to the row content inside its inset; it adds no geometry. Backlog B4
adds a set-type tint parameter.

### 8.4 `ironStaggeredEntrance(index:)`
Opacity 0 → 1 and y +8 → 0 with `IronMotion.snappy`, delayed 40 ms × index. Plays **once**.
Never reset it in `onDisappear`, because List prefetching would then hide rows.

### 8.5 `IronRestRing(progress:)`
Countdown ring. `progress` is the fraction remaining (1 = full). Its track is `tertiaryFill`,
it draws a 4 pt `metricTime` stroke with round caps, and it starts at 12 o'clock. Callers own
the timer. Hide it from VoiceOver when the text already announces the time.

### 8.6 `EffortRatingGraph(rating:allowsUnrated:)`
One slanted bar per level from 1 to 10, forming a single rising ramp like the Watch's, with wider gaps between `EffortTierPalette` tiers: 1–3 Easy, 4–6 Moderate, 7–8 Hard, 9–10 All Out. Each bar is fully lit in its tier color or fully `solidTrack`, so a rating never cuts through a bar. Numbers sit under the bars, and the readout above shows the number and tier name. Set it by tapping a column or dragging, with a selection haptic per step and an accessibility adjustable action. This is **the** pattern for any 1-to-N intensity input.

### 8.7 `IronSessionStrip`: `Iron/UI/Components/IronSessionStrip.swift`
The session, exercise by exercise. Input is `[ExerciseGroup(label:, sets: [Set(kind:
.warmUp/.normal/.record, completedAt:, duration:, volume:, result:, rpe:)])]`.
- **Rest summary:** Total Rest, Avg Rest and Longest in `metricTime`.
- **Each exercise:** its full name and total volume, then "4 sets · 14 min" beside a thin
  `metricTime` bar marking when it ran, so the bars stack into the session's timeline.
- **Each set:** set number or W, the result, a volume bar, RPE and the rest before it, under
  SET, RESULT, VOLUME, RPE and REST column labels. Superset rounds gather under each exercise.

Volume bars scale within an exercise, so one heavy machine can't flatten the other sets. They
are all `accent`, with warm-ups in `tertiaryText` and a W label, and records with a
`metricRecord` trophy. Orange and yellow bars side by side failed the palette validator, so hue
no longer carries set type. Accessibility sizes stack each set's values.

### 8.8 Sheets: `Iron/UI/SwiftUISupport.swift`
`IronUtilitySheet` (titled utility sheet with icon, subtitle and close button),
`IronConfirmationSheet`, `IronStatusSheet`, `IronDateTimePickerSheet`, `IronDurationPickerSheet`
/ `IronDurationWheel` (system dual wheel for minutes and seconds). Prefer `.alert` or
`.confirmationDialog` when a one-line explanation is enough.

### 8.8.1 `HevyImportProgressOverlay`: `Iron/Data/Model/HevyCSV.swift`
A blocking progress overlay for long imports. Its phases are reading (files) and saving
(workouts). Reuse the same pattern (glass card, `ProgressView`, phase text and counts) for any
operation over about 1 s.

### 8.8.2 `LightToast`: `Iron/UI/Components/LightToast.swift`
A short, self-dismissing glass capsule drops from the top for results needing no decision
(backup made, sync done, status checked). `LightToastCenter` presents one at a time in its own
non-interactive window above sheets and full-screen covers; touches pass through. It announces
the result to VoiceOver and respects the haptics preference. Errors needing reading or action
keep their sheets or alerts.

### 8.9 Muscle map (MuscleMap package)
`import MuscleMap`, then `BodyView(gender: .male, side:, style:)` with the style from §3.4.
The approved local package lives at `Packages/MuscleMap` (1.6.4, MIT; provenance in
`IRON_CHANGES.md`). `MuscleHitTester.muscle(at:in:gender:side:)` exposes the renderer's existing
hit testing for the app's hold-gated overlay. Do not duplicate the anatomical paths.
- **Live workout:** a 54 pt tall pair, not interactive (`allowsHitTesting(false)`).
- **Exercise detail:** a pair about 190 pt tall that is interactive (press-and-hold tooltip,
  §9.8).
- Map names with `ironMapMuscle(_:)`. Never hand-draw bodies.

### 8.10 Exercise art
`ExerciseDiagramThumbnail(exercise:size:)` (in `Iron/UI/Exercises/ExercisesView.swift`) draws
a circular white canvas with the cached still fitted inside, a hairline ring and a 2 pt shadow.
Sizes: 42 (logger header), 58 (lists), 60 (detail header). Thumbnails never draw the old
black-and-white PDF diagrams; `legacy-art.json` gives those exercises the same movement's still.
Default lists use `ExerciseStore.listed`: built-ins with no picture and the reviewed entries in
`catalog-duplicates.json` appear only after a search or "Show N More Exercises". Custom exercises
and anything in a workout or saved workout always stay listed. Nothing is deleted.
`ExerciseRemoteMediaView` plays the animated demo.
Unknown artwork uses the neutral `figure.strengthtraining.traditional` glyph, never an
O/initial masquerading as a picture. List stills are persisted at the original pixel size;
demonstrations retain their original animation. Do not upscale assets to imply added detail.
Custom Exercises uses `ExerciseLibraryRow`, matching the library's thumbnail, headline and
neutral tags. Safe Hevy name equivalences live in `hevy-aliases.json` and
`hevy-template-aliases.json`; read-time metadata recovery preserves the original custom
name/UUID and historical relationships. OpenGym text updates the main library while retaining
legacy entries and stable IDs. Its separately licensed media is not included.

The inline exercise history card uses plain buttons routed by ExerciseDetailView outside
the List. Never put several automatic NavigationLinks into this single List row: activating
one can push all sibling destinations. Full history's independent List rows may use links.

### 8.11 Sounds: `Shared/IronSoundPlayer.swift`
Covered in §12.

## 9. Recurring patterns

### 9.1 Metric chip (Home week card, finish grid)
```
[32pt circle, metric Container fill, SF Symbol 17pt in metric color]
<value>  ironMetric(.title2), primary (or metric color in the finish grid)
<label>  .footnote, secondaryText
```
Three per row in a `Grid` or a three-column `LazyVGrid`. Labels never truncate; at
accessibility sizes they wrap.

### 9.2 Metric line (History rows, accessory, exercise rows)
`"1h 02m · 14 sets · 9,860 lb"`: each value in its metric color, `ironMetric(.subheadline,
weight: .semibold)`, separated by `" · "` in `secondaryText`. Order is always
**time → sets → volume**, with effort or records as trailing badges.

### 9.3 Badges
A capsule 22–24 pt tall with 8 pt horizontal padding and `ironMetric(.caption, weight: .bold)`:
- PR: `trophy.fill` 11 pt + "2 PRs" in `metricRecord` on `metricRecordContainer`.
- RPE: "RPE 8" in `metricEffort` on `metricEffortContainer`.
- Streak: `flame.fill` + "33-week streak" in accent on `accentSoft`.

Set-result chips in exercise history are data readouts, using `compactCornerRadius` (10 pt).
Show "205×5" on `tertiaryFill`; warm-up uses `metricSets` on its container, and a record set
gets a trophy and record colors.

### 9.4 Segmented control
Use the system `Picker(...).pickerStyle(.segmented)` where possible. If you need custom styling
(the exercise progress card), use a 32 pt capsule track on `tertiaryFill`, a selected segment on
`systemBackground`/`card3` with a subtle shadow, 13 pt text (semibold when selected), and
`IronMotion.snappy` with `matchedGeometryEffect` for the thumb. Use four segments at most.

### 9.5 Time-range pills
Five equal 30 pt capsules: **1M · 3M · 6M · 1Y · All**. The selected pill is `accentSoft` with
accent bold text; the rest are clear with `secondaryText` semibold. Default is **3M**.

### 9.6 Empty states
Use `ContentUnavailableView` with an SF Symbol, a title and one sentence that says what will
appear and how to make it appear. No illustrations. Example: "No sessions yet" / "Log this
exercise in a workout and your progress will chart here."
List-row action buttons use native capsule styling, `.controlSize(.large)` and
`.fixedSize(horizontal: false, vertical: true)` so AX labels can wrap inside the row.
Use an explicit `Label` with `.labelStyle(.titleAndIcon)` when both text and symbol are required.
Do not put an external minimum-height frame around a styled empty-state button; give the
`ContentUnavailableView` the row width and insets instead.

### 9.7 Destructive confirmation
`.confirmationDialog` with a `.destructive` button. The copy states what is lost and what is
kept: "Your completed workout history is not affected."

### 9.8 Tooltip (muscle map, chart callouts)
A small capsule (30 pt tall, 12 pt horizontal padding) with `.regularMaterial` or glass, a
hairline edge and the shadow `0 6 18 black @ 0.28`. Content is an 8 pt colored dot, the bold
name and the role in `secondaryText`, as in **"● Chest  Primary"**. A 14 × 7 pointer points at
the target, and the tooltip sits above the touch point, clamped inside the card.
- **Appears** with scale 0.92 → 1 plus fade (`IronMotion.snappy`) and a `.selection` haptic
  whenever the target changes.
- **Disappears** on finger lift, or about 2 s after a tap.
- **Triggers:** touch-and-hold (0.25 s), then drag to scrub between targets. A quick tap shows
  it too. A vertical drag that starts on the map must still scroll the page; use a long-press
  that then becomes a drag, never an always-on `DragGesture(minimumDistance: 0)`.
- **Never** a sheet or modal.

### 9.9 Swipe to delete (custom rows)
The row slides left and a **separate** red capsule appears in the space it leaves, with an
**8 pt gap** between the row's trailing edge and the action. The action never sits under the
row and never overlaps the row's own controls. While the row is open, a tap on the row closes it
and does not toggle anything. A full swipe past 60% deletes. Use `danger` with `trash.fill`
and "Delete" in white. In `List`s, use the system `.swipeActions`.

### 9.10 Loading and progress
For work under about 1 s, show nothing. For more than that, show inline `ProgressView` in
the row or button. For blocking work over about 3 s (imports), use the overlay pattern in
§8.8.1 with a phase and count.

## 10. Data visualization

- **Swift Charts only.** No hand-drawn `Canvas`, `Path` or `GeometryReader` plotting and no
  third-party chart libraries. The session strip and effort graph are deliberate stack-based
  exceptions.
- **Use `Iron/UI/Components/IronChartKit.swift`** for every chart, so they all read like the
  Health app. Above the plot, `IronChartHeader` shows an uppercase caption ("Total", "Latest"),
  the value from `IronChartText.value` in its metric color with a secondary unit, and a date or
  period line. Values sit on `ironValueAxis` (trailing, `.caption2`, hairline `outline`
  gridlines, 2–3 ticks). Dates sit on `ironDateAxis` (`.caption2`, a faint dashed guide per label).
- **Line charts** (1RM, top weight, body, trends): a 2 pt line with linear interpolation,
  so the line passes through real values, and 5 pt points. No area fill. Body measurements and
  sparklines hug their data instead of starting at zero. The latest PR point is a 9 pt
  `metricRecord` dot with a soft halo and a 1.5 pt card stroke.
- **Bar charts** (volume, reps, duration): 3–4 pt corners, every bar in the metric color.
  Don't dim older bars to highlight the current period.
- **Scrubbing:** `chartXSelection`. The selected mark is full color and the others drop to
  `IronChartEmphasis.dimmed`. `IronChartSelectionRule` marks the selection, and the header above
  the chart switches to the selected value and date. Never float a callout or material box over
  the plot, and never show "drag to inspect" hint text.
- **Summary cards** (pinned charts): the title in the metric color with the date at the trailing
  edge, the value, and an axis-free sparkline that ends on a dot.
- **Color series:** one metric per chart, colored by that metric. Never encode meaning with
  hue alone.
- **First appearance:** bars grow and lines draw in with `IronMotion.snappy`. Changing metric
  or range cross-fades the plot and rolls the headline digits.
- **VoiceOver:** a chart summary label, the selected value and an adjustable action for
  previous and next points.
- **Vertical drags belong to the scroll view.** Chart gestures must only react to horizontal
  intent.

## 11. Motion

Tokens (`IronMotion`, in `IronStyle.swift`):

| Token | Curve | Use |
| --- | --- | --- |
| `snappy` | spring response 0.32, damping 0.82 | Anything the finger caused: selection, toggles, value changes, tooltips |
| `collapse` | spring response 0.42, damping 0.86 | Large surfaces moving: header collapse, rest strip insert, focused-set expand |
| `focusScroll` | cubic (0.16, 1, 0.3, 1), 0.65 s | Guided exercise/superset travel: prompt start, long deceleration, no bounce |
| `fade` | easeInOut 0.18 s | Non-spatial changes, and the Reduce Motion substitute |

Always write `withAnimation(IronMotion.preferred(.snappy, reduceMotion: reduceMotion))`, reading
`@Environment(\.accessibilityReduceMotion)`. Reduce Motion swaps spatial motion for a fade; the
haptics still play.
Programmatic exercise scrolling uses `focusScroll`; under Reduce Motion it moves directly
without a spatial animation.

| Moment | Motion |
| --- | --- |
| Complete a set | Fill sweep (§8.3), check bounce plus `.symbolEffect(.replace)`, success haptic and `setComplete` sound (`setRecord` for a PR) |
| Next set becomes current | The focused editor expands from the compact row (`collapse`). The previous card collapses into its completed row |
| Counters | `.contentTransition(.numericText())` plus `snappy` |
| Rest starts | The strip inserts under the triggering set with `.move(edge: .top).combined(with: .opacity)` and `collapse` |
| Rest ticks | The ring drains continuously and the digits roll down (`numericText(countsDown: true)`) |
| Rest ends | The ring pulses once (scale 1.12), the strip folds away, plus a light-impact haptic and the `restComplete` sound |
| Rest ruler opens | Expands under the strip (`collapse`), with ticks fading in |
| Delete set | The row slides out, then collapses (`collapse`) with an opacity plus scale 0.96 transition |
| Header collapse | The summary is swapped for the glass pill (`collapse`), and labels never squash |
| Open or minimize the workout | Zoom from the tab accessory (`matchedTransitionSource` plus `.navigationTransition(.zoom)`); fade under Reduce Motion |
| Finish screen | Metrics rise in staggered (`ironStaggeredEntrance`), session bars grow per exercise, trophies bounce |
| Effort and RPE | Bars fill while dragging, with a selection haptic per step |
| Charts | Grow on first appearance; cross-fade when the metric or range changes |
| Tooltip | Scale 0.92 → 1 plus fade (`snappy`) |
| Lists reordering (recency) | Default List animation; do not add extra motion |

Never delay a dismissal, save or navigation for an animation.

## 12. Haptics and sound

### 12.1 Haptics (`.sensoryFeedback`)

| Event | Feedback |
| --- | --- |
| Set completed by the user | `.success` after a successful local save (`ironSetCompletion` owns the visual sweep) |
| Stepper tap, weight/reps drag step, picker step, set-type change, effort and RPE step, ruler notch, tooltip target change, segment change | `.selection` |
| Rest ±15 s, start, pause/resume, skip/stop, open/close rest ruler | `.selection` |
| Inline set timer start/stop, undo set completion | `.selection` |
| Superset membership/save, exercise/set reorder, workout accessory controls/open/minimize, session summary expand/collapse | `.selection` |
| Rest finished | `.impact(weight: .light)` |
| Delete committed | `.impact(weight: .medium)` |
| Error or validation failure | `.error` |

Drive control feedback from local user actions, not shared model changes, initial hydration,
Watch sync, or Live Activity updates. Respect the workout haptics preference. Delete feedback
belongs on a surviving parent view after a successful deletion, so a removed row does not lose
its trigger. Live Activity extension intents never emit app haptics.

### 12.2 Sounds (`IronSoundPlayer.shared.play(.cue)`)

Original procedurally generated `.caf` files live in `Iron/Resources/Sounds/`; regenerate them
with `scripts/generate_sounds.py`. The audio session is `.ambient` (it mixes with music and
respects the silent switch). Players are preloaded at launch.

| Cue | When | Volume |
| --- | --- | --- |
| `setComplete` | Set marked complete | 0.6 |
| `setRecord` | Completed set is a PR (instead of `setComplete`) | 0.6 |
| `tick` | Keypad, steppers, dial and ruler notches, ±15 s | 0.35 |
| `restComplete` | Rest timer reaches zero (also the notification sound) | 0.8 |
| `workoutFinish` | Workout saved | 0.6 |

Never use system "beep" sounds. Never play a sound without its matching haptic, except
`tick`.

## 13. Copy and number formatting

- **Terminology:** "Workout" means a saved, reusable workout. Never say "routine", "plan" or
  "template" in UI copy, even though the model uses those names. "Set", "Rest", "Effort" or
  "RPE", "Record" or "PR", "Volume".
- **Case:** Title Case for buttons, navigation titles and section headers ("Start Workout",
  "Recent Workouts"). Sentence case for body text, footers, captions and tooltips ("Touch and
  hold a muscle").
- **Weights:** `205 lb`, `92.5 kg`. Use `settingsStore.weightUnit` and the
  `WeightUnit.convert` path; never hard-code the unit.
- **Sets:** `205 × 5` with a true multiplication sign (×) and spaces; chips may drop the
  spaces (`205×5`).
- **Volume:** `9,860 lb`, abbreviated as `19.0k lb` above 10,000 in compact places.
- **Durations:** elapsed `1h 02m` or `18:42`; rest `2:30`; adjustments `−15` and `+15` with a
  true minus sign (−).
- **Dates:** "Today", "Yesterday", "Wed, Oct 14" (same year), "Oct 14, 2025" (another year).
  Relative ages use `RelativeDateTimeFormatter` `.named` ("7 days ago").
- **Effort:** "RPE 8", "RPE 8.5"; session effort "8 · Hard".
- **Deltas:** an arrow glyph (↑/↓ symbol) plus the value, in `metricVolume` when good and
  `secondaryText` when flat or negative ("↑ 18 lb · in 3 months"). Never red for a dip; a dip
  is not an error.

## 14. Accessibility

- Dynamic Type through the accessibility sizes. Rows reflow from horizontal to vertical
  (`ViewThatFits` or an accessibility-size check). Exercise names wrap.
- In the logger, accessibility sizes stack the summary metrics and use labelled set fields
  instead of fixed table columns. The collapsed summary keeps each value on its own line;
  its scroll clearance scales with text. The top bar gives rest and Finish their full width.
  Circular steppers remain 40 pt visually inside 44 pt touch targets.
- Every icon-only button has an `accessibilityLabel`. Custom controls expose
  `accessibilityValue` and `accessibilityAdjustableAction`: steppers, effort, RPE, the ruler and
  charts.
- Combine composite rows with `.accessibilityElement(children: .combine)` or give them a written
  label ("Set 2, 205 pounds, 5 reps, completed").
- Decorative images and figures are `accessibilityHidden(true)`, with their meaning stated in a
  label on the container ("Target muscles. Primary: Chest. Secondary: Shoulders, Triceps.").
- Contrast is 4.5:1 for text. Metric-colored text on light backgrounds must be bold.
- Reduce Motion is covered in §11. Reduce Transparency is handled automatically because glass
  falls back to material.

## 15. Screen-by-screen reference

### 15.1 Tabs
There are five tabs, always in this order: **Home · History · Workout · Exercises · Settings**.
Each uses `NavigationStack` with a large title. The tab bar minimizes on scroll
(`.tabBarMinimizeBehavior(.onScrollDown)`). The active workout appears as the native tab-bar
accessory: name plus a metric line (time · volume · sets) on the left, and expand and discard
buttons on the right.

### 15.2 Home (`Iron/UI/Feed/FeedView.swift`, `Iron/UI/Components/HomeWeekViews.swift`)
Board: *Round 3 → Home*, revised 2026-11-02 to read like Fitness and Health, then made
customizable like Fitness's Edit Summary. Home is a list of cards the user adds, removes and
reorders in Customize Home (from a week card's ••• menu or the button at the end of Home);
the weekly set target is set there too. Cards live in `UserDefaults` under `home.cards`
(build 71's `home.weekStyle`, `home.sectionOrder` and `home.hiddenSections` carry over once);
no Core Data change. Default cards, in order:
1. Today's date as the navigation subtitle under "Home" (iOS 26 and later). No greeting.
2. **Week cards** (opaque neutral `IronTheme.surface`; no colored glass haze). Any of the four
   can be on Home at once, in any order. The first one is titled "This Week" with the date
   range, carries the Workouts/Sets/Volume row where its style has one, and ends with a
   full-width Resume or Start Workout button (native large `.borderedProminent` capsule).
   Later week cards are titled by name and show only their chart. With no week card, the
   Start button stands alone at the top of Home. Each week card's ••• menu adds another week
   card directly below it, removes it, or opens Customize Home.
   - **Rings** (default): Fitness-style rings for Volume (outer, `metricVolume`), Sets
     (`metricSets`) and Workouts (inner, accent) that close when this week matches last week;
     tracks use each metric's container color. Beside them, each metric as "11.4k / 26.6k lb".
     Below: a row of small daily volume rings scaled to the week's best day, and the best-day line.
   - **Pace**: running volume this week (solid 3 pt `metricVolume`) over last week's running
     line (dashed `tertiaryText`); the rest of the week is shaded; a translucent bar at today
     marks the gap. Header "VOLUME SO FAR" with "7,600 lb behind last Monday". As the first
     card, then Workouts, Sets and Time.
   - **Muscle Week**: a grid of the six tracked groups (Legs, Chest, Back, Shoulders, Arms,
     Core) by weekday. Dot area shows sets in `metricSets`; today's column has a
     `tertiaryFill` lane; a trailing LAST column gives days since each group was trained; one
     line names the most rested group.
   - **Daily Volume**: the original seven daily volume bars with the comparison line.
3. **Last 4 Weeks** calendar: 34 pt day circles, trained days solid accent with white numbers,
   others `tertiaryFill` with `secondaryText`. A streak chip sits in the section header.
   Every date opens a Daily Recap, including rest days. The recap shows that day's workout,
   set, time and volume totals, all its sessions, muscle focus and any logged measurements.
   Workout detail is one level below the recap. The full calendar follows the same rule.
4. Recent Training rows: the title with the date at the trailing edge, then the shared
   `IronWorkoutMetricLine` (duration, sets, volume).
5. **Muscle Focus**: average sets a week per tracked group over the last four weeks, ranked,
   as `metricSets` bars over a shaded target band (default 10–20, set in Customize Home).
   Header "N of 6 groups reach 10 sets a week"; the footer names the lowest group. Every
   row lays out its own name, so nothing collides at large text sizes.
6. Body and Pinned Charts use headline row names and the shared metric/unit
   hierarchy. Recent dates use subheadline metadata. Body rows use native List spacing and
   reflow vertically at accessibility sizes; never add a second minimum row height. Pinned
   chart titles use headline and chart axes use footnote.
7. A **Customize Home** button ends the list. The sheet is always in edit mode: "On Home"
   lists the cards with delete and reorder controls, "Add to Home" lists the rest with a
   `success` plus, then the weekly set target steppers and Restore Default Layout.

### 15.3 History (`Iron/UI/History/HistoryView.swift`)
Board: *Round 3 → History*, revised 2026-10-26. A segmented control (Workouts · Insights).
The cached Exercise Progress index lives in the toolbar's options menu. Workouts are
grouped by week, with headers showing the count in accent and volume in green. Each row has the
title, PR and RPE badges, "date · muscles" metadata and the metric line. The detail view has Repeat in its toolbar menu.

Chart controls and their chart belong in one continuous grouped row: metric selector above,
chart and headline together, and a labelled Period menu below. Never insert a transparent
segmented-control row between the top and bottom of a grouped card. Apply this to History,
Body Measurements and saved-workout trends. Large text gets a taller plot with fewer axis
labels. Use `ironHorizontalChartScrubbing` to keep vertical pans in the List.

Home, History and calendar summaries read the shared `TrainingHistoryStore` background
snapshot. Never traverse all workout relationships or search the catalog from a view body.
Use `ExerciseStore.exercisesByUUID` for catalog lookups. Snapshot refreshes follow history
saves, day/time-zone changes and app activation; changing a filter does not rescan Core Data.

### 15.4 Workout tab (`Iron/UI/Workout/StartWorkoutView.swift`)
Quick Start, Recent Workouts with one-tap Repeat, and Saved Workouts. Recent rows put the title,
metadata and metric line on the left and a bold text Repeat button, with the compact
rounded-rectangle border shape, on the right. Tapping the row opens details; holding it opens Save
as Workout, Repeat with Blank Sets and View Details. Save as Workout opens an isolated, prefilled
editor; Cancel preserves the source and Create saves a new copy.

### 15.5 Exercises (`Iron/UI/Exercises/*`)
- **Library** (`ExerciseMuscleGroupsView`): `.searchable`, two independent filter menus (muscle
  and equipment), and a **recency-first** order. Every exercise you have done, imported Hevy
  history included, comes first, newest first; the rest keep their existing order. Search
  results follow the same rule. This is implemented by `ExerciseStore.orderedByRecency` and
  `lastPerformedDates`. Row names use `.headline`; muscle and equipment labels are neutral
  capsules, and recency stays secondary. Native search, filters and navigation remain intact.
- **Detail** (`ExerciseDetailView`): see backlog B6 and boards *Round 5 → Exercise* and
  *History segment*.

Exercise detail keeps the exercise name in its page header only, with an empty inline
navigation title. Custom progress/target cards use the same outer gutter as native grouped
sections; do not add a second horizontal List-row inset.

### 15.6 Live workout (`Iron/UI/Workout/CurrentWorkoutView.swift`)
Boards: *Round 3 → Logger B · focused set*, *Round 4 → Live workout* (only the parts the backlog
adopts).

Top to bottom:
1. **Top bar:** `chevron.down` (minimize), "Log Workout" (`.headline`), the rest-timer button
   and the prominent **Finish** capsule.
2. **Session bar** (backlog B2): a thin progress bar segmented per exercise, with a 4 pt gap
   between exercises and a 1 pt gap between sets. It stays visible even when the header collapses.
   It belongs to the same `.bar` header surface as the toolbar and expanded metrics. Use fill only:
   no segment outline, separate panel fill or divider rules.
3. **Session header** (expanded by default, controlled by the user): the watch-sync banner (dot, status text such as
   "Saved on iPhone · Install Iron on Watch", device glyph, collapse chevron), then a summary row
   with **Duration** (`metricTime`, tap to edit), **Volume** (`metricVolume` plus unit),
   **Sets** (`metricSets`) and the **live muscle map** (54 pt front and back, completed sets
   only). Give duration/volume explicit columns with 12 pt gutters; sets use a narrower
   column and the 54 pt muscle figures keep their own space. Elapsed time reads `m:ss` below
   one hour and `h:mm:ss` above it. Captions align at the top even if a large value scales down.
4. **Collapsed state** (only after tapping the header chevron): the header is replaced by a
   full-width glass pill reading "● 18:42 • 2,430 lb • 6 sets ⌄". While the Watch is sending current
   readings it drops the dots and adds "♥ 132 🔥 210" in `metricHeartRate` and `metricEnergy`, so the
   row doesn't reflow as numbers grow; large type drops the readings first. It floats over the scroll viewport.
   Reserve its measured height, 8 pt top inset and 12 pt bottom gap with scroll-content
   margins so the first item starts below it. Scrolling content passes behind transparent
   glass; do not place an opaque strip behind it. Accessibility sizing grows the clearance.
   Scrolling never changes modes. Tapping the glass expands the summary at the current scroll
   position. Remember the choice for this workout in the scene, including minimize/reopen;
   a new workout starts expanded.
5. **Exercise card:** a 42 pt diagram thumbnail, the name (`.headline`), equipment
   (`secondaryText`), the rest chip top right (backlog B3), and an ⋯ menu (Replace, Superset,
   Reorder, Remove). Holding the name or thumbnail opens Arrange Exercises; a normal tap
   on the name still opens exercise detail. The sheet uses compact native rows and drag handles,
   stages changes until Done, and retains the source on Cancel. VoiceOver also offers a Reorder
   action and Move Up/Down within the sheet.
6. **Set rows:**
   - **Completed:** a compact row with the fill sweep, badge, values and check.
   - **Current, non-duration:** exactly **one focused editor in the entire active workout**.
     `WorkoutSetFocus` resolves the next unfinished set in workout order. A superset alternates
     by round (A1 → B1 → A2 → B2), skipping finished/empty members; unequal groups finish their
     remaining sets before advancing. Undo, deletion and reordering recompute from the model.
     The progress marker, automatic superset scroll and Live Activity use that same target.
     The raised card contains:
     - a header with "Set N" (it opens the set-type menu) and "Last time 200 × 5";
     - two tiles for weight and reps, each with a huge `ironMetric` TextField and 40 pt −/+
       circular steppers (2.5 in either lb or kg; 1 rep);
     - a plate picture and load hint for barbells or saved machine setups, opening the plate
       calculator; eligible machines without a setup show a "Plate Calculator" setup chip.
       Cable/pin-stack equipment has no automatic setup chip. Counts above four draw three
       representative plates with the real **×N** above them, in both hint and calculator;
     - an Add RPE pill;
     - a full-width 52 pt **Log Set** capsule in accent with a checkmark.
   - **Upcoming:** a compact row in secondary colors. Previous results and editable
     weight/reps/duration fields share `compactCornerRadius` (10 pt). Previous stays a quiet
     neutral readout; regular-row data boxes share the 46 pt field height. Editable values keep
     a soft fill and thin outline, including completed/color-filled rows. Never remove the
     field fill on completion: Previous, weight, reps and duration need equally visible
     neutral surfaces over the row color. Focus uses the accent fill and outline.
   - **Duration sets:** the compact row with an inline timer.
   - Rows swipe left to delete (§9.9).
   - **Unfilled sets:** `LoggerAssist.suggestedValues` supplies read-only weight/reps defaults
     while both values are zero. It inherits from the nearest same-type set above, then the
     matching previous-session set or fallback; warm-ups and working sets stay separate.
     Logging accepts the suggestion; merely showing it does not save it.
7. **After logging a set**, the logger scrolls that set to the top, with the rest strip and the next set under it. Going back to an earlier set scrolls to that set instead. Tapping a weight or reps box selects its value so typing replaces it, and a number stays `secondaryText` only while it still matches what was filled in; a focused or changed number is `primaryText`.
8. **Rest strip** under the set that started it: a `metricTimeContainer` rounded rectangle with
   `IronRestRing`, the countdown and "Rest of 2:30", then four 44 pt neutral circular buttons:
   **−15 · pause/play · +15 · skip**. Tapping the countdown opens the **inline rest-length
   ruler** (backlog B3); the old dial modal is retired.
9. **Add Exercises:** a prominent glass capsule button, then the bottom actions.

### 15.7 Workout complete (finish editor)
Board: *Round 3 → Workout complete*. Order: header (accent circle icon, name, date range); a
3 × 2 metrics grid (Duration, Volume, Sets, Exercises, Avg RPE, Records, each value in its metric
color); **How hard was it?** (`EffortRatingGraph`); `IronSessionStrip`; records list
(hidden when empty); the "Update saved workout" toggle; the Apple Health row (state: will save,
saved, waiting, imported, or not exported); notes and media; Save and Discard.

### 15.8 Settings
Native grouped `Form`/`List` sections with designed row anatomy. The owner rejected plain-text
native rows. Use `SettingsRowIcon` on every settings control/action row, with a wrapping title
and its control on the row: kg | lb segmented picker, estimated 1RM stepper, rest-length ruler,
or sound-preview play button (sound waves while playing). `SettingsToggle` keeps the native
switch beside its wrapping title. `SettingsActionLabel` adds a trailing action symbol,
replaced by a spinner and "Preparing…" while working. `SettingsStatusBadge` pairs a status word
with a green check or red exclamation; `SettingsConnectionHeader` combines the large connection
icon, name, badge and primary button on Health and Watch pages. Keep one short footer per group.

"Import & Export" holds the Hevy CSV import, backups and exports.
The "Imported Data" section follows Import: Hevy count/date range, "Replace with New Export…",
and destructive "Remove Imported Workouts". Both operations confirm the affected count and
explain that workouts logged in Iron are kept. Replacement chooses one workout CSV first;
failure preserves the old history. Measurements have no import-source tag and are kept.

### 15.9 Watch, widgets and Live Activity
- **Watch:** the exercise-first hierarchy in §21, native `List`/`Section` and glass controls,
  prominent Log Set, and the clock-safe vitals pill in §22.0. Same metric colors.
- **Widget:** `containerBackground(.fill.tertiary, for: .widget)`, with no solid accent slabs.
- **Live Activity:** the approved Set tile design in §20: exercise artwork, per-exercise blue
  completion cells and set position; compact surfaces omit the stopwatch. Expanded surfaces
  retain rest controls (−15 · +15 · Skip App Intents). A `.small` supplemental family is
  provided for the Watch Smart Stack. Active rest takes priority immediately after completing
  a set; it does not wait for the no-rest completion confirmation. ±15 intents publish their
  updated deadline before returning; the countdown stays visible without replacement fades.

### 15.10 Apple Health rule (behavior, not visual)
Only workouts **completed in Iron** (phone or Watch) are exported. Imported workouts (Hevy,
`importSource != nil`) are **never** exported. UI copy must say so where relevant.

## 16. Theming a screen from a screenshot

Use this procedure when you are given a screenshot of a screen that is not on-system (stock
SwiftUI, legacy Iron, or Hevy-like) and asked to "theme it".

**Step 1: inventory.** List every element in the screenshot and classify it: navigation chrome,
section or card, row, number, label, unit, icon, button (primary, secondary or destructive),
input, chart, badge, empty state, progress.

**Step 2: apply this mapping table** (left: what you see; right: what it becomes).

| You see | Make it |
| --- | --- |
| A custom-colored nav bar, tab bar or sheet background | Delete the custom background; let the system render it |
| Cards with borders or shadows stacked in a ScrollView | A `List(.insetGrouped)` with `Section`s, or one `surface` card (radius 22) when the content is a chart or graphic |
| Each row in its own card | Rows inside one `Section` |
| A plain number ("185", "1:30", "12") | `Text(...).font(.ironMetric(<style>))`, in its **metric color** if it measures sets, volume, time, effort, records or body; otherwise primary |
| A number with its unit in the same font | Split it: number in `ironMetric`, unit `.footnote` `secondaryText`, baseline-aligned |
| A row of 2–4 stats | Metric chips (§9.1) or metric columns, with values colored by metric |
| "1h 2m, 14 sets, 9860 lb" as plain text | The metric line pattern (§9.2) |
| Green on a "done" thing | Accent blue (completion) unless it is volume or success |
| Any gray, black or white `Color` literal | The semantic role from §3.1 |
| Rainbow muscle tags | Neutral tags (`secondarySystemFill` + `secondaryLabel`) |
| A primary button (filled) | `.ironProminentGlassButtonStyle()` floating over content, or `.borderedProminent` in a list; capsule shape; one per surface |
| A secondary button | `.bordered` or `.ironGlassButtonStyle()` |
| A delete button | `Button(role: .destructive)` plus a confirmation dialog |
| A custom segmented control or tabs | `Picker(.segmented)`, or §9.4 if it needs styling |
| A custom slider or dial for a discrete scale | `EffortRatingGraph`-style rising bars (intensity) or a ruler (time) |
| A wheel picker for RPE or effort | The rising bars (§8.6, backlog B5) |
| A chart drawn with shapes or a third-party library | Swift Charts following §10 |
| A "PR", "Best" or trophy marker | A record badge (§9.3) in `metricRecord` |
| An empty white screen with text | `ContentUnavailableView` (§9.6) |
| A spinner over the whole screen | Inline `ProgressView`, or the import overlay pattern for long work |
| Hand-drawn body or muscle graphics | MuscleMap `BodyView` with the §3.4 style |
| A modal popup with a single fact | A tooltip (§9.8) or `.popover` |
| Rounded font numbers | SF Pro via `ironMetric` |
| A corner radius that is not continuous, or random radii | `.continuous`, using 10, 12, 22 or capsule |
| Animations with ad-hoc durations | `IronMotion` tokens plus `preferred(_:reduceMotion:)` |
| Beeps | `IronSoundPlayer` cues |

**Step 3: hierarchy pass.** There is exactly one dominant action per screen. Titles are `.largeTitle`
at the root and `.headline` inline. Metadata is `secondaryText`. Max two type sizes per row.

**Step 4: color audit.** Every colored pixel must be accent, a metric role, a status role or
media. If you cannot say which role a color is, it is wrong.

**Step 5: states.** Design and verify empty, loading, error, light, dark, Dynamic Type XXXL and
Reduce Motion.

**Step 6: motion and feedback.** Add `numericText` to changing numbers, `snappy` to toggles and
selections, a `.selection` haptic to discrete steps, and sounds only for the §12 events.

**Step 7: check against §18.**

Worked example, a stock stats row:

```swift
// Before
HStack { Text("Volume: 9860 lb").foregroundColor(.green); Text("Sets: 14") }

// After
HStack(spacing: 0) {
    metric("Volume", value: "9,860", unit: "lb", tint: IronTheme.metricVolume)
    metric("Sets", value: "14", unit: nil, tint: IronTheme.metricSets)
}
func metric(_ label: String, value: String, unit: String?, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value).font(.ironMetric(.title2)).foregroundStyle(tint)
                .contentTransition(.numericText())
            if let unit { Text(unit).font(.footnote.weight(.semibold)).foregroundStyle(IronTheme.secondaryText) }
        }
        Text(label).font(.footnote).foregroundStyle(IronTheme.secondaryText)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
}
```

## 17. Retired components and banned techniques

Do not reintroduce any of these, or an equivalent under a new name.

| Removed | Use instead |
| --- | --- |
| `IronCard`, `IronScreenBackground`, `IronModalBackground` | `List`/`Form` with `Section` |
| `IronSectionTitle` | `Section` header |
| `IronHairline` | `Divider` |
| `IronDestinationHeader`, `ironDestinationScreen` | `.navigationTitle` + `ToolbarItem` |
| `IronMetricTile` | Metric chips inside one aggregate surface |
| `IronPrimary/Secondary/IconButtonStyle` | `.borderedProminent`, `.bordered`, glass styles |
| `IronCompact/Choice/UtilityPillButtonStyle` | `Picker`, or `.bordered` + `.capsule` |
| `IronPopupMenu`, `IronPopupAction` | `Menu`, `swipeActions`, `contextMenu` |
| `IronEffortCarousel` | `EffortRatingGraph` |
| `IronDateTimeButton` | `DatePicker` |
| `WatchCard`, `WatchActionButtonStyle` | watchOS `List`/`Section`, `.bordered` |
| The rest-timer radial dial modal | The inline rest-length ruler (backlog B3) |
| The RPE wheel sheet | Rising RPE bars (backlog B5) |

Banned techniques: `toolbarBackground`, `presentationBackground`, `design: .rounded`,
hard-coded colors for chrome, `GeometryReader` chart plotting, resetting entrance state in
`onDisappear`, `DragGesture(minimumDistance: 0)` on anything inside a scroll view, emoji in UI,
and gradients as decoration (gradients are allowed only inside effort bars).

## 18. Review checklist

- [ ] Light and dark: no hard-coded colors, and every color maps to a §3 role.
- [ ] Numbers use `ironMetric`; units are smaller and secondary; no rounded fonts.
- [ ] One primary action per surface; 44 pt targets everywhere.
- [ ] System chrome untouched (no toolbar or presentation backgrounds).
- [ ] Glass only on floating layers.
- [ ] Motion uses `IronMotion` plus `preferred`; Reduce Motion falls back to fades.
- [ ] Haptics and sounds match §12.
- [ ] Dynamic Type at AX sizes, VoiceOver labels and values, adjustable actions.
- [ ] Vertical scrolling works when a drag starts on any custom control.
- [ ] Final scroll content clears the tab bar and workout accessory
      (`floatingWorkoutBottomClearance`).
- [ ] Copy follows §13 (Workout, not routine; ×, −; Title Case buttons).
- [ ] Apple Health rule (§15.10) unaffected.

## 19. Workout organization (approved 2026-10-26)

Superset opens a native grouped sheet with Starting Exercise, a visual preview of the first
two rounds, then thumbnail selection rows. Partner selection stays local; selecting another
existing group includes its members. Create/Save is explicit and remains reachable at the
bottom; Cancel discards the draft. Preview chips use compact 10 pt corners, two columns at
standard sizes and a separate vertical stack at accessibility sizes. Changing text size while
the sheet is open must reflow offscreen chips without overlap. Empty/unequal set counts are
skipped correctly.

Arrange Exercises opens from a header hold or Reorder menu action. Native list handles stage
exercise order with Cancel/Done. Keep set editors stable underneath the sheet; no automatic
card collapse or custom drag gesture in the logger. Reordering preserves superset identities,
notes, timers and every set. VoiceOver exposes Move Up/Move Down actions. New sheets keep save
errors visible and dismiss only after successful persistence.

## 20. Light Live Activities (approved 2026-10-26)

The owner selected **Set tile** after reviewing `light-live-activities.html`. Compact surfaces
show cached exercise artwork and a blue square divided into set cells. Each cell fills as a set
is completed; the activity uses the actual per-exercise completed count, never the current set
ordinal. Cap dense tiles at twelve cells and use proportional fills for larger exercises.
Legacy activities without that count show their existing set-position text until refreshed.

All Live Activity surfaces use a black background with readable foregrounds, including Watch
Smart Stack and its larger presentation. Watch shows artwork/name, set position, the tile, and
secondary rest time with Skip when resting. Retain pause/resume and set completion actions.
Compact/minimal views do not show an elapsed or rest stopwatch; expanded views keep rest
controls available. The expanded iPhone island uses one full-width region below its sensor,
with safe content margins, artwork/name/set position, tile, and rest controls.

App branding is **Light**. Keep `IronTheme`, project/scheme names and compatibility identifiers
as implementation names; do not rename persistence keys, app groups, Health export metadata,
Watch companion IDs or backup formats as part of a display-name change. The owner will supply
the new icon. Credit the original Iron project and Karim Abou Zeid in README and About.


## 21. Light on Apple Watch: exercise-first (approved 2026-10-26)

Keep the OLED canvas black with native Watch navigation, lists, sheets and glass controls.
Watch `IronTheme` resolves the same metric hues without UIKit; `Font.ironMetric` is the shared
SF default-design numeric helper. Do not reintroduce rounded typography. Compact fields use
10 pt continuous corners. Glass is for controls/navigation, not layered content cards.

The default active screen lists **all exercises**, with artwork, muscle/superset context,
completed/total set counts and blue completion cells. Tap an exercise to see its sets, Add Set,
superset selection and Exercise Settings. Tap a set for weight/reps (or duration/distance), one
primary Log Set action and **Settings at the bottom**. Set type, RPE, notes, extra measurements,
plate calculator, undo and deletion belong there. There is no global ellipsis button. Each
screen has one title, clear of the system clock and back control.

Home mirrors the phone: New Workout, Saved Workouts, then History. Workout rows are generous
native rows with exercise/set totals and primary muscles; history also shows date and duration.
Saved and historical exercises drill into read-only sets, with explicit routine editing.
Live edits and saved-workout drafts preserve stable identifiers; closing an uncommitted draft
does not save it. Crown editors stage values until their native top checkmark (Done); closing
the sheet cancels. Numeric changes respect Reduce Motion. The rest screen uses cyan time,
native −15/pause/+15 controls, the next exercise and Start Next Set. Supersets rotate by round.

Deep menus use native List sections: all sets with values/status, set detail editors, exercise
notes/rest/replace/remove, visual thumbnail/check superset selection, accessible up/down order,
saved-workout drafts, history/repeat, units/sync, and finish/effort/discard. Keep a single root
navigation stack and reset to the active workout for Live Activity/user-activity launches.
Do not reset a draft merely because the scene becomes active.

During an active workout, heart rate and active kcal share the toolbar vitals pill (§22.0),
with red heart and orange flame symbols, except on pages with a trailing
button, where vitals are hidden to preserve the clock. The pill remains visible in Always On
and explicitly unredacted. Missing/stale heart rate shows a dash; never
manufacture a zero. Active energy remains Apple's native Traditional Strength Training estimate.
Distinguish edit sync from Health recording, report failures and offer Retry for failures only.
Never invent sensor readings for earlier edited start times.

Watch numeric editors (owner correction, 2026-10-26): weight values snap to **0.5** in both
lb and kg. Crown travel may accumulate fractionally internally, but only snapped detents are
shown and committed; weight ± buttons use 2.5 in either unit. Reps are integers. RPE uses 0.5,
durations 5 s and session effort whole numbers. Do not parse localized display strings back
into quantities.

Automatic recording (owner correction): a running native workout automatically starts or
recovers its Watch HealthKit recording. Recovery always runs first to avoid a duplicate session.
Opening the active app and receiving an active snapshot recheck recording. Record/Retry is an
exceptional recovery action for denied permissions or a failed start, never a normal opt-in.
Keep paused sessions paused and finalizing sessions intact. A failed automatic attempt must
not loop through permission/start requests. Sensor collection begins now, with no backfilled
heart-rate or calorie samples for earlier display time.

Recovered builders can temporarily omit their external-ID metadata. Associate the running or
paused session with the existing durable active projection locally, without rewriting live
builder metadata or starting another collection. Actual HealthKit metadata takes precedence
when available. Never use this fallback for inactive sessions or to replace a known identity.

## 22. Watch layout contract (binding for every lane, 2026-10-29)

These rules come from regressions on the owner's Watch. Every Watch UI change must follow them and **prove** them in its report.

### 22.0 Approved look first (owner, 2026-10-31; replaces the 2026-10-30 "native first" rule)
A lane that took "native first" literally removed Log Set, gave vitals their own row and shrank every value. The owner rejected it: "you absolutely butchered the watch display". The look below is the design; don't restyle it. Reference screenshots: `~/.local/share/light/approved/`.
- **Native parts, only here:** top-corner ✓ on rating pages (`ToolbarItem` with a plain `Button` + SF Symbol, so the system draws standard glass), and the system back button where a page has no vitals.
- **Vitals pill:** heart rate and calories share a 34 pt capsule in the toolbar, with width reserved for the clock and back control. It fits full readings, compact energy ("1.2k"), tighter readings, then heart rate alone; if none fits, it hides rather than crowding the clock. There is no KCAL caption; the flame carries that meaning. Pages with a trailing button hide vitals (`showsTrailingButton: true`).
- **Running rest screen:** back button and vitals in the toolbar row. Below it, the ring and a column of `+15 · Skip · −15` `watchNeutralCapsule()` buttons (50 pt wide below 180 pt width, 60 pt otherwise), with the column on the right, or on the left when the Watch is worn on the right wrist, because the buttons belong on the side the other hand reaches from. The next set's full exercise name and weight × reps run across the bottom, on one line when they fit and two otherwise. The ring only holds REST and the time. At accessibility type sizes the screen keeps the stacked readout with a `−15 · Skip · +15` row (44 pt tall below 180 pt width, 52 pt otherwise).
- **After Log Set:** RPE opens first when the set needs one, then slides to the rest screen on ✓ or after 5 s untouched. Rest's back button returns to RPE, which then waits for ✓. RPE opened by hand also waits for ✓. A set that already has an RPE skips this page, and new sets start unrated rather than copying an old rating. Only a manual action saves: ✓ saves the number shown and turning the wheel saves the new value. Opening RPE or letting the 5 s pass saves nothing, so the dimmed suggestion is never recorded on its own and that set stays unrated.
- **Vitals live in the toolbar row** beside the back button (`watchVitalsInset`). Never a separate row of their own.
- **Primary actions** are the big full-width capsule near the bottom: `watchGlassButton(prominent: true)` / `watchPrimaryCapsule()`, Liquid Glass tinted Iron blue. Never replace one with a small toolbar ✓ to save height. Never use native `.glassProminent` directly; it stops short of full width on larger Watches, so it won't line up with the tiles.
- **Data surfaces** are flat and dark, like the iPhone logger: set tiles and controls 15 pt radius, cards and rows 13 pt, `IronTheme.platter` fills. No glass, gloss or gradients around data. Selection changes color only.
- **Value tiles** use one fixed font size per row, set from the width that fits "188.5", so turning the Crown never resizes the number. Weight/reps split 54/46 (50/50 below 180 pt width).
- **Previous set** is read-only and always on the first screen; never tappable.
- **Scrolling lists** (`WatchContentList`) are flat and full width, with no carousel scaling, even 4 pt spacing and bottom padding so the last row scrolls clear of the rounded corners.
- **Crown:** every value control uses `watchCrownRotation`, never `digitalCrownRotation` directly. SwiftUI shows the green bar for any non-continuous rotation, and `.digitalCrownAccessory(.hidden)` doesn't affect it, so the helper uses continuous rotation and holds the value at its limits. A scrolling page with a tile that deselects uses `watchReturnsCrown(afterEditing:)`, so the wheel scrolls the page again as soon as the tile is released. Discrete scales use `sensitivity: .low`. The running rest countdown has no Crown binding; the rest-length picker does.
- **Use the whole screen:** measure with `GeometryReader` + `.ignoresSafeArea(.container, edges: .bottom)` where the bottom row is a capsule, centered text or tiles above the page dots. "So far from the bottom" is a repeated owner complaint. Only square-cornered graphics, such as RPE bars, must clear the display corners.
- **RPE and effort:** ✓ in the toolbar (vitals hidden), then context line, number, rising graph, small description centered at the bottom. Auto-accept 5 s after the Crown stops only when RPE appeared by itself after Log Set; opened manually or for effort, only ✓ confirms.
- **Notes** are text only. Rows say "Add Note" (accent) or preview two lines of the note, and an empty plan note has no row. On the note page the whole box is the control: a tap opens the system text input with the note filled in, Done saves, Cancel changes nothing. No Edit, Dictate, Save or Cancel buttons; Clear shows only when there is a note.
- **No visible "Test mode" text** on the Watch.
- **Secondary/destructive actions:** `WatchSecondaryButtonStyle` uses native Liquid Glass on watchOS 26, with a neutral-fill fallback. `WatchDestructiveButtonStyle` gives destructive confirmation a full-width red glass capsule with intrinsic height; use `watchGlassButton(destructive: true)`.
- **Controls entrance:** selecting the controls page animates metrics, then Pause/Exercise/Discard/Finish from the clock bar at 0.6 scale and zero opacity, using `IronMotion.snappy` with 40 ms stagger. It restarts on page selection, since TabView pre-renders; Reduce Motion uses a fade.
- **Empty/completed workout actions:** Add Exercise and Finish have an explicit `IronTheme.controlHeight + 8` height (52 pt) so the prominent style cannot stretch in the unbounded layout.

### 22.1 Fill the screen; design boldly
- The first screen of every Watch page uses the whole display: no empty bands and no floating controls.
- Primary button: **44 pt** tall at width < 180 pt, **50–52 pt** larger. Bottom clearance **6 pt** at width < 180 pt, **10 pt** larger, **16 pt** where page dots show. `WatchContentList` uses 8/14 pt from the screen edge, and Home adds 6 pt to that; a list on a dotted page passes `clearsPageDots: true`.
- Size hero values from the height **left over** after fixed rows; never use a fixed cap, except the value-tile rule above.
- Graphs and scales are bands at least **16 pt** tall (40 mm) and about **30 pt** (larger), never slivers.
- Prefer one bold element over several timid ones. When unsure, make the main thing bigger, not smaller.

### 22.2 Fit first, no scrolling for single-purpose pages
- Pickers and value pages (RPE, effort, rest picker, value editors) fit one screen from 40 mm (162×197 pt) through Ultra (211×257 pt). There's no ScrollView or List in their hierarchy (check wrappers like `watchVitalsInset` too).
- Long pages (Set Options, exercise list) may scroll, driven by the Crown, but their primary action stays on the first screen.
- Height budgets come from a `GeometryReader` at the **page** level, never one inside a ScrollView, where the height is unbounded.

### 22.3 The device is not the simulator
- On device, the top toolbar row (the back chevron plus a title like "Test mode", and the clock) takes about 44–50 pt. Budget from the real safe area that GeometryReader reports, never from screenshot pixels or assumed chrome.
- The Digital Crown must be focused on the value when the page appears (`.focusable()`, `@FocusState` set in `onAppear` and again in `.task`). If it isn't, the Crown scrolls the page on device even though the simulator looks fine.

### 22.4 Don't regress verified screens
- Approved screens: the Now page (Ultra), the rest screen, the set editor, the one-screen RPE and effort pages, the notes page. Reference screenshots live in `~/.local/share/light/approved/`.
- A lane that touches a file containing an approved screen must leave that screen pixel-equivalent unless the brief asks to change it. It states in its report which approved screens it affected.
- When fixing one screen, never change shared components (tiles, `WatchFirstScreenLayout`, the rating layout, safe-area modifiers) without listing every screen that uses them.

### 22.5 Interaction
- Minimal interaction: the app predicts the next step (set → rest → RPE → next set → next exercise → finish) and surfaces it without navigation.
- The Crown adjusts, and there's one primary button. Remove redundant − / + and Clear when the Crown covers them.
- Selection changes color only, never size. Widths never change while a value changes (base splits on field types and screen width, never on the live value).
- Previous is a read-only reference, never a link to another weight/reps editor. It belongs in the measured first-screen layout below the tiles and above any content action. Reserve its full text height before sizing the tiles; never push it below the fold or let it clip.

### 22.6 Required proof in every Watch lane report
1. Layout math, in points, for 40 mm (162×197) and 46 mm/Ultra (211×257), including the device toolbar row. Give each row's height, the primary button's bottom edge against the screen bottom, and the hero value's font size.
2. Every approved screen touched, and why it's unchanged or intentionally changed.
3. How Crown focus is established on appear.


### 22.7 Debug screenshot routes
Fixtures are gated by `DEBUG && targetEnvironment(simulator)` in `IronApp.swift`. Launch with `--light-watch-demo <route>`; `--hold-watch-flow` holds automatic transitions, and `--demo-weight 135.5` seeds a weight for checking tile fit.

Routes: `home`, `active`, `now`, `controls`, `exercises`, `exercise`, `set`, `options`, `catalog`, `tracking-type`, `set-type`, `superset`, `notes`, `plates`, `rest`, `rest-picker`, `warmup`, `rpe`, `rpe-manual`, `rpe-auto`, `effort`, `finish`, `discard`, `saved`, `saved-detail`, `saved-editor`, `history`, `history-detail`, `summary`, `empty`, `complete`, `after-log`, `after-rest`, `after-final-rest`.

