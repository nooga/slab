( compand.fy - a noise reducer out of alignment: the encode/decode pair
  of Dolby B or a VHS Hi-Fi compander, reduced to what is left when they
  don't match.  The band above SPLIT is followed; quiet passages in it
  get the decoder's error, AMT dB for every dB they sit under REF.

    hi    = x - LP[x]                     one-pole split
    env   = follower of max |hi|          2 ms up, 80 ms down
    gain  = AMT * clamp[REF - env_dB, 0, 30] dB on hi

  AMT < 0 is a deck playing back low: quiet highs go dull, and the
  hiss under them pumps as the music comes and goes - the "breathing"
  of a mistracking Dolby B [split ~1.5 kHz] or of a Hi-Fi compander
  [split near DC: the whole band breathes].  AMT > 0 is the bright,
  spitty mistrack.  At AMT 0 it is a pass; the owner skips it [ifte]. )

include "../00-primitives/math.fy"
include "../04-filters/tone.fy"   ( Pole, pole-G, pole-lp )

ustruct: CompandState
  Pole sl      ( the split's low-pass, per channel )
  Pole sr
  f64 env
;

ustruct: CompandParams
  ( set by the owner )
  f64 split    ( Hz )
  f64 amt      ( dB of error per dB under ref )
  f64 ref-db
  ( derived - compand-prepare )
  f64 G
  f64 atk
  f64 rel
  f64 ref-l2
  f64 amt-l2   ( amt scaled for log2 in, log2 out )
;

( sr cp -- )
dsp: compand-prepare | sr cp:CompandParams |
  cp.split 20.0 0.45 sr f* fclamp sr pole-G -> cp.G
  -1.0 0.002 sr f* f/ exp -> cp.atk
  -1.0 0.08 sr f* f/ exp -> cp.rel
  cp.ref-db 0.16609640474436813 f* -> cp.ref-l2
  cp.amt -> cp.amt-l2
;

( cs cp xl xr -- yl yr )
dsp: compand-tick | cs:CompandState cp:CompandParams xl xr -- yl yr |
  cs.sl& cp.G xl pole-lp | ll |
  cs.sr& cp.G xr pole-lp | lr |
  xl ll f- | hl |
  xr lr f- | hr |
  hl fabs hr fabs fmax | x |
  cs.env | e0 |
  x e0 cp.atk cp.rel fsel-lt | c |
  x  e0 x f-  c f*  f+ | e |
  e 1.0e-30 f+ 1.0e-30 f- -> cs.env
  ( dB and log2 differ by the same factor in and out, so the slope
    carries over unchanged )
  cp.ref-l2  e 1.0e-6 fmax log2  f-  0.0 4.98 fclamp  cp.amt-l2 f* exp2 | g |
  ll hl g f* f+
  lr hr g f* f+
;
