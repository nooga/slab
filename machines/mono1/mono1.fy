( mono1/mono1.fy - staged rebuild, Stage F.
  Signal path: oscillator/sub/noise mixer -> HPF -> driven resonant LPF with bipolar env/key mod -> amp ADSR -> gain. )

include "../lib/machine.fy"

:: _lib "/usr/lib/libSystem.B.dylib" dl-open ;
:: _pow _lib "pow" dl-sym ;
:: _exp _lib "exp" dl-sym ;
noalloc: pow _pow bind: dd:d ;
noalloc: exp _exp bind: d:d ;

:: SR_DEFAULT 48000.0 ;
:: TWO_PI 6.283185307179586 ;

( --- Voice state ------------------------------------------------ )
:: phase-cell 4 alloc ; 0.0 phase-cell f!32   ( normalized 0..1 )
:: step-cell  4 alloc ; 0.0 step-cell  f!32   ( cycles per sample )
:: sub-phase-cell 4 alloc ; 0.0 sub-phase-cell f!32
:: sub-step-cell  4 alloc ; 0.0 sub-step-cell  f!32
:: base-step-cell 4 alloc ; 0.0 base-step-cell f!32
:: pitch-cell 4 alloc ; 60.0 pitch-cell f!32
:: vel-cell   4 alloc ; 1.0 vel-cell   f!32
:: amp-cell   4 alloc ; 0.0 amp-cell   f!32
:: stage-cell 4 alloc ; 0 stage-cell !32       ( 0=idle 1=att 2=dec 3=sus 4=rel )
:: lfo-phase-cell 4 alloc ; 0.0 lfo-phase-cell f!32
:: lfo-delay-cell 4 alloc ; 0.0 lfo-delay-cell f!32
:: lfo-cell 4 alloc ; 0.0 lfo-cell f!32
:: attack-coeff-cell 4 alloc ; 0.0 attack-coeff-cell f!32
:: decay-coeff-cell 4 alloc ; 0.0 decay-coeff-cell f!32
:: release-coeff-cell 4 alloc ; 0.0 release-coeff-cell f!32
:: lfo-inc-cell 4 alloc ; 0.0 lfo-inc-cell f!32
:: hp-coeff-cell 4 alloc ; 0.0 hp-coeff-cell f!32
:: filter-coeff-cell 4 alloc ; 0.0 filter-coeff-cell f!32
:: gain-cell 4 alloc ; 0.5 gain-cell f!32
:: saw-level-cell 4 alloc ; 0.0 saw-level-cell f!32
:: pulse-level-cell 4 alloc ; 0.0 pulse-level-cell f!32
:: pw-cell 4 alloc ; 0.5 pw-cell f!32
:: sub-level-cell 4 alloc ; 0.0 sub-level-cell f!32
:: noise-level-cell 4 alloc ; 0.0 noise-level-cell f!32
:: mix-sum-cell 4 alloc ; 1.0 mix-sum-cell f!32
:: sustain-level-cell 4 alloc ; 0.7 sustain-level-cell f!32
:: cutoff-cell 4 alloc ; 0.7 cutoff-cell f!32
:: fenv-bipolar-cell 4 alloc ; 0.0 fenv-bipolar-cell f!32
:: keytrack-cell 4 alloc ; 0.0 keytrack-cell f!32
:: res-gain-cell 4 alloc ; 0.0 res-gain-cell f!32
:: drive-gain-cell 4 alloc ; 1.0 drive-gain-cell f!32
:: lfo-delay-sec-cell 4 alloc ; 0.0 lfo-delay-sec-cell f!32
:: lfo-delay-inc-cell 4 alloc ; 0.0 lfo-delay-inc-cell f!32
:: lfo-pitch-amt-cell 4 alloc ; 0.0 lfo-pitch-amt-cell f!32
:: lfo-pw-amt-cell 4 alloc ; 0.0 lfo-pw-amt-cell f!32
:: lfo-amp-amt-cell 4 alloc ; 0.0 lfo-amp-amt-cell f!32
:: lfo-cut-amt-cell 4 alloc ; 0.0 lfo-cut-amt-cell f!32
:: blep-t-cell  4 alloc ; 0.0 blep-t-cell  f!32
:: blep-dt-cell 4 alloc ; 0.0 blep-dt-cell f!32
:: hp-prev-in-cell 4 alloc ; 0.0 hp-prev-in-cell f!32
:: hp-prev-out-cell 4 alloc ; 0.0 hp-prev-out-cell f!32
:: filt-in-cell 4 alloc ; 0.0 filt-in-cell f!32
:: f1-cell 4 alloc ; 0.0 f1-cell f!32
:: f2-cell 4 alloc ; 0.0 f2-cell f!32
:: f3-cell 4 alloc ; 0.0 f3-cell f!32
:: f4-cell 4 alloc ; 0.0 f4-cell f!32
:: out-cell   4 alloc ; 0.0 out-cell f!32

( --- Labels ----------------------------------------------------- )
:: _lbl_m1  "MONO1" cstr-new ;
:: _lbl_dco "DCO"   cstr-new ;
:: _lbl_rng "RNG"   cstr-new ;
:: _lbl_16  "16"    cstr-new ;
:: _lbl_8   "8"     cstr-new ;
:: _lbl_4   "4"     cstr-new ;
:: _lbl_pul "PUL"   cstr-new ;
:: _lbl_pw  "PW"    cstr-new ;
:: _lbl_saw "SAW"   cstr-new ;
:: _lbl_sub "SUB"   cstr-new ;
:: _lbl_noi "NOI"   cstr-new ;
:: _lbl_vcf "VCF"   cstr-new ;
:: _lbl_hpf "HPF"   cstr-new ;
:: _lbl_cut "CUT"   cstr-new ;
:: _lbl_res "RES"   cstr-new ;
:: _lbl_drv "DRV"   cstr-new ;
:: _lbl_env "ENV"   cstr-new ;
:: _lbl_key "KEY"   cstr-new ;
:: _lbl_amp "AMP"   cstr-new ;
:: _lbl_att "ATK"   cstr-new ;
:: _lbl_dec "DEC"   cstr-new ;
:: _lbl_sus "SUS"   cstr-new ;
:: _lbl_rel "REL"   cstr-new ;
:: _lbl_gn  "GAIN"  cstr-new ;
:: _lbl_lfo "LFO"   cstr-new ;
:: _lbl_rat "RAT"   cstr-new ;
:: _lbl_dly "DLY"   cstr-new ;
:: _lbl_pit "PIT"   cstr-new ;

( Stage F params only. Later stages append fields; do not pre-expose
  inert controls while auditioning the oscillator. )
struct: Mono1State u32 unused ;
struct: Mono1Params
  f32 gain
  f32 range
  f32 saw
  f32 pulse
  f32 pw
  f32 sub
  f32 noise
  f32 attack
  f32 decay
  f32 sustain
  f32 release
  f32 cutoff
  f32 resonance
  f32 drive
  f32 hpf
  f32 fenv
  f32 keytrack
  f32 lfo_rate
  f32 lfo_delay
  f32 lfo_pitch
  f32 lfo_pw
  f32 lfo_amp
  f32 lfo_cutoff
;

noalloc: p-gain  slab:params f@32 ;
noalloc: p-range slab:params 4 + f@32 ;
noalloc: p-saw   slab:params 8 + f@32 ;
noalloc: p-pulse slab:params 12 + f@32 ;
noalloc: p-pw    slab:params 16 + f@32 ;
noalloc: p-sub   slab:params 20 + f@32 ;
noalloc: p-noise slab:params 24 + f@32 ;
noalloc: p-attack  slab:params 28 + f@32 ;
noalloc: p-decay   slab:params 32 + f@32 ;
noalloc: p-sustain slab:params 36 + f@32 ;
noalloc: p-release slab:params 40 + f@32 ;
noalloc: p-cutoff  slab:params 44 + f@32 ;
noalloc: p-res     slab:params 48 + f@32 ;
noalloc: p-drive   slab:params 52 + f@32 ;
noalloc: p-hpf     slab:params 56 + f@32 ;
noalloc: p-fenv    slab:params 60 + f@32 ;
noalloc: p-key     slab:params 64 + f@32 ;
noalloc: p-lfo-rate  slab:params 68 + f@32 ;
noalloc: p-lfo-delay slab:params 72 + f@32 ;
noalloc: p-lfo-pitch slab:params 76 + f@32 ;
noalloc: p-lfo-pw    slab:params 80 + f@32 ;
noalloc: p-lfo-amp   slab:params 84 + f@32 ;
noalloc: p-lfo-cut   slab:params 88 + f@32 ;
: p-gain!  slab:params f!32 ;
: p-range! slab:params 4 + f!32 ;
: p-saw!   slab:params 8 + f!32 ;
: p-pulse! slab:params 12 + f!32 ;
: p-pw!    slab:params 16 + f!32 ;
: p-sub!   slab:params 20 + f!32 ;
: p-noise! slab:params 24 + f!32 ;
: p-attack!  slab:params 28 + f!32 ;
: p-decay!   slab:params 32 + f!32 ;
: p-sustain! slab:params 36 + f!32 ;
: p-release! slab:params 40 + f!32 ;
: p-cutoff!  slab:params 44 + f!32 ;
: p-res!     slab:params 48 + f!32 ;
: p-drive!   slab:params 52 + f!32 ;
: p-hpf!     slab:params 56 + f!32 ;
: p-fenv!    slab:params 60 + f!32 ;
: p-key!     slab:params 64 + f!32 ;
: p-lfo-rate!  slab:params 68 + f!32 ;
: p-lfo-delay! slab:params 72 + f!32 ;
: p-lfo-pitch! slab:params 76 + f!32 ;
: p-lfo-pw!    slab:params 80 + f!32 ;
: p-lfo-amp!   slab:params 84 + f!32 ;
: p-lfo-cut!   slab:params 88 + f!32 ;

noalloc: safe-sr
  slab:sr dup 1.0 f<
  [ drop SR_DEFAULT ] then
;

noalloc: midi-to-hz  ( pitch -- hz )
  69.0 f- 12.0 f/ 2.0 swap pow 440.0 f*
;

noalloc: range-mul
  p-range 0.5 f<
  [ 0.5 ]
  [
    p-range 1.5 f<
    [ 1.0 ]
    [ 2.0 ]
    ifte
  ]
  ifte
;

noalloc: calc-step
  pitch-cell f@32 midi-to-hz range-mul f* safe-sr f/
  dup 0.45 f> [ drop 0.45 ] then
;

noalloc: env-coeff  ( seconds -- coeff )
  dup 0.001 f< [ drop 0.001 ] then
  safe-sr f*
  1.0 swap f/ fneg exp
  1.0 swap f-
;

noalloc: do-attack  ( env -- env )
  1.0 attack-coeff-cell f@32 fslew
;

noalloc: do-decay  ( env -- env )
  sustain-level-cell f@32 decay-coeff-cell f@32 fslew
;

noalloc: do-release  ( env -- env )
  0.0 release-coeff-cell f@32 fslew
;

noalloc: amp-env-tick
  stage-cell @32 0 =
  [ 0.0 ]
  [
    amp-cell f@32
    stage-cell @32 1 =
    [
      do-attack
      dup 0.995 f> [ 2 stage-cell !32 ] then
    ] then
    stage-cell @32 2 =
    [
      do-decay
      dup sustain-level-cell f@32 f> not [ 3 stage-cell !32 ] then
    ] then
    stage-cell @32 3 =
    [
      sustain-level-cell f@32 swap drop
    ] then
    stage-cell @32 4 =
    [
      do-release
      dup 0.0005 f< [ drop 0.0 0 stage-cell !32 ] then
    ] then
    dup amp-cell f!32
  ]
  ifte
;

noalloc: clamp01
  fclamp01
;

noalloc: lfo-rate-hz
  p-lfo-rate clamp01
  66.6666667 swap pow
  0.3 f*
;

noalloc: lfo-delay-sec
  p-lfo-delay clamp01 2.0 f*
;

noalloc: lfo-delay-factor
  lfo-delay-sec-cell f@32 0.001 f<
  [ 1.0 ]
  [
    lfo-delay-cell f@32 lfo-delay-sec-cell f@32 f/
    dup 1.0 f> [ drop 1.0 ] then
  ]
  ifte
;

noalloc: lfo-triangle
  lfo-phase-cell f@32 0.25 f<
  [
    lfo-phase-cell f@32 4.0 f*
  ]
  [
    lfo-phase-cell f@32 0.75 f<
    [
      2.0 lfo-phase-cell f@32 4.0 f* f-
    ]
    [
      lfo-phase-cell f@32 4.0 f* 4.0 f-
    ]
    ifte
  ]
  ifte
;

noalloc: lfo-pitch-mul
  1.0 lfo-cell f@32 lfo-pitch-amt-cell f@32 fmadd
  0.5 2.0 fclamp
;

noalloc: lfo-amp-mul
  lfo-amp-amt-cell f@32 0.0001 f<
  [ 1.0 ]
  [
    1.0 lfo-amp-amt-cell f@32 f-
    lfo-cell f@32 1.0 f+ 0.5 f* lfo-amp-amt-cell f@32 f* f+
  ]
  ifte
;

noalloc: lfo-tick
  lfo-phase-cell f@32 lfo-inc-cell f@32 f+ fwrap01
  lfo-phase-cell f!32

  lfo-delay-cell f@32 lfo-delay-inc-cell f@32 f+
  dup 2.0 f> [ drop 2.0 ] then
  lfo-delay-cell f!32

  lfo-triangle lfo-delay-factor f*
  lfo-cell f!32

  base-step-cell f@32 lfo-pitch-mul f*
  0.0 0.45 fclamp
  step-cell f!32
  step-cell f@32 0.5 f* sub-step-cell f!32
;

( PolyBLEP correction for a discontinuity at phase 0.
  Input and output are normalized to one cycle. )
noalloc: polyblep  ( t dt -- correction )
  blep-dt-cell f!32
  blep-t-cell f!32
  blep-t-cell f@32 blep-dt-cell f@32 f<
  [
    blep-t-cell f@32 blep-dt-cell f@32 f/
    dup f+
    blep-t-cell f@32 blep-dt-cell f@32 f/
    dup f*
    f-
    1.0 f-
  ]
  [
    blep-t-cell f@32 1.0 blep-dt-cell f@32 f- f>
    [
      blep-t-cell f@32 1.0 f- blep-dt-cell f@32 f/
      dup dup f* swap dup f+ f+ 1.0 f+
    ]
    [ 0.0 ]
    ifte
  ]
  ifte
;

noalloc: saw-sample
  phase-cell f@32 2.0 -1.0 fma
  phase-cell f@32 step-cell f@32 polyblep
  f-
;

noalloc: saw-raw-sample
  phase-cell f@32 2.0 -1.0 fma
;

noalloc: clamped-pw
  pw-cell f@32
  lfo-cell f@32 lfo-pw-amt-cell f@32 fmadd
  0.08 0.92 fclamp
;

noalloc: pulse-edge-phase
  phase-cell f@32 clamped-pw f- fwrap01
;

noalloc: pulse-sample
  phase-cell f@32 clamped-pw f<
  [ 1.0 ] [ -1.0 ] ifte
  phase-cell f@32 step-cell f@32 polyblep
  f+
  pulse-edge-phase step-cell f@32 polyblep
  f-
  clamped-pw 2.0 -1.0 fma f-
;

noalloc: pulse-raw-sample
  phase-cell f@32 clamped-pw f<
  [ 1.0 ] [ -1.0 ] ifte
  clamped-pw 2.0 -1.0 fma f-
;

noalloc: square50-raw-sample
  phase-cell f@32 0.5 f<
  [ 1.0 ] [ -1.0 ] ifte
;

noalloc: sub-edge-phase
  sub-phase-cell f@32 0.5 f- fwrap01
;

noalloc: sub-sample
  sub-phase-cell f@32 0.5 f<
  [ 1.0 ] [ -1.0 ] ifte
  sub-phase-cell f@32 sub-step-cell f@32 polyblep
  f+
  sub-edge-phase sub-step-cell f@32 polyblep
  f-
;

noalloc: sub-raw-sample
  sub-phase-cell f@32 0.5 f<
  [ 1.0 ] [ -1.0 ] ifte
;

noalloc: mix-level-sum
  mix-sum-cell f@32
;

noalloc: limit1
  -1.0 1.0 fclamp
;

noalloc: softclip
  -2.0 2.0 fclamp
  dup dup f* 0.111111 f* 1.0 swap f- f*
;

noalloc: fenv-bipolar
  fenv-bipolar-cell f@32
;

noalloc: keytrack-norm
  pitch-cell f@32 60.0 f- 48.0 f/
  keytrack-cell f@32 f*
;

noalloc: cutoff-norm
  cutoff-cell f@32
  fenv-bipolar amp-cell f@32 fmadd
  keytrack-norm f+
  lfo-cell f@32 lfo-cut-amt-cell f@32 fmadd
  fclamp01
;

noalloc: cutoff-hz
  cutoff-norm
  500.0 swap pow
  40.0 f*
;

noalloc: hpf-hz
  p-hpf clamp01
  80.0 swap pow
  18.0 f*
;

noalloc: hpf-coeff
  1.0
  1.0 TWO_PI hpf-hz f* safe-sr f/ f+
  f/
;

noalloc: filter-coeff
  TWO_PI cutoff-hz f* safe-sr f/
  fneg exp
  1.0 swap f-
  0.001 0.72 fclamp
;

noalloc: res-gain
  res-gain-cell f@32
;

noalloc: drive-gain
  drive-gain-cell f@32
;

noalloc: hpf-sample  ( sample -- sample )
  dup
  hp-prev-in-cell f@32 f-
  hp-prev-out-cell f@32 f+
  hp-coeff-cell f@32 f*
  dup hp-prev-out-cell f!32
  swap hp-prev-in-cell f!32
  limit1
;

noalloc: lp1-tick
  f1-cell f@32 filt-in-cell f@32 filter-coeff-cell f@32 fslew
  dup f1-cell f!32
;

noalloc: lp2-tick
  f2-cell f@32 f1-cell f@32 filter-coeff-cell f@32 fslew
  dup f2-cell f!32
;

noalloc: lp3-tick
  f3-cell f@32 f2-cell f@32 filter-coeff-cell f@32 fslew
  dup f3-cell f!32
;

noalloc: lp4-tick
  f4-cell f@32 f3-cell f@32 filter-coeff-cell f@32 fslew
  dup f4-cell f!32
;

noalloc: vcf-sample  ( sample -- sample )
  f2-cell f@32 res-gain f* f-
  drive-gain f*
  softclip
  filt-in-cell f!32
  lp1-tick drop
  lp2-tick
  softclip
;

noalloc: mixed-sample
  0.0
  saw-level-cell f@32 0.0001 f>
  [ saw-raw-sample saw-level-cell f@32 fmadd ] then
  pulse-level-cell f@32 0.0001 f>
  [ pulse-raw-sample pulse-level-cell f@32 fmadd ] then
  sub-level-cell f@32 0.0001 f>
  [ sub-raw-sample sub-level-cell f@32 fmadd ] then
  noise-level-cell f@32 0.0001 f>
  [ slab:noise noise-level-cell f@32 fmadd ] then
  mix-level-sum f/
;

noalloc: mixed-sample-hq
  0.0
  saw-level-cell f@32 0.0001 f>
  [ saw-sample saw-level-cell f@32 fmadd ] then
  pulse-level-cell f@32 0.0001 f>
  [ pulse-sample pulse-level-cell f@32 fmadd ] then
  sub-level-cell f@32 0.0001 f>
  [ sub-sample sub-level-cell f@32 fmadd ] then
  noise-level-cell f@32 0.0001 f>
  [ slab:noise noise-level-cell f@32 fmadd ] then
  mix-level-sum f/
;

noalloc: advance-phase
  phase-cell f@32 step-cell f@32 f+ fwrap01
  phase-cell f!32
  sub-phase-cell f@32 sub-step-cell f@32 f+ fwrap01
  sub-phase-cell f!32
;

noalloc: note-on  ( event-index -- )
  dup slab:note-pitch pitch-cell f!32
  slab:note-vel vel-cell f!32
  calc-step base-step-cell f!32
  base-step-cell f@32 step-cell f!32
  base-step-cell f@32 0.5 f* sub-step-cell f!32
  0.0 lfo-delay-cell f!32
  1 stage-cell !32
;

noalloc: note-off  ( event-index -- )
  drop
  stage-cell @32 0 = not
  [ 4 stage-cell !32 ] then
;

noalloc: process-notes
  0 slab:note-count
  [
    dup slab:note-kind 0 =
    [ dup note-on ] then
    dup slab:note-kind 1 =
    [ dup note-off ] then
    1+
  ] dotimes
  drop
;

noalloc: amp-output  ( sample -- sample )
  amp-cell f@32 f*
  lfo-amp-mul f*
  vel-cell f@32 f*
  gain-cell f@32 f*
;

noalloc: update-block-coeffs
  p-gain gain-cell f!32
  p-saw clamp01 saw-level-cell f!32
  p-pulse clamp01 pulse-level-cell f!32
  p-pw clamp01 pw-cell f!32
  p-sub clamp01 sub-level-cell f!32
  p-noise clamp01 noise-level-cell f!32
  p-sustain clamp01 sustain-level-cell f!32
  p-cutoff clamp01 cutoff-cell f!32
  p-fenv clamp01 0.5 f- 2.0 f* fenv-bipolar-cell f!32
  p-key clamp01 keytrack-cell f!32
  p-res clamp01 1.25 f* res-gain-cell f!32
  p-drive clamp01 4.0 f* 1.0 f+ drive-gain-cell f!32
  p-lfo-delay clamp01 2.0 f* lfo-delay-sec-cell f!32
  1.0 safe-sr f/ lfo-delay-inc-cell f!32
  p-lfo-pitch clamp01 0.06 f* lfo-pitch-amt-cell f!32
  p-lfo-pw clamp01 0.4 f* lfo-pw-amt-cell f!32
  p-lfo-amp clamp01 lfo-amp-amt-cell f!32
  p-lfo-cut clamp01 0.5 f* lfo-cut-amt-cell f!32
  saw-level-cell f@32 pulse-level-cell f@32 f+
  sub-level-cell f@32 f+
  noise-level-cell f@32 f+
  dup 1.0 f< [ drop 1.0 ] then
  mix-sum-cell f!32
  p-attack env-coeff attack-coeff-cell f!32
  p-decay env-coeff decay-coeff-cell f!32
  p-release env-coeff release-coeff-cell f!32
  lfo-rate-hz safe-sr f/ lfo-inc-cell f!32
  hpf-coeff hp-coeff-cell f!32
  filter-coeff filter-coeff-cell f!32
;

noalloc: debug-sample
  slab:debug-mode 6 =
  [ square50-raw-sample ]
  [
  slab:debug-mode 5 =
  [ pulse-raw-sample ]
  [
  slab:debug-mode 4 =
  [ sub-sample ]
  [
  slab:debug-mode 3 =
  [ pulse-sample ]
  [
  slab:debug-mode 2 =
  [ saw-sample ]
  [
    mixed-sample
    slab:debug-mode 1 =
    [ ]
    [ hpf-sample vcf-sample ]
    ifte
  ]
  ifte
  ]
  ifte
  ]
  ifte
  ]
  ifte
  ]
  ifte
;

noalloc: mono1-audio
  process-notes
  update-block-coeffs
  0 slab:block-size
  [
    lfo-tick
    amp-env-tick drop
    debug-sample
    amp-output
    out-cell f!32
    out-cell f@32 over slab:write-stereo
    advance-phase
    1+
  ] dotimes
  drop
;

noalloc: mono1-audio-hq
  process-notes
  update-block-coeffs
  0 slab:block-size
  [
    lfo-tick
    amp-env-tick drop
    mixed-sample-hq
    hpf-sample
    vcf-sample
    amp-output
    out-cell f!32
    out-cell f@32 over slab:write-stereo
    advance-phase
    1+
  ] dotimes
  drop
;

noalloc: mono1-reset
  0.0 phase-cell f!32
  0.0 step-cell f!32
  0.0 sub-phase-cell f!32
  0.0 sub-step-cell f!32
  0.0 base-step-cell f!32
  60.0 pitch-cell f!32
  1.0 vel-cell f!32
  0.0 amp-cell f!32
  0 stage-cell !32
  0.0 lfo-phase-cell f!32
  0.0 lfo-delay-cell f!32
  0.0 lfo-cell f!32
  0.0 attack-coeff-cell f!32
  0.0 decay-coeff-cell f!32
  0.0 release-coeff-cell f!32
  0.0 lfo-inc-cell f!32
  0.0 hp-coeff-cell f!32
  0.0 filter-coeff-cell f!32
  0.5 gain-cell f!32
  0.0 saw-level-cell f!32
  0.0 pulse-level-cell f!32
  0.5 pw-cell f!32
  0.0 sub-level-cell f!32
  0.0 noise-level-cell f!32
  1.0 mix-sum-cell f!32
  0.7 sustain-level-cell f!32
  0.7 cutoff-cell f!32
  0.0 fenv-bipolar-cell f!32
  0.0 keytrack-cell f!32
  0.0 res-gain-cell f!32
  1.0 drive-gain-cell f!32
  0.0 lfo-delay-sec-cell f!32
  0.0 lfo-delay-inc-cell f!32
  0.0 lfo-pitch-amt-cell f!32
  0.0 lfo-pw-amt-cell f!32
  0.0 lfo-amp-amt-cell f!32
  0.0 lfo-cut-amt-cell f!32
  0.0 hp-prev-in-cell f!32
  0.0 hp-prev-out-cell f!32
  0.0 filt-in-cell f!32
  0.0 f1-cell f!32
  0.0 f2-cell f!32
  0.0 f3-cell f!32
  0.0 f4-cell f!32
  0.0 out-cell f!32
;

( --- Stage E UI ------------------------------------------------- )
:: CW 52.0 ;
:: CG 53.0 ;
:: DCOX 0.0 ;
:: DCOW 340.0 ;
:: VCFX 340.0 ;
:: VCFW 326.0 ;
:: LFOX 0.0 ;
:: LFOW 326.0 ;
:: ENVX 326.0 ;
:: ENVW 220.0 ;
:: AMPX 546.0 ;
:: AMPW 120.0 ;

: top-y slab:panel-y 12.0 f+ ;
: bot-y slab:panel-y 86.0 f+ ;
: row1-y slab:panel-y 24.0 f+ ;
: row2-y slab:panel-y 98.0 f+ ;
: kh 52.0 ;
: dco-x slab:panel-x DCOX f+ ;
: dco-label-x dco-x 4.0 f+ ;
: rng-x dco-x 4.0 f+ ;
: pwx dco-x 64.0 f+ ;
: sawx dco-x 118.0 f+ ;
: pulx dco-x 172.0 f+ ;
: subx dco-x 226.0 f+ ;
: nox dco-x 280.0 f+ ;

: vcf-x slab:panel-x VCFX f+ ;
: vcf-label-x vcf-x 4.0 f+ ;
: vc0 vcf-x 8.0 f+ ;
: vc1 vcf-x 61.0 f+ ;
: vc2 vcf-x 114.0 f+ ;
: vc3 vcf-x 167.0 f+ ;
: vc4 vcf-x 220.0 f+ ;
: vc5 vcf-x 273.0 f+ ;

: lfo-x slab:panel-x LFOX f+ ;
: lfo-label-x lfo-x 4.0 f+ ;
: lx0 lfo-x 8.0 f+ ;
: lx1 lfo-x 61.0 f+ ;
: lx2 lfo-x 114.0 f+ ;
: lx3 lfo-x 167.0 f+ ;
: lx4 lfo-x 220.0 f+ ;
: lx5 lfo-x 273.0 f+ ;

: env-x slab:panel-x ENVX f+ ;
: env-label-x env-x 4.0 f+ ;
: ex0 env-x 8.0 f+ ;
: ex1 env-x 61.0 f+ ;
: ex2 env-x 114.0 f+ ;
: ex3 env-x 167.0 f+ ;

: amp-x slab:panel-x AMPX f+ ;
: amp-label-x amp-x 4.0 f+ ;
: gx amp-x 34.0 f+ ;

: mono1-ui
  slab:panel-x slab:panel-y slab:panel-w 12.0 widget:bevel-raised
  slab:panel-x 4.0 f+ slab:panel-y _lbl_m1 widget:draw-label

  dco-x top-y DCOW 74.0 widget:bevel-raised
  dco-label-x slab:panel-y 14.0 f+ _lbl_dco widget:draw-label
  rng-x slab:panel-y 32.0 f+ 54.0 48.0 _lbl_rng _lbl_16 _lbl_8 _lbl_4 p-range widget:switch3v p-range!
  pwx row1-y CW kh _lbl_pw p-pw widget:knob p-pw!
  sawx row1-y CW kh _lbl_saw p-saw widget:knob p-saw!
  pulx row1-y CW kh _lbl_pul p-pulse widget:knob p-pulse!
  subx row1-y CW kh _lbl_sub p-sub widget:knob p-sub!
  nox row1-y CW kh _lbl_noi p-noise widget:knob p-noise!

  vcf-x top-y VCFW 74.0 widget:bevel-raised
  vcf-label-x slab:panel-y 14.0 f+ _lbl_vcf widget:draw-label
  vc0 row1-y CW kh _lbl_hpf p-hpf widget:knob p-hpf!
  vc1 row1-y CW kh _lbl_cut p-cutoff widget:knob p-cutoff!
  vc2 row1-y CW kh _lbl_res p-res widget:knob p-res!
  vc3 row1-y CW kh _lbl_drv p-drive widget:knob p-drive!
  vc4 row1-y CW kh _lbl_env p-fenv widget:knob p-fenv!
  vc5 row1-y CW kh _lbl_key p-key widget:knob p-key!

  lfo-x bot-y LFOW 74.0 widget:bevel-raised
  lfo-label-x slab:panel-y 88.0 f+ _lbl_lfo widget:draw-label
  lx0 row2-y CW kh _lbl_rat p-lfo-rate widget:knob p-lfo-rate!
  lx1 row2-y CW kh _lbl_dly p-lfo-delay widget:knob p-lfo-delay!
  lx2 row2-y CW kh _lbl_pit p-lfo-pitch widget:knob p-lfo-pitch!
  lx3 row2-y CW kh _lbl_pw p-lfo-pw widget:knob p-lfo-pw!
  lx4 row2-y CW kh _lbl_amp p-lfo-amp widget:knob p-lfo-amp!
  lx5 row2-y CW kh _lbl_cut p-lfo-cut widget:knob p-lfo-cut!

  env-x bot-y ENVW 74.0 widget:bevel-raised
  env-label-x slab:panel-y 88.0 f+ _lbl_env widget:draw-label
  ex0 row2-y CW kh _lbl_att p-attack widget:knob p-attack!
  ex1 row2-y CW kh _lbl_dec p-decay widget:knob p-decay!
  ex2 row2-y CW kh _lbl_sus p-sustain widget:knob p-sustain!
  ex3 row2-y CW kh _lbl_rel p-release widget:knob p-release!

  amp-x bot-y AMPW 74.0 widget:bevel-raised
  amp-label-x slab:panel-y 88.0 f+ _lbl_amp widget:draw-label
  gx row2-y CW kh _lbl_gn p-gain widget:knob p-gain!
;

: manifest
  \mono1-audio \mono1-ui
  Mono1State.size Mono1Params.size
  notes->audio
  Machine.new
;
