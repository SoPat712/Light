# Light Watch app and effort/RPE: build spec (Round 6, owner-approved 2026-10-26)

Designed by the lead (Claude). The owner approved Round 6 ("I like the artifact a lot") and the
two follow-ups in §3. Build exactly this. Do not redesign or add buttons, menus or screens.

- Canvas: https://claude.ai/artifact/XwxfzWTFvH2PNZWqMRpihv, page "Round 6 · Watch".
- Exact source for every value: `docs/design/watch-round6.dc.html` (Watch, all screens, with
  working logic in its script) and `docs/design/phone-effort-rpe.dc.html` (iPhone effort and RPE).
  **The Watch mockup is drawn at 2 px per point** (422 × 514 px = 49 mm Ultra, 211 × 257 pt).
  Halve every px value in it to get points. The phone mockup is 1 px per point.

## 0. Rules that override everything else

1. **Navigation is native.** Use one `NavigationStack`. Use the system back button and the system
   toolbar. Never hand-position a back button or the clock, because watchOS places them inside
   the curved display's safe area. Nothing may clip at a corner on 40, 42, 44, 46 mm or Ultra.
2. **The path is Home → workout (exercise list) → exercise (sets) → set editor.** There is no ⋯
   button and no "Actions" page anywhere. Secondary actions live at the bottom of the screen they
   belong to (§2.6, §2.7).
3. **Heart rate and active calories are always visible during a workout.** They sit in the
   top-leading toolbar slot, next to the back button, on every workout screen (§2.1), including
   Always On.
4. Preserve all existing store behavior: `WorkoutSessionManagerStore`, phone sync, outbox,
   automatic HealthKit recording, recovery, Live Activity and the 0.5 weight step. This is a
   **view rewrite**. Call the existing store methods (`updateSet`, `toggleSet`, `addSet`,
   `deleteSet`, `updateSetTag`, `addExercise`, `replaceExercise`, `deleteExercise`,
   `startRestTimer`, `stopRestTimer`, superset and reorder helpers, finish and discard). Imported
   workouts are never exported to Health.
5. Watch tokens live in `WatchIron Extension/UI/WatchDesign.swift` (`IronTheme`). Add the new ones
   there (§1). No literal colors in view code.
6. Accessibility: every control is a real `Button` with a label. Numbers have accessibility
   values. Respect Reduce Motion (`IronMotion.preferred`). Large text sizes wrap rather than clip.

## 1. Watch tokens (add to `WatchDesign.swift`)

| Token | Value | Use |
| --- | --- | --- |
| `background` | black | every screen |
| `platter` | #222224 | rows and cards |
| `platterRaised` | #333336 | set-number badge when not done |
| `glass` | `.glass` button style (watchOS 26), fallback `.bordered` | secondary buttons |
| `accent` | systemBlue #0A84FF; text on black #409CFF (`accentText`) | primary, current, links |
| `accentWash` | accent at 0.20 | Up Next card, current exercise row (0.16), focused field |
| `metricTime` | #64D2FF, wash 0.18–0.20 | elapsed time, rest ring, rest chip |
| `metricVolume` | #30D158 | volume |
| `metricSets` | #FF9F0A | set counts |
| `metricHeartRate` | #FF453A | BPM |
| `metricEnergy` | #FF9F0A; unit label #C77A00 | kcal |
| `metricEffort` | #FF375F | RPE |
| `metricRecord` | #FFD60A | PR badge |
| `danger` | #FF453A; destructive text #FF6961; destructive wash at 0.26 | delete, discard |
| `secondaryText` | #9C9CA3 | meta lines (≥ 4.5:1 on black and platter) |
| Set types | warm-up orange, drop indigo #5E5CE6 (text #A5A3FF), failure red | badge wash 0.26/0.34, done-row wash 0.16/0.22 |
| Done set row | accent at 0.22 (normal) or set-type done wash | |

Shapes (pt): rows and cards are `RoundedRectangle(cornerRadius: 13, style: .continuous)`; the Up
Next card is 15. Buttons are capsules. Supersets join rows with 5 pt inner corners and a 1.5 pt gap
(§2.4). Settings-style rows start with a 20 pt circle icon: white SF Symbol on a solid system
color (gray `#636366`, blue, cyan `#32ADE6`, red, pink, indigo `#5E5CE6`, yellow with a black
glyph, green with a black glyph, orange with a black glyph).

Type: use watchOS text styles, scaled to match the mockup on a 49 mm screenshot.
- Screen title: `.title3.bold()`.
- Row title: `.headline`.
- Meta: `.footnote`, secondary.
- Section header: `.footnote.weight(.semibold)`, secondary.
- Big numbers: `Font.ironMetric(.title, weight: .semibold)` or `.largeTitle`.
- Every number uses monospaced digits (`ironMetric`).

Never use the rounded font design.

Sizes (pt): the minimum row height is 48 for list rows and 52–56 for workout rows. Primary capsule
buttons are 38–42 tall. Exercise art is a 26 pt circle on white (existing cached catalog image,
with a dumbbell glyph as the fallback).

SF Symbols:

| Purpose | Symbol |
| --- | --- |
| Heart rate | `heart.fill` |
| Calories | `flame.fill` |
| Add | `plus` |
| Log | `checkmark` |
| Settings | `gearshape.fill` |
| Rest | `timer` |
| Superset | `link` |
| Replace | `arrow.triangle.2.circlepath` |
| Move | `arrow.up` / `arrow.down` |
| Notes | `note.text` |
| Delete | `trash.fill` |
| RPE | `chart.bar.fill` |
| Set type | `tag.fill` |
| Mark not done | `arrow.uturn.backward` |
| Finish | `flag.checkered` |
| Repeat | `arrow.clockwise` |
| Start | `play.fill` |
| Edit | `pencil` |
| Skip | `forward.end.fill` |
| Search | `magnifyingglass` |
| Dictation | `mic.fill` |
| iPhone | `iphone` |
| Sync | `arrow.triangle.2.circlepath` |
| Unit | `scalemass.fill` |

## 2. Screens (board names in parentheses)

### 2.1 Workout toolbar (every workout screen)

Leading slot, next to the system back button:
- `heart.fill` at 13 pt and the BPM value, both in `metricHeartRate`, value in `.ironMetric(.headline, .semibold)`;
- 7 pt gap;
- `flame.fill` at 13 pt with the kcal value in `metricEnergy`, followed by a small "KCAL" caption in the darker orange.

The icons are larger than the earlier checkpoint's, as the owner asked. Show "--" when there's no
sample. One accessibility element: "Heart rate N beats per minute, N active calories".

In Always On (`isLuminanceReduced`), keep the vitals at full color and dim the content to 45 %
opacity. The elapsed time drops seconds ("24 min"), and the timeline refreshes once a minute.

Verified on watchOS 27:
- a `topBarLeading` item replaces the system back button;
- the slot shows only one item.

So the vitals modifier (`WatchVitalsInset`) puts a single leading item there. It holds a plain 34 pt back circle (`glassFill`, dismiss) and the vitals, and it hides the system back button only while a workout runs. Home shows no vitals.

Type: names and buttons use `.footnote` semibold, and screen titles use `.headline` bold. Measured on the 49 mm simulator, this lands within about 15 % of the board's proportions. Secondary buttons use `WatchSecondaryButtonStyle` (neutral `glassFill` capsule); only the primary action uses accent glass.

### 2.2 Home (W6Home, W6HomeIdle)

The navigation title is "Light", shown in the accent color as the system title. Scrolling list,
from the top:
1. **When a workout is running:** a card on `accentWash`:
   - a dot and "In Progress" in `accentText`, `.footnote.semibold`;
   - the workout title, `.headline` bold;
   - a metric line: elapsed in cyan · "6/18 sets" in orange (completed count in orange, the rest secondary);
   - one 4 pt bar per set (blue when done, white at 0.2 otherwise).

   Tapping it opens the workout.

   **When no workout is running:** a prominent "New Workout" capsule (`plus`). It starts an empty
   workout and opens it.
2. "Saved Workouts" header, then the first 3 saved workouts. Each row shows:
   - the name;
   - "18 sets" in orange · "5 exercises" secondary;
   - the primary muscles, secondary.

   Then an "All Saved Workouts" capsule (white at 0.12, accent text).
3. "History" header, then the 3 latest workouts. Each row shows:
   - the name;
   - the date and time, secondary;
   - a metric line: duration in cyan · sets in orange · volume in green with "lb".

   Then "All History".
4. A Settings row with a gray gear icon.

Rows are bigger than the checkpoint's: 56 pt minimum, 3 lines.

### 2.3 Saved and History (W6Saved, W6SavedDetail, W6History, W6HistoryDetail)

**Saved Workouts list:**
- the same rows as Home;
- then a "New Saved Workout" glass button, which opens the existing saved-workout editor.

**Saved workout detail:**
- title, a sets/exercises line, and a muscles · "Last done …" line;
- a prominent **Start Workout** (`play.fill`), placed above the exercises so you don't need to scroll to it;
- the exercises as rows with art, name and plan ("5 sets · 205 lb × 5");
- an Edit Workout glass button at the bottom, which opens the existing editor reskinned with the same rows.

Starting a workout never happens from a list tap; it always goes through this detail screen.

**History detail:**
- title and date;
- the metric line;
- red heart "N avg" and orange flame "N kcal";
- a prominent **Repeat Workout** (`arrow.clockwise`), which creates fresh IDs (existing logic);
- exercise rows showing "4 sets · Best 315 lb × 5", with a yellow "PR" badge when the row has a record.

### 2.4 Workout, the exercise list (W6Workout, W6Empty, W6Aod)

This is the root of an active workout.
1. The title, then a metric line: elapsed in cyan · "3/18 sets" · volume in green.
2. An **Up Next card** on `accentWash`, corner radius 15. The next set is chosen by the same
   resolver as the phone (`WorkoutSetFocus` rules: in order, with superset members alternating by
   round). The card has:
   - **Top:** a button that opens that set's editor, with art, a caption ("UP NEXT" or
     "UP NEXT · SUPERSET", accent, `.caption2.bold`), the exercise name and
     "Set 4 of 5 · 205 lb × 5".
   - **Bottom:** a prominent **Log Set** capsule (`checkmark`). It logs the set with its current
     values and opens Rest (§2.8).

   When every set is done, the card becomes "Every set is logged" with a prominent Finish.

   An empty workout shows a card instead: dumbbell icon, "No exercises yet", and a prominent Add Exercise.
3. An "Exercises" header, then one row per exercise:
   - art, with a blue check badge when the exercise is complete;
   - the name;
   - one 4 pt bar per set;
   - "3 of 5 sets" or "All 5 sets done".

   The current exercise's row uses `accentWash` at 0.16. Superset members are preceded by a
   "Superset" label (accent, with `link`). Their rows are joined: the first has 13/13/5/5 corners,
   the middle 5, the last 5/5/13/13, with a 1.5 pt gap.
4. An Add Exercise glass button, a Finish Workout glass button (accent text, `flag.checkered`), and
   a plain "Discard Workout" in destructive text. Discard always confirms (§2.11).

### 2.5 Exercise (W6Exercise)

1. The exercise name (`.title3.bold`, up to 2 lines), then the equipment · muscles meta line.
2. Chips:
   - a rest chip (`timer` with "2:30", cyan on cyan wash) that opens Rest Timer;
   - when the exercise is in a superset, a superset chip (`link` with the partner names, accent) that opens the Superset picker.
3. Set rows (46 pt minimum):
   - **Badge (22 pt circle):** the set number, or W, D or F colored by type.
   - **Value:** "205 lb × 5", where "lb" is smaller and secondary.
   - **Sub line:**
     - done: "RPE 8" in pink, or "Done";
     - current: "Next · 205 × 5 · RPE 8.5" in accent;
     - upcoming: "Last 200 × 5", secondary.
   - **Trailing:** done shows an 18 pt filled blue check; not done shows an 18 pt ring. The ring is
     accent for the current set and white at 0.28 otherwise.
   - **Backgrounds:** done rows use the done wash for their type. The current row has a 1.5 pt
     accent inner stroke.

   Tapping a row opens the set editor.
4. At the bottom: an **Add Set** glass button, then an **Exercise Settings** glass button (`gearshape.fill`).

### 2.6 Set editor (W6Set)

1. The exercise name (one line, secondary), then "Set 4 of 5" (`.title3.bold`) with a set-type chip
   if the set isn't normal.
2. Two fields side by side, about 60 pt tall:
   - Weight: label "Weight · lb", value in `.ironMetric(.largeTitle)`;
   - Reps.

   The focused field has `accentWash` with a 1.5 pt accent stroke, and its label is accent. The
   **Digital Crown edits the focused field**: weight in 0.5 steps, reps in 1, with a detent haptic.
   Tapping the other field moves focus to it.
3. − and + glass capsules that step the focused field by 0.5 lb or 1 rep.
4. "Last time 205 × 5 · RPE 8.5", centered, secondary.
5. A prominent **Log Set**. If the set is already done, it reads **Save Changes**.

   Log Set marks the set done, pops this editor, and pushes Rest. When Rest ends, you're back on
   the exercise with the next set outlined.
6. "Set Settings" header, then:
   - RPE (pink icon; the value in pink, or "Add" in accent), which opens §3.2;
   - Set Type (indigo icon; value secondary), which opens the type list;
   - Mark as Not Done (only for done sets);
   - Delete Set (red icon, destructive text).

### 2.7 Exercise Settings (W6ExSettings), Rest Timer (W6RestPicker), Superset (W6Superset), Set Type (W6SetType)

**Exercise Settings rows:**
- Rest Timer (cyan, with the value);
- Superset (blue, with the partners or "None");
- Replace Exercise (gray), which opens the picker in replace mode;
- Move Up and Move Down, two half-width rows, dimmed at the ends;
- Notes (yellow), which opens dictation and Scribble and shows "Dictate";
- Delete Exercise (red), which confirms first.

**Rest Timer:**
- a cyan value in `.ironMetric(.largeTitle)`;
- −15 and +15 circles (38 pt) on either side; **the Crown also adjusts it in 15 s detents**;
- preset capsules 1:00, 1:30, 2:00, 2:30, 3:00 and 4:00, three per row, with the selected one filled cyan with black text;
- a Done prominent button.

**Superset:**
- the subtitle "Alternate sets with Bench Press";
- rows of the other exercises, each with a check toggle (selected rows use `accentWash`);
- a Done button.

It uses the existing superset membership logic.

**Set Type:** four rows (Normal, Warm-up, Drop Set, Failure), each with its badge, and an accent
checkmark on the selected one. Choosing one returns immediately.

### 2.8 Rest (W6Rest)

This is a full-screen page pushed after Log Set, with no back button but with the vitals.
- "Rest" title in cyan.
- A 112 pt ring with an 8 pt stroke: cyan progress on a cyan 0.2 track, with round caps, starting at 12 o'clock.
- Inside the ring: the remaining time in `.ironMetric(.largeTitle)`, and "of 2:30", secondary.
- −15 and +15 glass circles (38 pt) on each side.
- **The Crown adds or removes 15 s per detent**, with a click haptic. The owner confirmed this.
- "Next" plus the next set (exercise short name · weight × reps), one line.
- A Skip Rest glass capsule (`forward.end.fill`).

It closes automatically at zero with the existing end haptic and sound, and returns to the
previous screen. It uses the existing rest timer store and Live Activity. Rest belongs to this
page; don't put it on other pages.

### 2.9 Finish (W6Finish), Rate Your Effort (W6Effort), Saved (W6Done)

**Finish:**
- "Finish Workout" and the title;
- a 2-column grid of tiles: Duration (cyan), Volume (green), Sets "N of M" (orange), Avg Heart Rate (red), Active Calories (orange), Records (yellow);
- a Workout Effort row showing "7 · Hard" in the tier color, or "Add", which opens §3.1;
- a prominent Save Workout, a Keep Going glass button, and "Discard Workout" in destructive text.

**Saved:**
- a 58 pt blue circle with a check;
- "Workout Saved", then the title · duration;
- "On iPhone" (green `iphone`) and "In Health" (red heart, only when the Health save succeeded);
- a Done glass button that returns to Home.

### 2.10 Add or Replace Exercise (W6Picker)

- A search capsule with `magnifyingglass`, "Search" and `mic.fill`. Search uses the system text input with dictation.
- "Recent" (recency-first from history, the same ordering as the phone's `ExerciseRecency`).
- "All Exercises" (A–Z).

Rows have art, the name, and equipment · muscle. Choosing one adds or replaces it and returns.

### 2.11 Confirm (W6Confirm)

- A centered title ("Discard Workout?" or "Delete Exercise?");
- a secondary message with the count ("3 logged sets will be deleted. This can't be undone.");
- a destructive capsule (red wash, red text);
- a Cancel glass button.

### 2.12 Settings (W6Settings)

Rows:
- iPhone status (green when connected, with "Synced 2 min ago", or orange "Not connected");
- Sync Now;
- Weight Unit, a lb/kg segmented control inside one card;
- Health Recording, with the explanation "Heart rate and calories record during every workout";
- Default Rest;
- the version as a footnote.

## 3. Effort and RPE graphs (iPhone and Watch)

The owner asked for both to look like Apple Fitness's "Rate Your Effort".

### 3.1 Workout effort: `EffortRatingGraph` (iPhone finish sheet, Watch §2.9)

It should **match Apple's control almost exactly**:
- **Four blocks.** Widths are in a 3:3:2:2 ratio for levels 1–3 (Easy), 4–6 (Moderate), 7–8 (Hard)
  and 9–10 (All Out). The gap is 8 pt on iPhone and 4 pt on Watch.
- **Slanted tops.** Each block's top edge rises from left to right. Height fractions of the
  control height, left → right: Easy 0.22→0.385, Moderate 0.48→0.64, Hard 0.74→0.82, All Out
  0.905→1.0.
- **Corners.** Every corner is rounded: radius 18 pt on iPhone, 8 pt on Watch, as quadratic curves
  that follow the slope. Use `docs/design/phone-effort-rpe.dc.html` → `slantPath()` as the exact
  path recipe, implemented as `SlantedBarShape: Shape` in a new
  `Shared/UI/SwiftUI/SlantedBarShape.swift` compiled into both the iOS and Watch targets.
- **Dots.** One per level, spaced evenly inside its block, 18 pt above the bottom (9 pt on Watch).
  Radius 3 pt, 4.5 pt when selected.
- **Unrated state.** Blocks are `systemGray5` on iPhone and #262628 on Watch. Dots are white at 0.3.
- **Selected state.** Every block up to and including the selected tier fills with its tier color:
  Easy systemGreen, Moderate systemYellow, Hard systemOrange, All Out systemRed. The selected dot
  is white and larger; dots for lower levels are white at 0.75; dots above the selection inside the
  selected block are black at 0.28.
- **Readout above the graph.** The number in `ironMetric` (large) and the tier word, both in the
  tier color. On light backgrounds use Apple's accessible text variants: green #248A3D, yellow
  #B25000, orange #C93400, red #D70015.
- **Input:**
  - tapping a dot selects that level;
  - tapping a block selects its first level, or keeps the current level if it's already inside that block;
  - a horizontal scrub selects by position (reuse `ironHorizontalScrub`) without stealing vertical scroll;
  - on Watch, the Crown steps 1…10;
  - every change plays `.selection` haptics and animates with `IronMotion.snappy`;
  - VoiceOver is adjustable, read as "7 of 10, Hard".
- **Placement.**
  - iPhone: replace the existing `EffortRatingGraph` and `FinishWorkoutEffortControl` visuals (in
    `SwiftUISupport.swift` and `CurrentWorkoutView.swift`) in every place they're used, keeping
    their bindings and the unrated (0) behavior. The finish sheet gets the "Rate Your Effort"
    title, the readout, then the graph (about 190 pt tall at full width).
  - Watch: a pushed page titled "Rate Your Effort" with the context line (title · duration), the
    readout with − and + circles, the graph (85 pt), then Clear and Done.

### 3.2 Set RPE: `RPEGraph` (iPhone logger RPE popover, Watch §2.6)

The same language, but **not chunked**:
- **Bars.** 11 separate bars for 5, 5.5 … 10. Every half step is its own bar, which is how 0.5 is
  shown. The gap is 4 pt on iPhone and 2.5 pt on Watch.
- **Heights.** One continuous ramp across the whole width, 0.28 → 1.0 of the height. Each bar's top
  is the slanted piece of that ramp over its own x-range.
- **Corners.** `SlantedBarShape` with corner radius `min(8, barWidth / 2.6)` on iPhone and
  `min(4, barWidth / 2.6)` on Watch.
- **Fill.** Bars at or below the selection are `metricEffort` (pink); the rest are the gray base.
- **Labels.** Whole-number labels (5 6 7 8 9 10) centered under their bars, `.caption.semibold`, secondary.
- **Readout.** The value ("8.5") in pink `ironMetric` and the reps-in-reserve text from `RPE`
  (for example "1–2 reps left"), with a Clear button.
- **Input.** Tap or scrub; on Watch the Crown moves in 0.5 steps; haptics; VoiceOver adjustable
  ("RPE 8.5, 1 to 2 reps left").
- **Placement.** Replace the set RPE `IronIntensityGraph` use in `CurrentWorkoutView.swift`. Remove
  `IronIntensityGraph` if nothing else uses it.

## 4. Done means

- Watch and iPhone both build for the simulator and for the device.
- Every Round 6 board is matched on the 49 mm and 42 mm simulators, and nothing clips at the
  corners.
- The Up Next, Log Set, Rest, Crown and Finish paths work against the real store, and phone sync
  still works.
- The effort and RPE graphs replace the old bars on both platforms.
