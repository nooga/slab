( drum2.fy — synthesized drum machine, docs/16. Kick, snare, and clap
  slots; hats and tom land next.

  DSP lives in the kernels rig [kernels/05-drums]. State and params are
  the voice structs laid out back to back - [KickState|SnareState|
  ClapState] - and the stage wrappers below compute each slot's region
  base with introspected sizes, never hand-written offsets. The render
  word is a call: composition, one fresh register budget per stage,
  every stage accumulating into the host-zeroed out cell.

  note-pitch mode: note-on receives raw MIDI pitch and gates each slot's
  branchless trigger by PITCH CLASS, so the kit answers in every octave:
  C = kick, D = snare, D# = clap. The note map advertises the canonical
  GM octave - 36 / 38 / 39. )

include "../../kernels/05-drums/kick.fy"
include "../../kernels/05-drums/snare.fy"
include "../../kernels/05-drums/clap.fy"
include "../lib/manifest.fy"

( state params sample-rate -- : fill every slot's derived coefficients. )
dsp2: drum2-prepare
  | state params sr |
  state params sr kick-prepare
  state KickState.size ptr+
  params KickParams.size ptr+
  sr snare-prepare
  state KickState.size ptr+ SnareState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+
  sr clap-prepare
  drop2 drop
;

( state params pitch velocity -- : gate each slot's trigger by the
  note's pitch class - C kick, D snare, D# clap, any octave. )
dsp2: drum2-note-on
  | state params pitch velocity |
  pitch 12.0 f/ ffrac 12.0 f*
  | pc |
  state params
  pc 0.5 1.0 0.0 fsel-lt
  velocity kick-trigger
  state KickState.size ptr+
  params KickParams.size ptr+
  pc 2.5  1.5 pc 1.0 0.0 fsel-lt  0.0  fsel-lt
  velocity snare-trigger
  state KickState.size ptr+ SnareState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+
  pc 3.5  2.5 pc 1.0 0.0 fsel-lt  0.0  fsel-lt
  velocity clap-trigger
  drop2 drop2 drop
;

( --- render stages: region base + voice helper, accumulate into out.
  Kick sits at region 0 so its stages are used directly. --- )

dsp2: d2-snare-shell
  | state params |
  state KickState.size ptr+  params KickParams.size ptr+  snare-shell-write
  drop2
;

dsp2: d2-snare-snap
  | state params |
  state KickState.size ptr+  params KickParams.size ptr+  snare-snap-write
  drop2
;

dsp2: d2-snare-accum
  | out state params |
  out  state KickState.size ptr+  params KickParams.size ptr+  snare-accum
  drop2 drop
;

dsp2: d2-clap-env
  | state params |
  state KickState.size ptr+ SnareState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+
  clap-env-write
  drop2
;

dsp2: d2-clap-accum
  | out state params |
  out
  state KickState.size ptr+ SnareState.size ptr+
  params KickParams.size ptr+ SnareParams.size ptr+
  clap-accum
  drop2 drop
;

( out state params -- : one summed mono drum sample. )
dsp2: k-drum2-render
  | out state params |
  state params call: kick-osc-write
  out state params call: kick-accum
  state params call: d2-snare-shell
  state params call: d2-snare-snap
  out state params call: d2-snare-accum
  state params call: d2-clap-env
  out state params call: d2-clap-accum
;

: manifest
  "drum2" voice-sample machine*
  "k-drum2-render" render!
  "drum2-prepare"  prepare!
  "drum2-note-on"  note-on!
  KickState.size SnareState.size + ClapState.size +  state-size!
  KickParams.size SnareParams.size + ClapParams.size +  params-size!
  312.0 panel-w!
  note-pitch
  36 "KICK" note-label
  38 "SNARE" note-label
  39 "CLAP" note-label

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

  "KICK" 1 strip
  "SNARE" 1 strip
  "CLAP" 1 strip
  machine-desc
;
