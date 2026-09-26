( pages.fy - raw DSP2 fixture exercising the tabbed-panel `page` vocab.
  Two tabs, each with one strip in a single row; silent output. )

ustruct: RawPagesState
  f64 dummy
;

ustruct: RawPagesParams
  f64 a
  f64 b
;

( io ctx state params -- : write one silent mono sample. )
dsp: raw-pages-render
  | out ctx state params |
  0.0 out f!64
  drop2 drop drop
;

include "../lib/manifest.fy"

: manifest
  "raw-pages" voice-sample machine*
  "raw-pages-render" render!
  RawPagesState.size  state-size!
  RawPagesParams.size params-size!

  "AONE" "A" "a" RawPagesParams.a 0.0 1.0 0.5 curve-lin knob
  "BTWO" "B" "b" RawPagesParams.b 0.0 1.0 0.5 curve-lin knob
  "AONE" 1 strip
  "BTWO" 1 strip

  "PAGE A" page
    1.0 row  1.0 cell  "AONE" 1.0 item
  "PAGE B" page
    1.0 row  1.0 cell  "BTWO" 1.0 item

  machine-desc
;
