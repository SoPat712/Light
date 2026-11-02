# Third-party notices

## Exercise catalogue and instructions

Iron's generated exercise catalogue uses metadata and English instruction text from the
`hasaneyldrm/exercises-dataset` data included through the supplied openGym reference material.
That metadata and text are distributed under the MIT License:

> Copyright (c) 2026 Hasan Emir Yıldırım
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software
> and associated documentation and data files (the "Software"), to deal in the Software without
> restriction, including without limitation the rights to use, copy, modify, merge, publish,
> distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
> Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
> BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Source: https://github.com/hasaneyldrm/exercises-dataset

### OpenGym catalogue updates

Iron also includes the current OpenGym exercise names, muscles, descriptions and instructions,
adapted from revision `b6cfe2bbd3f099523ffbf2677438864e9a09a06f`.
Copyright (C) 2026 Duarte Santos and contributors. OpenGym-authored text and corrections are
licensed under GNU AGPL version 3; the original ExerciseDB text retains the MIT notice above.

The converted JSON, source-ID map and converter ship in Iron's source tree. The full AGPL,
upstream text notice and pinned source/hash manifest are bundled under
`WorkoutDataKit/everkinetic-data/Licenses/`. No OpenGym exercise media is included.

Source: https://github.com/DuarteSantos8/openGym/tree/main/catalogue

## Exercise images and animations

The JPG/GIF exercise media is not bundled into Iron. When an internet connection is available,
Iron extracts the upstream ExerciseDB media ID and requests the corresponding 180p GIF from the
official free ExerciseDB V1 CDN (`static.exercisedb.dev`). The upstream dataset notice asks that
every use carries this attribution:

> © Gym Visual — https://gymvisual.com/

The media is not covered by the dataset's MIT License. The dataset identifies Gym Visual as the
rights holder and says its permission is not transferable, while ExerciseDB presents the official
V1 hosted media as a free app-development API. These provenance claims are not treated as legally
resolved by runtime loading. Product distribution may therefore require written confirmation from
the relevant rights holder. Iron retains its original bundled diagrams for the exercise detail
page of any exercise without other media.

Iron saves the first frame of its existing provider's GIFs as a persistent PNG for list
thumbnails, preserving the original animation for demonstrations. This does not increase the
source resolution. OpenGym's separately licensed stills and clips are not copied into Iron;
its media notice limits the non-commercial exception to forks of OpenGym.

## Muscle maps

Iron vendors `MuscleMap` 1.6.4 in `Packages/MuscleMap`, retaining its license and adding a public
hit-test facade for hold-and-scrub. It renders front/back muscle highlighting. The package is
separate from OpenGym and is licensed under MIT:

> Copyright (c) 2026 Melih Colpan
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software
> and associated documentation files (the "Software"), to deal in the Software without
> restriction, including without limitation the rights to use, copy, modify, merge, publish,
> distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
> Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
> BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Source: https://github.com/melihcolpan/MuscleMap
