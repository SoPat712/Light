# Exercise catalog and Hevy matching audit — 2026-10-25

The owner reported many exercise pictures replaced by an apparent “0”. A read-only copy of
`custom_exercises.json` from the installed phone app contained **49 custom definitions, all
without muscle metadata, PDF paths or remote-media filenames**. No phone workout database was
copied or changed for this audit. The glyph was `o.circle.fill` for the “other” muscle group.

## Causes

- Import matching normalized punctuation and reordered tokens, but had very few actual
  synonyms. Hevy “Bicep Curl (Machine)” did not match “Biceps Curl: Machine”; “Machine” did
  not bridge the catalog's “Lever” naming. Unmatched exercises were created with empty
  metadata and a distinct custom UUID. Changing the matcher alone would not repair them.
- Iron bundles **1,441** entries; 1,324 have remote media filenames, 159 have PDF references
  (some overlap). Only 71 entries originally had aliases. The catalog last changed in
  `adec86d` (2026-08-27); it mixes retained legacy Everkinetic entries with ExerciseDB V1
  metadata. It has no explicit upstream dataset version. The provider currently advertises
  1,500 free V1 entries, also confirmed by its public endpoint's metadata. A complete upstream
  diff was not obtained: the paginated probe stopped on a non-JSON response.
- A sampled current CDN GIF was **180 × 180**, 12 frames. Upscaling cannot add detail.

## Initial recovery

`hevy-aliases.json` adds 24 reviewed synonyms to 23 canonical IDs. Existing custom definitions
receive missing metadata/media **in memory**, retaining their UUID, original Hevy name and
all historical relationships. This restores media for **24 of the 49** observed definitions.
Original custom JSON is not rewritten at launch, and histories are not merged. Explicit
custom muscles/media or contradictory equipment choices are preserved. Future import
matching indexes real titles before aliases, so an existing custom title continues to resolve
to its original UUID. A genuinely new alias can resolve directly to a built-in entry.

Unknown-image fallback is a neutral strength-training figure, with no O glyph or extra letter. Custom Exercises
uses the same illustrated row component as the library and picker.

## Image options

- [ExerciseDB V1 media](https://docs.ascendapi.com/products/edb-v1/overview): current free media
  is 180p GIFs. Clean 360–1080p media is on the paid tier.
- [ExerciseDB V2](https://docs.ascendapi.com/products/edb-v2/overview): higher-resolution images
  and videos; free media is watermarked. This would require a provider integration and owner
  API setup; no credentials or subscriptions were created.
- [wger](https://github.com/wger-project/wger#license): exercise data uses Creative Commons
  licenses per entry. It is a candidate for selected replacements after per-image review,
  rather than an already-verified uniform replacement library.
- [free-exercise-db image provenance](https://github.com/yuhonas/free-exercise-db/issues/2):
  the maintainer explicitly could not establish the images' origin/reuse rights. Its code's
  Unlicense should not be treated as proof of image rights. No such images were imported.

## Remaining 16 names requiring a specific variant or new catalog coverage

Do not merge these automatically with a related but different movement. Their existing names,
IDs and workout records remain available. An illustrative picture and a canonical history
merge are separate decisions.

- **Seated Triceps Press** — The title does not identify equipment or whether this is a press versus a triceps extension; mapping would guess both movement and machine/device.
- **Lat Pulldown (Machine)** — The machine candidate is specifically reverse-grip leverage equipment, while the custom title does not specify grip or subtype.
- **Single Arm Cable Row** — Single-arm cable row is shared by bent-over, seated, and kneeling/high-row catalog variants; position is missing.
- **Calf Extension (Machine)** — Extension does not identify whether the intended movement is a calf press or seated/standing calf raise.
- **Abdominal** — Generic body-area wording does not identify a movement, apparatus, or position.
- **Seated Calf Raise** — Position matches but equipment is absent; machine, barbell, and dumbbell variants cannot be conflated.
- **Iso-Lateral Row (Machine)** — Iso-lateral machine behavior is not represented by one catalog title; high, seated, and unilateral rows are different movements.
- **Iso-Lateral Chest Press (Machine)** — Iso-lateral behavior and press angle are not preserved by the generic or incline catalog candidates; machine subtype is ambiguous.
- **Seated Cable Row - Bar Grip** — The custom bar-grip qualifier has no exact catalog counterpart, and high/low/rope seated rows differ mechanically.
- **Treadmill** — The only treadmill catalog entry adds walking and incline qualifiers absent from the custom title.
- **Triceps Extension (Dumbbell)** — Dumbbell equipment matches, but lying/standing/seated and one-arm variants are not interchangeable.
- **Jacobs Ladder** — No Jacobs Ladder or equivalent ladder-climb entry exists in the catalog.
- **Cable Core Palloff Press** — The catalog only has band Pallof presses and distinguishes horizontal versus vertical; cable equipment cannot be conflated.
- **Goblet Squat** — Goblet squat equipment is omitted; dumbbell and kettlebell variants must remain distinct.
- **Cycling** — No generic cycling entry exists; stationary, air, and upper-body bike movements are distinct.
- **Iso-Lateral High Row (Machine)** — The catalog does not encode an exact iso-lateral machine variant; unilateral, cable, and lever high rows differ.

## Verification

- Actual Foundation resolver + mechanically extracted production importer matcher: **173
  checks passed**, including all aliases, UUID/name preservation, idempotence, ambiguity,
  custom fields/equipment and existing-custom precedence.
- Three integration regressions added to `ExportImportWorkoutDataTests.swift`; test bundle
  compiles. XCTest execution remains limited by the previously documented simulator host issue.
- A disposable simulator received a copy of the exercise definitions only; searching “Leg
  Raise Parallel Bars” displayed its recovered picture and Abdominals/Body Weight metadata.
  Phone custom-file bytes remain unchanged by the recovery path.

## Owner redirect: current OpenGym catalogue/stills and Watch

The owner stopped the V2 comparison direction and asked to use OpenGym's catalogue/still
approach, then asked whether to use OpenGym itself, with native Watch heart rate essential.
The GitLab URL is a mirror; the primary project is
[GitHub](https://github.com/DuarteSantos8/openGym).

The current [catalogue guide](https://github.com/DuarteSantos8/openGym/blob/main/catalogue/README.md)
uses permanent per-exercise JSON IDs and separate `media/still/<id>.webp` / `media/clip/<id>.mp4`
files. Repository media is 180 px. Its [NOTICE](https://github.com/DuarteSantos8/openGym/blob/main/NOTICE.md)
explicitly separates media rights from the code/text: the media is licensed to OpenGym, with a
limited non-commercial OpenGym-fork exception, and cannot simply be integrated into an
independent app. Higher resolutions exist only in its compiled app packages. The original
1,324 text entries retain their MIT provenance; newer text/edits/descriptions are AGPL.
Iron's root license is GPL v3. OpenGym artwork is not included. The later text integration is described below, with bundled AGPL/MIT notices.

OpenGym's [published App Store listing](https://apps.apple.com/us/app/opengym-workout-tracker/id6822275400)
now includes Apple Watch, heart rate, set/rest controls, Hevy import and optional Apple Health.
Its native watch source at commit `042c9ee42282756ab0e6e86a1cd5c710efaecee6` contains
`HKWorkoutSession`, `HKLiveWorkoutBuilder` and an anchored heart-rate query in
`frontend/ios/App/Watch/WorkoutManager.swift`. It is a companion Watch app; cached sessions
can continue while the phone is unreachable. These were source-verified, not physically tested.
The owner's Watch requirement therefore does not by itself rule out trying OpenGym.


## Current dataset update and imported-history matching

The owner explicitly chose to keep Iron and requested an OpenGym-based main dataset update,
plus matching imported Hevy history (not API/account synchronization).

- Canonical text source: OpenGym revision `042c9ee42282756ab0e6e86a1cd5c710efaecee6`.
  `scripts/import_opengym_catalogue.py` reads JSON only and generates 5,632 definitions,
  excluding 922 variant-only records. The converter preserves all 1,324 existing media-prefix
  UUIDs/IDs and generates stable UUIDs/negative IDs for 4,308 new definitions.
- `ExerciseCatalogMetadata.updatingCatalog` replaces the 1,324 known definitions in place,
  keeps 117 legacy-only exercises, and appends the 4,308 new definitions. Iron's main library
  therefore contains **5,749 built-ins**, with every original UUID/ID/media reference retained.
  Original titles remain aliases when renamed upstream. New entries without existing artwork
  show their muscle/equipment metadata and the neutral strength-training placeholder.
- Nine additional reviewed Hevy aliases resolve cable low-to-high twist, dead hang, barbell hip
  thrust, close-grip pulldown, horizontal leg press, seated V-grip cable row, seated cable fly,
  stair machine and toes-to-bar. In the observed phone definitions, **33/49 recover metadata**
  and **25/49 have existing-source pictures**. The 16 names above remain unguessed.
- Existing custom exercise UUIDs, original Hevy names and on-disk file bytes remain intact.
  An exact custom title takes priority over a canonical title or alias during reimport.
  No historical records are merged or reimported. New imports can resolve the reviewed aliases
  directly to the expanded built-in catalog.
- Catalog provenance, output hashes, upstream MIT notice and AGPL license are bundled under
  `everkinetic-data/Licenses/`; Settings attributes both text sources. OpenGym's media notice
  permits a limited non-commercial OpenGym-fork exception and explicitly excludes independent
  app integration. No OpenGym stills or clips were read, processed or included.
- List thumbnails now persist a PNG of the first frame from Iron's existing ExerciseDB media.
  Demonstrations retain the original animation. Native resolution remains 180 px; this is a
  cache/loading improvement, not higher-resolution artwork. Separately licensed bundled
  `catalogue/still/` files can be resolved without changing workout identities.

Verification for this update:

- Actual Foundation metadata/merge code and mechanically extracted production Hevy matcher
  passed: all 1,441 original IDs/media retained, 5,749 unique built-ins, 33 fresh aliases,
  all 49 observed custom UUIDs preserved, and a custom/built-in exact-title collision.
  Catalog decode plus name indexing took approximately 0.21 s on this Mac.
- Actual `ExerciseMediaStore` fixture harness passed: the original 12-frame GIF stayed intact;
  a native 180 px one-frame PNG persisted; offline, fresh-store and local-file reads succeeded.
- Five new catalog/import regressions cover merge retention, direct alias import, in-memory
  recovery without file rewrite, reviewed ambiguity and exact custom-title precedence.
- Simulator `build-for-testing` compiled the app and regression bundle; the final signed
  iPhone/Watch Debug build passed. XCTest execution remains limited by the previously
  documented test-host service stall; these new XCTest cases are not claimed as executed.
- Simulator search for “Hip Thrust (Barbell)” found the canonical and existing custom entries;
  the custom detail showed its Hevy name, Glutes/Barbell metadata, target map and instructions.
  Five persisted list PNGs were created while 1,324 original GIFs remained cached.
  Screenshots are in the task's `iron-cohesion/opengym-*` artifacts. The stale 1,400+ search
  prompt was corrected to “Search exercises”.
- The final signed app installed and launched on Josh's iPhone. An optional post-install
  device-to-host copy for byte comparison was blocked by automatic approval review because
  it could contain personal exercise data; no transfer was retried. Phone-file byte equality
  is not claimed for this update. Iron's simulator was shut down and shared slots released.

## One illustrated set and OpenGym revision `b6cfe2b` — 2026-11-02

The owner asked to replace the black-and-white outline icons with the cohesive set.

- **Art sources today:** of 5,749 built-ins, 1,324 have ExerciseDB art, 117 had only Everkinetic
  PDF outlines, and 4,308 have no picture. The ExerciseDB art is free-tier 180 px GIFs.
- **`legacy-art.json`** maps 116 of the 117 outline exercises to the same movement's existing
  art. Each pairing was chosen by hand and its first frame checked on a contact sheet. It is a
  separate file because the OpenGym importer requires each media prefix to be unique in
  `exercises.json`. UUIDs, titles, aliases, PDFs and history are unchanged. Supermans has no
  matching picture. Several pictures are close rather than exact: Leg Press (Narrow Stance) uses
  the standard leg press, and Leg Curl (Standing) shows a bodyweight curl, not a machine.
- **OpenGym has no consolidated list.** Its README says an id is never deleted and a duplicate
  is fixed by improving one entry. Against the earlier revision, 316 exercise files changed and
  none were added or removed. They add `hold` (135), `needs` (110), and equipment or body-part
  corrections. Iron's importer reads equipment but not those new fields, so regenerating changed
  46 entries. Iron guesses timed holds from names, so wall sits and L-sits still default to reps.
- **Default lists:** the owner asked for high-quality exercises over every exercise, and for
  caution: "I'd rather miss some than get rid of too many". Of 5,749 built-ins, default lists show
  1,383. No exercise is deleted, and history, imports and UUIDs are unchanged. Search and "Show N
  More Exercises" reach the rest, browsable entries first. A custom exercise, or anything in a
  workout or saved workout, always stays listed. The Watch list honors the same rule and its search
  reaches everything. Pinned chart selection is deliberately unchanged.
- **`catalog-duplicates.json`** has 58 entries, chosen by name: 43 older names for the same
  exercise, 7 camera-angle or female-figure copies, 2 spelling variants and 6 exact same names.
  Each names the entry to keep. "V. 2" entries were left visible because the name doesn't show
  whether they differ. Anything Hevy imports map to was left out, which excluded
  Bench Press: Machine, Biceps Curl: Machine and Triceps Pushdown: Cable with and without rope.
  Plain common names such as Crunch, Plank, Leg Press and Leg Extension also stay.
- **ExerciseDB's free tier** has 1,500 entries. It includes all 1,324 pictures Iron uses and 176
  more, of which only 2 exactly name a no-picture exercise, so it doesn't close the gap. Its README
  calls the free endpoints "for exploration only and not recommended for production integration".
- **Before a public release:** OpenGym's text may be used under the bundled AGPL and MIT notices;
  its media may not. No terms were found that confirm commercial use of the ExerciseDB media,
  or caching it: the terms link (`dub.sh/exercisedb-api-tos`) refused automated access. Read the
  terms or ask the provider. Its paid tier offers 360p to 1080p; prices were not retrieved.
