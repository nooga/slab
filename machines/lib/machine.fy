( machine.fy — machine manifest struct.
  A machine file defines a word called `manifest` that creates and
  returns one of these structs.  Slab compiles the file, calls manifest,
  reads the fields, then captures the audio/ui quote references.

  Port flags (0 or 1):
    in-notes  — machine reads ctx note_in
    out-notes — machine writes ctx note_out
    in-audio  — machine reads ctx audio_in
    out-audio — machine writes ctx audio_out )

struct: Machine
  ptr audio        ( quote ref to the per-block render word )
  ptr ui           ( quote ref to the panel draw word, or 0 )
  u32 state-size   ( bytes of persistent state to allocate )
  u32 params-size  ( bytes for params double-buffer )
  u8  in-notes
  u8  out-notes
  u8  in-audio
  u8  out-audio
;

( Port helpers — push ( in-notes out-notes in-audio out-audio ).
  Use in manifest before Machine.new, or push the four flags manually
  if your machine type doesn't fit one of these. )
: notes->audio   1 0 0 1 ;   ( instrument: note events in, audio out )
: audio->audio   0 0 1 1 ;   ( effect: audio in and out             )
: notes->notes   1 1 0 0 ;   ( transformer: note events in and out  )
