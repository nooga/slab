( svf2.fy - lean Chamberlin state-variable filter for the drum voices:
  band-pass for clap / hat color, high-pass for snare snap. Two f64 state
  cells; a voice embeds them as adjacent fields and passes their base
  pointer. f = 2 * sin of pi*fc/sr - computed at block rate by svf2-coeff
  via the polynomial sine; q is the damping, roughly 1/Q. Stable for
  fc well under sr/6, which svf2-coeff's clamp guarantees. )

include "sine.fy"

ustruct: Svf2State
  f64 lp
  f64 bp
;

( fc sr -- f : filter coefficient at block rate. )
dsp: svf2-coeff
  | fc sr |
  fc 20.0 7500.0 fclamp  2.0 sr f*  f/
  sine-shape
  2.0 f*
;

( state in f q -- band : one band-pass step, state advanced in place. )
dsp: svf2-bp-step
  | state:Svf2State in f q |
  state.lp  f state.bp f*  f+
  | lp |
  in lp f-  q state.bp f*  f-
  | hp |
  state.bp  f hp f*  f+
  | bp |
  lp -> state.lp
  bp -> state.bp
  bp
;

( state in f q -- high : one high-pass step, state advanced in place. )
dsp: svf2-hp-step
  | state:Svf2State in f q |
  state.lp  f state.bp f*  f+
  | lp |
  in lp f-  q state.bp f*  f-
  | hp |
  state.bp  f hp f*  f+
  -> state.bp
  lp -> state.lp
  hp
;
