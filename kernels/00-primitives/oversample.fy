( oversample.fy - 2x and 4x polyphase IIR halfband resampling.

  Each halfband is two parallel chains of first-order allpass sections,
  [c + z^-1] / [1 + c z^-1] at the lower rate - one multiply per section.
  Coefficients from tools/fit/halfband.py:

  hb9   2x <-> 1x   9 sections  flat to 0.003 dB up to 0.23 fs2, -112 dB
                                 from 0.27 fs2: 22 kHz clean at 48 kHz
  hb4   4x <-> 2x   4 sections  -113 dB from 0.37 fs4; only has to keep
                                 what would fold below 24 kHz

  A voice that runs its core at 4x renders four samples x0..x3 [oldest
  first] and hands them to dec4; an effect runs up4 on its input first.
  Per output sample: dec4 = 17 sections, up4 = 17 sections.  The group
  delay is a few samples at the base rate, and the phase is nonlinear
  near Nyquist, as with any IIR halfband. )

ustruct: HbAp f64 x f64 y ;          ( one section: last input, last output )
ustruct: Hb9 f64 m 18 ;              ( 9 sections )
ustruct: Hb4 f64 m 8 ;               ( 4 sections )
ustruct: Dec2 Hb9 h ;
ustruct: Up2 Hb9 h ;
ustruct: Dec4 Hb4 a Hb9 b ;          ( 4x -> 2x -> 1x )
ustruct: Up4 Hb9 a Hb4 b ;           ( 1x -> 2x -> 4x )

( p x c -- y : one allpass section. )
dsp: hb-ap | p:HbAp x c -- y |
  x p.y f- c f* p.x f+ | o |
  x -> p.x
  o -> p.y
  o
;

( m x0 x1 -- y : one output from a pair at the higher rate, x0 older. )
dsp: hb9-dec | m x0 x1 -- y |
  x1 | a |
  m 0 ptr+ a 0.03270139024814258 hb-ap | a |
  m 16 ptr+ a 0.25092452931490206 hb-ap | a |
  m 32 ptr+ a 0.5334382037734813 hb-ap | a |
  m 48 ptr+ a 0.769175179754028 hb-ap | a |
  m 64 ptr+ a 0.9549727484449697 hb-ap | a |
  x0 | b |
  m 80 ptr+ b 0.12292192727433598 hb-ap | b |
  m 96 ptr+ b 0.39384824646144356 hb-ap | b |
  m 112 ptr+ b 0.659440556757765 hb-ap | b |
  m 128 ptr+ b 0.865498072577736 hb-ap | b |
  a b f+ 0.5 f*
;

( m x -- y0 y1 : a pair at the higher rate from one sample, y0 older. )
dsp: hb9-up | m x -- y0 y1 |
  x | a |
  m 0 ptr+ a 0.03270139024814258 hb-ap | a |
  m 16 ptr+ a 0.25092452931490206 hb-ap | a |
  m 32 ptr+ a 0.5334382037734813 hb-ap | a |
  m 48 ptr+ a 0.769175179754028 hb-ap | a |
  m 64 ptr+ a 0.9549727484449697 hb-ap | a |
  x | b |
  m 80 ptr+ b 0.12292192727433598 hb-ap | b |
  m 96 ptr+ b 0.39384824646144356 hb-ap | b |
  m 112 ptr+ b 0.659440556757765 hb-ap | b |
  m 128 ptr+ b 0.865498072577736 hb-ap | b |
  a b
;

( m x0 x1 -- y : one output from a pair at the higher rate, x0 older. )
dsp: hb4-dec | m x0 x1 -- y |
  x1 | a |
  m 0 ptr+ a 0.04364692960875863 hb-ap | a |
  m 16 ptr+ a 0.3991256466910782 hb-ap | a |
  x0 | b |
  m 32 ptr+ b 0.17462808091546225 hb-ap | b |
  m 48 ptr+ b 0.749510679417447 hb-ap | b |
  a b f+ 0.5 f*
;

( m x -- y0 y1 : a pair at the higher rate from one sample, y0 older. )
dsp: hb4-up | m x -- y0 y1 |
  x | a |
  m 0 ptr+ a 0.04364692960875863 hb-ap | a |
  m 16 ptr+ a 0.3991256466910782 hb-ap | a |
  x | b |
  m 32 ptr+ b 0.17462808091546225 hb-ap | b |
  m 48 ptr+ b 0.749510679417447 hb-ap | b |
  a b
;

( s x0 x1 -- y : 2x decimator, x0 older. )
dsp: dec2 | s:Dec2 x0 x1 -- y |  s.h& x0 x1 hb9-dec ;

( s x -- y0 y1 : 2x interpolator. )
dsp: up2 | s:Up2 x -- y0 y1 |  s.h& x hb9-up ;

( s x0 x1 x2 x3 -- y : 4x decimator, x0 oldest. )
dsp: dec4 | s:Dec4 x0 x1 x2 x3 -- y |
  s.b&  s.a& x0 x1 hb4-dec  s.a& x2 x3 hb4-dec  hb9-dec
;

( s x -- y0 y1 y2 y3 : 4x interpolator, y0 oldest. )
dsp: up4 | s:Up4 x -- y0 y1 y2 y3 |
  s.a& x hb9-up | u0 u1 |
  s.b& u0 hb4-up  s.b& u1 hb4-up
;
