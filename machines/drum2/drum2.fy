( drum2.fy — synthesized drum machine, docs/16. Kick, snare, clap,
  hats [CH/OH with choke], and tom.

  DSP lives in the kernels rig [kernels/05-drums]. State and params are
  the voice structs laid out back to back - [Kick|Snare|Clap|Hat|Tom] -
  where TOM reuses the kick voice on its own region. The stage wrappers
  below compute each slot's region base with introspected sizes, never
  hand-written offsets. The render word is a call: composition, one
  fresh register budget per stage, every stage accumulating into the
  host-zeroed out cell.

  note-pitch mode: note-on receives raw MIDI pitch and gates each slot's
  branchless trigger by PITCH CLASS, so the kit answers in every octave:
  C = kick, D = snare, D# = clap, F# = closed hat, A = tom, A# = open
  hat. The note map advertises the canonical GM octave. )

include "../../kernels/00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../../kernels/05-drums/kick.fy"
include "../../kernels/05-drums/snare.fy"
include "../../kernels/05-drums/clap.fy"
include "../../kernels/05-drums/hat.fy"
include "../lib/manifest.fy"

( master section - no per-sample state, just three params at the tail
  of the params block: accent shapes velocity at note-on, drive/level
  shape the summed kit in the final render stage. )
ustruct: Drum2Master
  f64 accent        ( 0 = every hit full force, 1 = full velocity range )
  f64 drive         ( summed-kit gain into the rational-tanh glue )
  f64 level
;

( ctx state params -- : fill every slot's derived coefficients. )
dsp: drum2-prepare
  | ctx state params |
  ctx Ctx.sr@ | sr |
  state params sr kick-prepare
  state KickState.size ptr+
  params KickParams.size ptr+
  sr snare-prepare
  state KickState.size ptr+ SnareState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+
  sr clap-prepare
  state KickState.size ptr+ SnareState.size ptr+ ClapState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+ ClapParams.size ptr+
  sr hat-prepare
  state KickState.size ptr+ SnareState.size ptr+ ClapState.size ptr+ HatState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+ ClapParams.size ptr+ HatParams.size ptr+
  sr kick-prepare
  drop2 drop drop
;

( ctx state params -- : gate each slot's trigger by the
  note's pitch class - C kick, D snare, D# clap, F# CH, A tom, A# OH. )
dsp: drum2-note-on
  | ctx state params |
  ctx Ctx.hz@ ctx Ctx.vel@ | pitch velocity |
  pitch 12.0 f/ ffrac 12.0 f*
  | pc |
  ( accent: blend the incoming velocity toward full force )
  params KickParams.size ptr+ SnareParams.size ptr+ ClapParams.size ptr+ HatParams.size ptr+ KickParams.size ptr+
  Drum2Master.accent@
  | acc |
  1.0 acc f-  acc velocity f*  f+  0.0 1.0 fclamp
  | vel |
  state params
  pc 0.5 1.0 0.0 fsel-lt
  vel kick-trigger
  state KickState.size ptr+
  params KickParams.size ptr+
  pc 2.5  1.5 pc 1.0 0.0 fsel-lt  0.0  fsel-lt
  vel snare-trigger
  state KickState.size ptr+ SnareState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+
  pc 3.5  2.5 pc 1.0 0.0 fsel-lt  0.0  fsel-lt
  vel clap-trigger
  state KickState.size ptr+ SnareState.size ptr+ ClapState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+ ClapParams.size ptr+
  pc 6.5  5.5 pc 1.0 0.0 fsel-lt  0.0  fsel-lt
  vel hat-ch-trigger
  state KickState.size ptr+ SnareState.size ptr+ ClapState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+ ClapParams.size ptr+
  pc 10.5  9.5 pc 1.0 0.0 fsel-lt  0.0  fsel-lt
  vel hat-oh-trigger
  state KickState.size ptr+ SnareState.size ptr+ ClapState.size ptr+ HatState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+ ClapParams.size ptr+ HatParams.size ptr+
  pc 9.5  8.5 pc 1.0 0.0 fsel-lt  0.0  fsel-lt
  vel kick-trigger
  drop2 drop2 drop2 drop drop
;

( --- render stages: region base + voice helper, accumulate into out.
  Kick sits at region 0 so its stages are used directly. --- )

dsp: d2-snare-shell
  | state params |
  state KickState.size ptr+  params KickParams.size ptr+  snare-shell-write
  drop2
;

dsp: d2-snare-snap
  | state params |
  state KickState.size ptr+  params KickParams.size ptr+  snare-snap-write
  drop2
;

dsp: d2-snare-accum
  | out state params |
  out  state KickState.size ptr+  params KickParams.size ptr+  snare-accum
  drop2 drop
;

dsp: d2-clap-env
  | state params |
  state KickState.size ptr+ SnareState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+
  clap-env-write
  drop2
;

dsp: d2-clap-accum
  | out state params |
  out
  state KickState.size ptr+ SnareState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+
  clap-accum
  drop2 drop
;

dsp: d2-hat-metal
  | state params |
  state KickState.size ptr+ SnareState.size ptr+ ClapState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+ ClapParams.size ptr+
  hat-metal-write
  drop2
;

dsp: d2-hat-filter
  | state params |
  state KickState.size ptr+ SnareState.size ptr+ ClapState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+ ClapParams.size ptr+
  hat-filter-write
  drop2
;

dsp: d2-hat-accum
  | out state params |
  out
  state KickState.size ptr+ SnareState.size ptr+ ClapState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+ ClapParams.size ptr+
  hat-accum
  drop2 drop
;

dsp: d2-tom-osc
  | state params |
  state KickState.size ptr+ SnareState.size ptr+ ClapState.size ptr+ HatState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+ ClapParams.size ptr+ HatParams.size ptr+
  kick-osc-write
  drop2
;

dsp: d2-tom-accum
  | out state params |
  out
  state KickState.size ptr+ SnareState.size ptr+ ClapState.size ptr+ HatState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+ ClapParams.size ptr+ HatParams.size ptr+
  kick-accum
  drop2 drop
;

( out state params -- : drive the summed kit and scale - overwrites out. )
dsp: d2-master
  | out state params |
  params KickParams.size ptr+ SnareParams.size ptr+ ClapParams.size ptr+ HatParams.size ptr+ KickParams.size ptr+
  | master |
  out f@64
  master Drum2Master.drive@ f*
  k-tanh-rational-shape-dsp2
  master Drum2Master.level@ f*
  out f!64
  drop2 drop2
;

( io ctx state params -- : one summed mono drum sample. )
dsp: k-drum2-render
  | io ctx state params |
  state params call: kick-osc-write
  io state params call: kick-accum
  state params call: d2-snare-shell
  state params call: d2-snare-snap
  io state params call: d2-snare-accum
  state params call: d2-clap-env
  io state params call: d2-clap-accum
  state params call: d2-hat-metal
  state params call: d2-hat-filter
  io state params call: d2-hat-accum
  state params call: d2-tom-osc
  io state params call: d2-tom-accum
  io state params call: d2-master
;

: manifest
  "DS-404 Drums" voice-sample machine*
  "k-drum2-render" render!
  "drum2-prepare"  prepare!
  "drum2-note-on"  note-on!
  KickState.size SnareState.size + ClapState.size + HatState.size + KickState.size +  state-size!
  KickParams.size SnareParams.size + ClapParams.size + HatParams.size + KickParams.size + Drum2Master.size +  params-size!
  520.0 panel-w!
  note-pitch
  36 "KICK" note-label
  38 "SNARE" note-label
  39 "CLAP" note-label
  42 "CH" note-label
  45 "TOM" note-label
  46 "OH" note-label

  ( module label id offset min max default curve — frequencies and times
    are log [curve-exp], levels and sends squared audio taper [curve-pow] )
  "KICK" "TUNE"  "kick-tune"   KickParams.tune-hz      20.0 200.0 50.0 curve-exp knob
  "KICK" "SWEEP" "kick-sweep"  KickParams.sweep-amount 0.0 16.0 7.0 curve-pow knob
  "KICK" "BEND"  "kick-bend"   KickParams.sweep-time   0.005 0.4 0.055 curve-exp knob
  "KICK" "DEC"   "kick-decay"  KickParams.decay-s      0.05 2.5 0.42 curve-exp knob
  "KICK" "CLICK" "kick-click"  KickParams.click-level  0.0 1.0 0.35 curve-pow knob
  "KICK" "DRIVE" "kick-drive"  KickParams.drive        0.5 6.0 1.8 curve-exp knob
  "KICK" "LVL"   "kick-level"  KickParams.level        0.0 1.0 0.9 curve-pow knob

  "SNARE" "TUNE" "snare-tune"  KickParams.size SnareParams.tune-hz +    110.0 440.0 185.0 curve-exp knob
  "SNARE" "DEC"  "snare-decay" KickParams.size SnareParams.body-decay + 0.05 0.8 0.18 curve-exp knob
  "SNARE" "SNAP" "snare-snap"  KickParams.size SnareParams.snap-level + 0.0 1.0 0.8 curve-pow knob
  "SNARE" "SDEC" "snare-sdec"  KickParams.size SnareParams.snap-decay + 0.03 0.6 0.10 curve-exp knob
  "SNARE" "TONE" "snare-tone"  KickParams.size SnareParams.snap-hz +    400.0 6000.0 1800.0 curve-exp knob
  "SNARE" "LVL"  "snare-level" KickParams.size SnareParams.level +      0.0 1.0 0.9 curve-pow knob

  "CLAP" "TONE" "clap-tone"   KickParams.size SnareParams.size + ClapParams.tone-hz +  400.0 3000.0 1100.0 curve-exp knob
  "CLAP" "SPRD" "clap-spread" KickParams.size SnareParams.size + ClapParams.spread-s + 0.004 0.04 0.011 curve-exp knob
  "CLAP" "DEC"  "clap-decay"  KickParams.size SnareParams.size + ClapParams.decay-s +  0.05 1.5 0.28 curve-exp knob
  "CLAP" "LVL"  "clap-level"  KickParams.size SnareParams.size + ClapParams.level +    0.0 1.0 0.9 curve-pow knob

  "HAT" "TUNE"  "hat-tune"   KickParams.size SnareParams.size + ClapParams.size + HatParams.tune +     0.6 1.8 1.0 curve-exp knob
  "HAT" "TONE"  "hat-tone"   KickParams.size SnareParams.size + ClapParams.size + HatParams.tone +     0.6 1.6 1.0 curve-exp knob
  "HAT" "CHDEC" "hat-chdec"  KickParams.size SnareParams.size + ClapParams.size + HatParams.ch-decay + 0.02 0.4 0.07 curve-exp knob
  "HAT" "OHDEC" "hat-ohdec"  KickParams.size SnareParams.size + ClapParams.size + HatParams.oh-decay + 0.1 2.0 0.6 curve-exp knob
  "HAT" "LVL"   "hat-level"  KickParams.size SnareParams.size + ClapParams.size + HatParams.level +    0.0 1.5 0.85 curve-pow knob

  "TOM" "TUNE"  "tom-tune"   KickParams.size SnareParams.size + ClapParams.size + HatParams.size + KickParams.tune-hz +      60.0 360.0 110.0 curve-exp knob
  "TOM" "SWEEP" "tom-sweep"  KickParams.size SnareParams.size + ClapParams.size + HatParams.size + KickParams.sweep-amount + 0.0 6.0 1.2 curve-pow knob
  "TOM" "DEC"   "tom-decay"  KickParams.size SnareParams.size + ClapParams.size + HatParams.size + KickParams.decay-s +      0.05 1.5 0.3 curve-exp knob
  "TOM" "DRIVE" "tom-drive"  KickParams.size SnareParams.size + ClapParams.size + HatParams.size + KickParams.drive +        0.5 6.0 1.3 curve-exp knob
  "TOM" "LVL"   "tom-level"  KickParams.size SnareParams.size + ClapParams.size + HatParams.size + KickParams.level +        0.0 1.0 0.85 curve-pow knob

  ( tom: fixed kick-voice params the strip does not expose )
  KickParams.size SnareParams.size + ClapParams.size + HatParams.size + KickParams.sweep-time +  0.09 const-f64
  KickParams.size SnareParams.size + ClapParams.size + HatParams.size + KickParams.click-level + 0.05 const-f64

  "MASTER" "ACC" "master-accent" KickParams.size SnareParams.size + ClapParams.size + HatParams.size + KickParams.size + Drum2Master.accent + 0.0 1.0 0.7 curve-lin knob
  "MASTER" "DRIVE" "master-drive" KickParams.size SnareParams.size + ClapParams.size + HatParams.size + KickParams.size + Drum2Master.drive +  0.5 5.0 1.0 curve-exp knob
  "MASTER" "LVL" "master-level"   KickParams.size SnareParams.size + ClapParams.size + HatParams.size + KickParams.size + Drum2Master.level +  0.0 1.0 0.9 curve-pow knob

  "KICK" 1 strip
  "SNARE" 1 strip
  "CLAP" 1 strip
  "HAT" 1 strip
  "TOM" 1 strip
  "MASTER" 3 strip

  ( five voice strips over a short horizontal master row )
  5.0 row
    1.0 cell  "KICK" 1.0 item
    1.0 cell  "SNARE" 1.0 item
    1.0 cell  "CLAP" 1.0 item
    1.0 cell  "HAT" 1.0 item
    1.0 cell  "TOM" 1.0 item
  1.0 row
    1.0 cell  "MASTER" 1.0 item
  machine-desc
;
