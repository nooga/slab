( ctx.fy - the host <-> machine kernel ABI [docs/04 §Kernel ABI].

  Every machine entry word takes ( ctx state params -- ).  Per-sample
  render words take a leading io pointer: ( io ctx state params -- ); the
  host's repeated caller advances io by Io.size each sample.

  The host mirrors both structs as extern structs in
  src/machines/fy_raw_machine.zig [KernelCtx, IoFrame]; a test there
  checks the layouts match.  Including this file more than once is fine. )

ustruct: Ctx
  f64 sr       ( sample rate, Hz )
  f64 inv-sr   ( 1 / sr )
  f64 tempo    ( host tempo, bpm )
  f64 beat     ( quarter-note position at block start )
  f64 frames   ( frames in this block )
  f64 chan     ( region index: voice index for voice machines, 0 L / 1 R for effects )
  f64 hz       ( note-on: pitch in Hz - or raw MIDI pitch for note-pitch machines )
  f64 vel      ( note-on: velocity 0..1 )
  f64 pitch    ( note-on: MIDI pitch )
  f64 data     ( pointer: the machine's derive data; read with Ctx.data-p p@64 )
  f64 legato   ( note-on: 1 when the voice was still held [mono slide], else 0 )
;

ustruct: Io
  f64 out-l    ( @0: voices ACCUMULATE here, effects write it.  At offset 0 so
                 a stage handed io can keep using `out f@64` / `out f!64`. )
  f64 out-r
  f64 in-l     ( effect input for this pass's channel [dual-mono lane] )
  f64 in-r
  f64 det      ( max of |L| |R| of the effect input: stereo-linked detector )
;
