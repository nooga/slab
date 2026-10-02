( wavetable.fy - reading a host-built wavetable [src/wavetable.zig].

  A table is frames of WT-STRIDE f64 cells.  Each frame holds 11 octave
  mip levels, mip m keeping harmonics up to 1024 >> m, stored in
  min[2048, 16384 >> m] cells plus one guard cell.  wt-read crossfades two
  frames [the position] and two mip levels [the pitch], four linear
  reads in all, so position sweeps morph and pitch sweeps don't step.

  The mip choice: harmonic h of a note at f lands at h f, and folds back
  to sr - h f past Nyquist; anything folding above ~19 kHz is inaudible,
  so a level may hold harmonics up to [sr - 19000] / f.  `mipx` is the
  phase increment times WT-MIP-K = 1024 sr / [sr - 19000], computed per
  block [wt-mip-k]; log2 of it is the level that just fits.  Both read
  levels sit at or below that limit: no audible aliasing at any pitch. )

include "../00-primitives/table.fy"

:: WT-STRIDE 10235.0 ;

( m -- off len : where mip level m starts in a frame, and its cells. )
dsp: wt-mip | m -- off len |
  m fneg fexp2i | s |
  m 3.0 f<  2049.0 m f*  10240.0 32768.0 s f* f- m f+  select
  2048.0  16384.0 s f*  fmin
;

( sr -- k : the per-block constant that turns an increment into mipx. )
dsp: wt-mip-k | sr -- k |
  1024.0 sr f*  sr 19000.0 f-  sr 0.5 f* fmax  f/
;

( tbl fbase fcount pos ph mipx -- y : one sample of the table at
  position pos [0..1 over frames fbase .. fbase + fcount - 1] and phase
  ph [0..1[. )
dsp: wt-read | tbl fbase fcount pos ph mipx -- y |
  pos 0.0 1.0 fclamp  fcount 1.0 f- 0.0 fmax f* | fp |
  fp floor | f0 |
  fp f0 f- | ff |
  f0 1.0 f+  fcount 1.0 f- 0.0 fmax  fmin | f1 |
  mipx 0.5 511.0 fclamp | x |
  x flog2i  x fmant 1.0 f-  f+ | mf |
  mf floor | mfl |
  mf mfl f- | w |
  mfl 1.0 f+ | m0 |
  m0 wt-mip | o0 l0 |
  m0 1.0 f+ wt-mip | o1 l1 |
  fbase f0 f+ WT-STRIDE f* | b0 |
  fbase f1 f+ WT-STRIDE f* | b1 |
  ph l0 f* | i0 |
  ph l1 f* | i1 |
  tbl  b0 o0 f+ i0 f+  tbl-lerp | a00 |
  tbl  b1 o0 f+ i0 f+  tbl-lerp | a10 |
  tbl  b0 o1 f+ i1 f+  tbl-lerp | a01 |
  tbl  b1 o1 f+ i1 f+  tbl-lerp | a11 |
  a10 a00 f- ff f* a00 f+ | v0 |
  a11 a01 f- ff f* a01 f+ | v1 |
  v1 v0 f- w f* v0 f+
;
