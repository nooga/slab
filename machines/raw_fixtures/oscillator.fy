( oscillator.fy - raw DSP2 fixture machine with one note-controlled saw. )

ustruct: RawOscState
  f64 phase
;

ustruct: RawOscParams
  f64 note-hz
  f64 amp
  f64 inv-sample-rate
;

( state params sample-rate -- : update block-rate derived params. )
dsp2: raw-osc-prepare
  | state params sample-rate |
  1.0
  sample-rate
  f/
  params RawOscParams.inv-sample-rate-p
  f!64
  drop2 drop
;

( state params hz velocity -- : start a note and reset phase. )
dsp2: raw-osc-note-on
  | state params hz velocity |
  hz
  params RawOscParams.note-hz-p
  f!64
  velocity
  params RawOscParams.amp-p
  f!64
  0.0
  state RawOscState.phase-p
  f!64
  drop2 drop2
;

( state params -- : stop the note immediately. )
dsp2: raw-osc-note-off
  | state params |
  0.0
  params RawOscParams.amp-p
  f!64
  drop2
;

( out state params -- : render one mono saw sample. )
dsp2: raw-osc-render
  | out state params |
  state RawOscState.phase@
  params RawOscParams.note-hz@
  params RawOscParams.inv-sample-rate@
  f*
  f+
  fwrap01
  | phase |
  phase
  state RawOscState.phase-p
  f!64
  phase
  2.0
  f*
  1.0
  f-
  params RawOscParams.amp@
  f*
  out
  f!64
  drop
  drop2 drop
;
