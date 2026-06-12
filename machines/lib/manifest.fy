( manifest.fy — machine descriptor vocabulary.

  A machine file defines a word called `manifest` that builds and returns
  a MachineDesc.  The host compiles the file, calls `manifest`, and walks
  the descriptor graph [src/machine_desc.zig].  Everything the old
  pipe-delimited .manifest text file carried lives here instead, and all
  param offsets come from ustruct field introspection — never hand-written
  numbers.

  Authoring shape:

    : manifest
      "name" voice-sample machine*
      "render-word" render!  "prepare-word" prepare!
      MyState.size state-size!  MyParams.size params-size!
      420.0 panel-w!
      "MOD" "LBL" "ctl-id" MyParams.field 0.0 1.0 0.5 curve-lin knob
      "MOD" "SEL" "sel-id" MyParams.other 1.0 switch
        "OFF" 0.0 opt  "ON" 1.0 opt
      "MOD" 1 strip
      4.0 row  1.0 cell  "MOD" 1.0 item
      machine-desc
    ;

  All fields are `ptr` so the Zig mirror is a flat array of tagged i64
  values: ints/pointers untag with >>2, floats mask the low tag bits. )

struct: MachineDesc
  ptr name           ( cstr )
  ptr mode           ( int: 0 voice-sample, 1 effect-sample, 2 effect-block )
  ptr render         ( cstr dsp2 word name )
  ptr prepare        ( cstr or 0 )
  ptr note-on        ( cstr or 0 )
  ptr note-off       ( cstr or 0 )
  ptr block-prepare  ( cstr or 0 — dsp2 word: params sample-rate -- )
  ptr state-size     ( int bytes )
  ptr params-size    ( int bytes )
  ptr panel-w        ( float px )
  ptr controls       ( ControlDesc chain or 0 )
  ptr strips         ( StripDesc chain or 0 )
  ptr displays       ( DisplayDesc chain or 0 )
  ptr rows           ( RowDesc chain or 0 )
  ptr consts         ( ConstDesc chain or 0 )
  ptr note-pitch     ( int flag: note-on gets raw MIDI pitch, not Hz )
  ptr note-labels    ( NoteLabelDesc chain or 0 — drum-lane piano roll )
  ptr buffers        ( BufferDesc chain or 0 — host-allocated audio buffers )
  ptr channel-cell   ( int state offset + 1, or 0 — host writes channel index )
  ptr detector-cell  ( int state offset + 1, or 0 — host writes pointer to a
                       per-block detector buffer: max abs of both inputs )
;

struct: ControlDesc
  ptr next
  ptr module         ( cstr strip/module name )
  ptr label          ( cstr knob label )
  ptr id             ( cstr stable identity, survives reloads )
  ptr kind           ( int: 0 knob/direct-f64, 1 switch )
  ptr offset         ( int byte offset into params )
  ptr min
  ptr max
  ptr default        ( knob: value; switch: option index )
  ptr curve          ( int: 0 linear, 1 exp )
  ptr options        ( OptionDesc chain, switch only )
;

struct: OptionDesc  ptr next  ptr label  ptr value ;
struct: StripDesc   ptr next  ptr module  ptr cols ;
struct: DisplayDesc ptr next  ptr name  ptr kind  ptr sources ;
struct: RowDesc     ptr next  ptr weight  ptr cells ;
struct: CellDesc    ptr next  ptr weight  ptr items ;
struct: ItemDesc    ptr next  ptr name  ptr weight ;
struct: ConstDesc   ptr next  ptr offset  ptr value ;
struct: NoteLabelDesc ptr next  ptr pitch  ptr label ;
struct: BufferDesc  ptr next  ptr name  ptr ptr-offset  ptr len-offset  ptr seconds ;

( --- builder state ------------------------------------------------ )
:: _mf-md         8 alloc ;
:: _mf-last-ctl   8 alloc ;
:: _mf-last-opt   8 alloc ;
:: _mf-last-strip 8 alloc ;
:: _mf-last-disp  8 alloc ;
:: _mf-last-row   8 alloc ;
:: _mf-last-cell  8 alloc ;
:: _mf-last-item  8 alloc ;
:: _mf-last-const 8 alloc ;
:: _mf-last-nl    8 alloc ;
:: _mf-last-buf   8 alloc ;

: _mf-md@ _mf-md @64 ;

( --- mode + curve constants --------------------------------------- )
: voice-sample 0 ;
: effect-sample 1 ;
: effect-block 2 ;
: curve-lin 0 ;
: curve-exp 1 ;  ( log taper - frequencies, times; min must be > 0 )
: curve-pow 2 ;  ( squared audio taper - levels, sends, 0-based ranges )

( --- machine header ------------------------------------------------ )
: machine*  ( name-str mode -- )
  MachineDesc.alloc _mf-md !64
  _mf-md@ MachineDesc.mode! drop
  cstr-new _mf-md@ MachineDesc.name! drop
  0 _mf-last-ctl !64
  0 _mf-last-opt !64
  0 _mf-last-strip !64
  0 _mf-last-disp !64
  0 _mf-last-row !64
  0 _mf-last-cell !64
  0 _mf-last-item !64
  0 _mf-last-const !64
  0 _mf-last-nl !64
  0 _mf-last-buf !64
;

: render!        ( str -- ) cstr-new _mf-md@ MachineDesc.render! drop ;
: prepare!       ( str -- ) cstr-new _mf-md@ MachineDesc.prepare! drop ;
: note-on!       ( str -- ) cstr-new _mf-md@ MachineDesc.note-on! drop ;
: note-off!      ( str -- ) cstr-new _mf-md@ MachineDesc.note-off! drop ;
: block-prepare! ( str -- ) cstr-new _mf-md@ MachineDesc.block-prepare! drop ;
: state-size!    ( n -- ) _mf-md@ MachineDesc.state-size! drop ;
: params-size!   ( n -- ) _mf-md@ MachineDesc.params-size! drop ;
: panel-w!       ( f -- ) _mf-md@ MachineDesc.panel-w! drop ;

( note-on receives raw MIDI pitch instead of Hz — drum machines, where
  the pitch is an address, not a frequency. )
: note-pitch  ( -- ) 1 _mf-md@ MachineDesc.note-pitch! drop ;

( declare a note the machine answers to; the piano roll renders one
  labelled lane per declared note instead of the chromatic keyboard. )
: note-label  ( pitch label -- )
  NoteLabelDesc.alloc
  swap cstr-new swap NoteLabelDesc.label!
  NoteLabelDesc.pitch!
  _mf-last-nl @64 0 =
  [ dup _mf-md@ MachineDesc.note-labels! drop ]
  [ dup _mf-last-nl @64 NoteLabelDesc.next! drop ]
  ifte
  _mf-last-nl !64
;

( --- controls ------------------------------------------------------ )
: _mf-append-ctl  ( ctl -- )
  _mf-last-ctl @64 0 =
  [ dup _mf-md@ MachineDesc.controls! drop ]
  [ dup _mf-last-ctl @64 ControlDesc.next! drop ]
  ifte
  _mf-last-ctl !64
;

: knob  ( module label id offset min max default curve -- )
  ControlDesc.alloc
  ControlDesc.curve!
  ControlDesc.default!
  ControlDesc.max!
  ControlDesc.min!
  ControlDesc.offset!
  swap cstr-new swap ControlDesc.id!
  swap cstr-new swap ControlDesc.label!
  swap cstr-new swap ControlDesc.module!
  0 swap ControlDesc.kind!
  _mf-append-ctl
;

( default is the selected option index. Follow with `opt` lines. )
: switch  ( module label id offset default -- )
  ControlDesc.alloc
  ControlDesc.default!
  ControlDesc.offset!
  swap cstr-new swap ControlDesc.id!
  swap cstr-new swap ControlDesc.label!
  swap cstr-new swap ControlDesc.module!
  1 swap ControlDesc.kind!
  0 _mf-last-opt !64
  _mf-append-ctl
;

: opt  ( label value -- )
  OptionDesc.alloc
  OptionDesc.value!
  swap cstr-new swap OptionDesc.label!
  _mf-last-opt @64 0 =
  [ dup _mf-last-ctl @64 ControlDesc.options! drop ]
  [ dup _mf-last-opt @64 OptionDesc.next! drop ]
  ifte
  _mf-last-opt !64
;

( --- panel: strips, displays, weighted layout --------------------- )
: strip  ( module knob-cols -- )
  StripDesc.alloc
  StripDesc.cols!
  swap cstr-new swap StripDesc.module!
  _mf-last-strip @64 0 =
  [ dup _mf-md@ MachineDesc.strips! drop ]
  [ dup _mf-last-strip @64 StripDesc.next! drop ]
  ifte
  _mf-last-strip !64
;

( sources: comma-separated module names overlaid in one field. )
: adsr-display  ( name sources -- )
  DisplayDesc.alloc
  swap cstr-new swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  0 swap DisplayDesc.kind!
  _mf-last-disp @64 0 =
  [ dup _mf-md@ MachineDesc.displays! drop ]
  [ dup _mf-last-disp @64 DisplayDesc.next! drop ]
  ifte
  _mf-last-disp !64
;

: row  ( height-weight -- )
  RowDesc.alloc
  RowDesc.weight!
  _mf-last-row @64 0 =
  [ dup _mf-md@ MachineDesc.rows! drop ]
  [ dup _mf-last-row @64 RowDesc.next! drop ]
  ifte
  _mf-last-row !64
  0 _mf-last-cell !64
;

: cell  ( width-weight -- )
  CellDesc.alloc
  CellDesc.weight!
  _mf-last-cell @64 0 =
  [ dup _mf-last-row @64 RowDesc.cells! drop ]
  [ dup _mf-last-cell @64 CellDesc.next! drop ]
  ifte
  _mf-last-cell !64
  0 _mf-last-item !64
;

( name refers to a strip module or a display; items stack in the cell. )
: item  ( name height-weight -- )
  ItemDesc.alloc
  ItemDesc.weight!
  swap cstr-new swap ItemDesc.name!
  _mf-last-item @64 0 =
  [ dup _mf-last-cell @64 CellDesc.items! drop ]
  [ dup _mf-last-item @64 ItemDesc.next! drop ]
  ifte
  _mf-last-item !64
;

( --- host-allocated buffers ---------------------------------------- )
( Request an audio-rate f64 buffer from the host: per channel, the host
  allocates ceil[seconds * sample-rate] zeroed f64 cells at machine
  create, then writes the base pointer and the element count into that
  channel's STATE at the two introspected field offsets. Kernels read
  them back with p@64 / f@64 and index with f@i / f!i. )
: buffer  ( name ptr-offset len-offset seconds -- )
  BufferDesc.alloc
  BufferDesc.seconds!
  BufferDesc.len-offset!
  BufferDesc.ptr-offset!
  swap cstr-new swap BufferDesc.name!
  _mf-last-buf @64 0 =
  [ dup _mf-md@ MachineDesc.buffers! drop ]
  [ dup _mf-last-buf @64 BufferDesc.next! drop ]
  ifte
  _mf-last-buf !64
;

( The host writes the channel index — 0.0 left, 1.0 right — into STATE at
  this introspected offset after buffer injection and after every reset.
  Effect machines use it to decorrelate the two channels: LFO phase
  offsets, slight delay detunes.  Stored as offset+1 so 0 means "none". )
: channel-cell  ( offset -- )
  1 + _mf-md@ MachineDesc.channel-cell! drop
;

( The host writes a pointer to a block-length detector buffer — per
  sample the max of abs of both input channels — into STATE at this
  introspected offset.  Both channels read the SAME buffer, which is
  what makes a compressor stereo-linked.  Kernels index it with a
  sample counter zeroed in their prepare word - prepare runs once per
  block.  Stored as offset+1 so 0 means "none". )
: detector-cell  ( offset -- )
  1 + _mf-md@ MachineDesc.detector-cell! drop
;

( --- params constants ---------------------------------------------- )
: const-f64  ( offset value -- )
  ConstDesc.alloc
  ConstDesc.value!
  ConstDesc.offset!
  _mf-last-const @64 0 =
  [ dup _mf-md@ MachineDesc.consts! drop ]
  [ dup _mf-last-const @64 ConstDesc.next! drop ]
  ifte
  _mf-last-const !64
;

( --- finish --------------------------------------------------------- )
: machine-desc  ( -- desc ) _mf-md@ ;
