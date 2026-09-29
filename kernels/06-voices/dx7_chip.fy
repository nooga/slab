( dx7_chip.fy - the arithmetic of the DX7's chips, for FM-86's DX7 and
  DX7 II engines [fm86_voice.fy]; the MODERN engine doesn't use it.

  Written from the hardware write-ups, not from any emulator's code:
  Ken Shirriff's DX7 reverse engineering [righto.com, 2021-2022, parts
  IV "algorithms" and V "the output circuitry"] and ajxs's "Yamaha DX7
  Technical Analysis".

  The operator [YM21280 OPS] works in the log domain.  A quarter-wave
  log-sine ROM of 1024 entries turns the phase into an attenuation, the
  envelope's attenuation is added to it [a multiplication, done as an
  addition of logs], and an exponent ROM turns the sum back into a
  linear value; its integer part is a right shift.  So:

    phase        4096 steps a cycle [the ROM index]
    log-sine     1/1024 of an octave [log2 units]
    envelope     1/256 of an octave [12 bits over 16 octaves]
    output       a 12-bit magnitude per operator, truncated by the shift,
                 so quiet operators lose bits: the grit on a decay

  The voice's carriers are divided by their count [algorithm 32 by 1/6,
  in the log domain] into a 15-bit sample.  The DAC is 12 bits with an
  analog scaler dividing by 1, 2, 4 or 8, picked per sample from the
  leading zeros with two kept as headroom: a sign, an 11-bit mantissa
  and a 2-bit exponent, so the step is 8, 4, 2 or 1 [of 16384] as the
  sample gets quieter.  A Sallen-Key low-pass at about 16 kHz follows.

  The DX7 II [YM2604 OPS2 / YM3609 EGS2] is documented far less: it
  sounds the same but cleaner, and keeps its top end up the keyboard.
  Here it is an assumption, and labelled so: the same log-domain
  operator with a 14-bit magnitude, a linear 16-bit DAC with no gain
  ranging, and a gentler 20 kHz filter.

  Both engines also take the feedback of ALGO 4 and 6 round the loop the
  DX7's algorithm chart draws [OP4, OP5 back to OP6; fm86-voice-step-dx],
  where msfa has OP6 feed itself.  At high levels and FBK 7 the ALGO 4
  loop turns to noise, as players report of the instrument; that is
  lore, not a measurement.

  Not modelled: the DX7's 49,096 Hz sample rate [FM-86 runs at the
  host's], and the "buzz" Dexed's authors hear on hardware that no
  engine reproduces - its cause isn't documented, so it waits for a
  recording to measure against. )

include "../00-primitives/math.fy"

:: _dxc-lib "/usr/lib/libSystem.B.dylib" dl-open ;
:: _dxc-sin  _dxc-lib "sin" dl-sym ;
:: _dxc-log2  _dxc-lib "log2" dl-sym ;
:: _dxc-exp2  _dxc-lib "exp2" dl-sym ;
:: _dxc-round  _dxc-lib "round" dl-sym ;
noalloc: dxc-sin  _dxc-sin bind: d:d ;
noalloc: dxc-log2  _dxc-log2 bind: d:d ;
noalloc: dxc-exp2  _dxc-exp2 bind: d:d ;
noalloc: dxc-round  _dxc-round bind: d:d ;

:: DXC-PI 3.141592653589793 ;

( the quarter-wave log-sine ROM: -log2 sin, in 1/1024 octaves, at the
  middle of each of 1024 steps )
table: dxc-logsin 1024
  0.5 f+ 1024.0 f/ DXC-PI f* 0.5 f* dxc-sin dxc-log2 -1024.0 f* dxc-round
;

( the exponent ROM: 2^-[n/1024] as a 12-bit mantissa, 4096 .. 2048 )
table: dxc-exp 1024
  -1024.0 f/ dxc-exp2 4096.0 f* dxc-round
;

( ph att bits -- y : one operator sample from its total phase [cycles]
  and envelope attenuation [octaves under full scale]; `bits` is the
  output magnitude's resolution [4096 for the OPS, 16384 for OPS2].
  y is in FM-86's units, full scale 2. )
dsp: dxc-op | ph att bits -- y |
  ph ffrac 4096.0 f* floor | i |
  i 0.0009765625 f* floor | q |           ( quadrant 0..3 )
  i q 1024.0 f* f- | j |
  q 1.0 f=  q 3.0 f=  or  1023.0 j f-  j  select | jj |
  dxc-logsin jj f@i | ls |
  att 256.0 f* floor 4.0 f* | ea |         ( the envelope, 1/256 octave, in 1/1024 )
  ls ea f+ | t |                           ( total attenuation, 1/1024 octaves )
  t 0.0009765625 f* floor | k |
  t k 1024.0 f* f- | f |
  dxc-exp f f@i | m |                      ( 4096 .. 2048 )
  m bits 0.000244140625 f* f*  0.0 k f- fexp2i f*  floor | y |  ( the shift truncates )
  k 30.0 f<  y 0.0 select | yy |
  yy 2.0 bits f/ f* | a |
  q 1.5 f>  0.0 a f-  a  select
;

( x v2 -- y : the voice's sample through the DAC, x in -1..1 of the
  15-bit full scale.  DX7: truncated to 15 bits, then to the gain
  range's step [8, 4, 2 or 1 of 16384].  DX7 II [v2 = 1]: a linear
  16-bit converter. )
dsp: dxc-dac | x v2 -- y |
  v2 0.5 f>  32768.0 16384.0 select | fs |
  x -1.0 1.0 fclamp fs f* floor | n |
  n fabs | an |
  an 2048.0 f>=  8.0  an 1024.0 f>=  4.0  an 512.0 f>=  2.0 1.0  select select select | st1 |
  v2 0.5 f>  1.0 st1 select | st |
  n st f/ floor st f*  fs f/
;
