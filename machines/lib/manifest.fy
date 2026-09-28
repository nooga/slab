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

  Entry words [render, prepare, note-on, note-off, note-expr,
  block-prepare, derive]
  all take ( ctx state params -- ); render takes a leading io pointer:
  ( io ctx state params -- ).  Ctx/Io live in kernels/00-primitives/ctx.fy
  [docs/04 §Kernel ABI].

  All fields are `ptr` so the Zig mirror is a flat array of tagged i64
  values: ints/pointers untag with >>2, floats mask the low tag bits. )

struct: MachineDesc
  ptr name           ( cstr )
  ptr mode           ( int: 0 voice-sample, 2 effect-block )
  ptr render         ( cstr dsp2 word name )
  ptr prepare        ( cstr or 0 )
  ptr note-on        ( cstr or 0 )
  ptr note-off       ( cstr or 0 )
  ptr block-prepare  ( cstr or 0 — dsp: word, once per block )
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
  ptr voices         ( int voice count for voice-sample machines, 0 = mono )
  ptr assets         ( AssetDesc chain or 0 — host-loaded read-only audio )
  ptr pages          ( PageDesc chain or 0 — tabbed panel; rows declared after
                       a `page` belong to it, and the panel shows a tab bar.
                       When 0, the top-level `rows` chain is the whole panel. )
  ptr derive         ( cstr or 0 — dsp: word called each block, before
                       block-prepare, to compute derived params from controls. )
  ptr derive-data    ( ptr or 0 — opaque machine-built data, handed to every
                       entry word as ctx.data. )
  ptr stereo         ( int flag: voices write out-l AND out-r; effects get one
                       true-stereo pass with in-l/in-r instead of dual mono )
  ptr note-expr      ( cstr or 0 — dsp: word retuning a sounding voice to
                       ctx.pitch / ctx.hz: per-note expression, docs/22 )
  ptr sidechain      ( int flag: an effect whose io.det can come from another
                       track's signal, a key [docs/23] )
  ptr render-lite    ( cstr or 0 — a cheaper render word for blocks where
                       the params f64 at render-lite-sel is exactly 0 )
  ptr render-lite-sel  ( int params byte offset )
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
  ptr widget         ( int: panel control, 0 auto [see `as-fader` & co] )
;

struct: OptionDesc  ptr next  ptr label  ptr value  ptr sets ;
( picking the option from the panel also sets these controls )
struct: SetDesc  ptr next  ptr id  ptr value ;
struct: StripDesc   ptr next  ptr module  ptr cols ;
( kind 0 adsr, 1 waveform, 2 meter.  off0..off6 are state byte offsets used
  only by the meter kind, in order: gain-min, in-peak, out-peak,
  ms-momentary, ms-short, ms-integrated-sum, integrated-count. )
struct: DisplayDesc
  ptr next  ptr name  ptr kind  ptr sources
  ptr off0  ptr off1  ptr off2  ptr off3  ptr off4  ptr off5  ptr off6
;
struct: PageDesc    ptr next  ptr name  ptr rows ;
struct: RowDesc     ptr next  ptr weight  ptr cells ;
struct: CellDesc    ptr next  ptr weight  ptr items ;
struct: ItemDesc    ptr next  ptr name  ptr weight ;
struct: ConstDesc   ptr next  ptr offset  ptr value ;
struct: NoteLabelDesc ptr next  ptr pitch  ptr label ;
struct: BufferDesc  ptr next  ptr name  ptr ptr-offset  ptr len-offset  ptr seconds ;
struct: AssetDesc   ptr next  ptr name  ptr ptr-offset  ptr len-offset  ptr sr-offset  ptr file  ptr kind  ptr edits-offset  ptr aa-control  ptr aa-ratio  ptr aa-cap ;

( --- builder state ------------------------------------------------ )
:: _mf-md         8 alloc ;
:: _mf-last-ctl   8 alloc ;
:: _mf-last-opt   8 alloc ;
:: _mf-last-strip 8 alloc ;
:: _mf-last-disp  8 alloc ;
:: _mf-last-row   8 alloc ;
:: _mf-last-page  8 alloc ;
:: _mf-cur-page   8 alloc ;
:: _mf-last-cell  8 alloc ;
:: _mf-last-item  8 alloc ;
:: _mf-last-const 8 alloc ;
:: _mf-last-nl    8 alloc ;
:: _mf-last-buf   8 alloc ;
:: _mf-last-asset 8 alloc ;

: _mf-md@ _mf-md @64 ;

( --- mode + curve constants --------------------------------------- )
: voice-sample 0 ;
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
  0 _mf-last-page !64
  0 _mf-cur-page !64
  0 _mf-last-cell !64
  0 _mf-last-item !64
  0 _mf-last-const !64
  0 _mf-last-nl !64
  0 _mf-last-buf !64
  0 _mf-last-asset !64
;

: render!        ( str -- ) cstr-new _mf-md@ MachineDesc.render! drop ;
: voices!        ( n -- ) _mf-md@ MachineDesc.voices! drop ;
: prepare!       ( str -- ) cstr-new _mf-md@ MachineDesc.prepare! drop ;
: note-on!       ( str -- ) cstr-new _mf-md@ MachineDesc.note-on! drop ;
: note-off!      ( str -- ) cstr-new _mf-md@ MachineDesc.note-off! drop ;
: note-expr!     ( str -- ) cstr-new _mf-md@ MachineDesc.note-expr! drop ;
: block-prepare! ( str -- ) cstr-new _mf-md@ MachineDesc.block-prepare! drop ;
: derive!        ( str -- ) cstr-new _mf-md@ MachineDesc.derive! drop ;
: derive-data!   ( ptr -- ) _mf-md@ MachineDesc.derive-data! drop ;
: state-size!    ( n -- ) _mf-md@ MachineDesc.state-size! drop ;
: params-size!   ( n -- ) _mf-md@ MachineDesc.params-size! drop ;
: panel-w!       ( f -- ) _mf-md@ MachineDesc.panel-w! drop ;

( note-on receives raw MIDI pitch instead of Hz — drum machines, where
  the pitch is an address, not a frequency. )
: note-pitch  ( -- ) 1 _mf-md@ MachineDesc.note-pitch! drop ;
( the machine renders true stereo [see MachineDesc.stereo] )
: stereo  ( -- ) 1 _mf-md@ MachineDesc.stereo! drop ;
( the effect's detector [io.det] takes a sidechain key: with one set, the
  host fills io.det from the key track instead of the input [docs/23] )
: sidechain  ( -- ) 1 _mf-md@ MachineDesc.sidechain! drop ;
( a second render word the host runs instead for any block where the
  params f64 at `offset` is exactly 0 - a stage that does nothing at
  that setting [bus2's COLOR] skips its cost; the word must produce the
  same output there )
: render-lite!  ( str offset -- )
  _mf-md@ MachineDesc.render-lite-sel! drop
  cstr-new _mf-md@ MachineDesc.render-lite! drop ;

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
( Integer selector over [min, max]: a detented rotary with generated number
  labels. The param receives the raw integer. For ranges too wide for `switch`'s
  option list, e.g. the 32 DX7 algorithms. )
: int-step  ( module label id offset min max default -- )
  ControlDesc.alloc
  ControlDesc.default!
  ControlDesc.max!
  ControlDesc.min!
  ControlDesc.offset!
  swap cstr-new swap ControlDesc.id!
  swap cstr-new swap ControlDesc.label!
  swap cstr-new swap ControlDesc.module!
  2 swap ControlDesc.kind!
  _mf-append-ctl
;

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

( After an `opt`: choosing that option on the panel also moves control
  `id` to `value` [in its own units] - a switch of models that each set
  several knobs.  Presets and automation set only the switch. )
: sets  ( id value -- )
  SetDesc.alloc
  SetDesc.value!
  swap cstr-new swap SetDesc.id!
  _mf-last-opt @64 OptionDesc.sets@ nip over SetDesc.next! drop
  _mf-last-opt @64 OptionDesc.sets! drop
;

( --- panel controls -------------------------------------------------
  Follow a control [after its `opt` lines] to pick the catalogue control
  the panel draws for it.  Without one the panel picks from the kind:
  knobs for values, an LED latch for OFF/ON, a lever for other pairs, a
  list for 3-6 options.  A centred range [-x..x] draws from the middle out. )
: _mf-widget  ( n -- ) _mf-last-ctl @64 ControlDesc.widget! drop ;
: as-knob    1 _mf-widget ;  ( rotary; switches get a stepped one )
: as-fader   2 _mf-widget ;  ( vertical fader, values only )
: as-lever   3 _mf-widget ;  ( toggle lever, 2 options )
: as-slide   4 _mf-widget ;  ( horizontal slide switch )
: as-list    5 _mf-widget ;  ( LED option column )
: as-radio   6 _mf-widget ;  ( joined LED buttons, one down )
: as-button  7 _mf-widget ;  ( LED latch, 2 options: off / on )

( VFD value with steppers: options, or an integer range of up to 128 )
: as-display 8 _mf-widget ;
( joined LED buttons stacked top to bottom, one down )
: as-vradio  9 _mf-widget ;

( --- panel: strips, displays, weighted layout --------------------- )
: _mf-append-disp  ( disp -- )
  _mf-last-disp @64 0 =
  [ dup _mf-md@ MachineDesc.displays! drop ]
  [ dup _mf-last-disp @64 DisplayDesc.next! drop ]
  ifte
  _mf-last-disp !64
;

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

( bind a waveform oscillogram to a host asset (by asset name); the panel
  draws the loaded sample plus a LOAD button. )
: waveform-display  ( name asset-name -- )
  DisplayDesc.alloc
  swap cstr-new swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  1 swap DisplayDesc.kind!
  _mf-last-disp @64 0 =
  [ dup _mf-md@ MachineDesc.displays! drop ]
  [ dup _mf-last-disp @64 DisplayDesc.next! drop ]
  ifte
  _mf-last-disp !64
;

( a CMI voice's RAM as 128 segments with its loop and start markers,
  bound to cmi-rate / cmi-loop / cmi-loop-start / cmi-loop-end /
  cmi-start; LOAD as on a waveform-display. )
: segment-display  ( name asset-name -- )
  DisplayDesc.alloc
  swap cstr-new swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  7 swap DisplayDesc.kind!
  _mf-last-disp @64 0 =
  [ dup _mf-md@ MachineDesc.displays! drop ]
  [ dup _mf-last-disp @64 DisplayDesc.next! drop ]
  ifte
  _mf-last-disp !64
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

( A frequency-response curve [kind 3].  The display reads the machine's
  own band controls and recomputes the composite biquad magnitude, so it
  needs no sources or state offsets — just a name for panel placement. )
: response-display  ( name -- )
  DisplayDesc.alloc
  0 swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  3 swap DisplayDesc.kind!
  _mf-last-disp @64 0 =
  [ dup _mf-md@ MachineDesc.displays! drop ]
  [ dup _mf-last-disp @64 DisplayDesc.next! drop ]
  ifte
  _mf-last-disp !64
;

( A compressor's transfer curve [kind 8]: the static curve of the
  machine's `prefix`-thresh / -ratio / -knee controls [e.g. "comp"],
  the live detector level [state f64 at `lvl`, linear] as a dot at the
  gain actually applied, and a gain-reduction bar [state f64 at `gr`,
  dB >= 0]. )
: dyn-display  ( name prefix gr lvl -- )
  DisplayDesc.alloc
  DisplayDesc.off1!
  DisplayDesc.off0!
  swap cstr-new swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  8 swap DisplayDesc.kind!
  _mf-last-disp @64 0 =
  [ dup _mf-md@ MachineDesc.displays! drop ]
  [ dup _mf-last-disp @64 DisplayDesc.next! drop ]
  ifte
  _mf-last-disp !64
;

( An operator-routing diagram [kind 4], read from the machine's
  derive-data table: the row is the value of the int-step control `selector`
  minus its min; `ops` operators; each row is `stride` f64s holding a
  modulation matrix m[carrier][modulator] at `matrix`, carrier flags at
  `carriers` and feedback flags at `feedback` [all element offsets]. )
: algo-display  ( name selector ops stride matrix carriers feedback -- )
  DisplayDesc.alloc
  DisplayDesc.off4!
  DisplayDesc.off3!
  DisplayDesc.off2!
  DisplayDesc.off1!
  DisplayDesc.off0!
  swap cstr-new swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  4 swap DisplayDesc.kind!
  _mf-append-disp
;

( A four-rate / four-level envelope [kind 5], DX style: reads the source
  module's R1..R4 rates [level per sample] and L1..L4 levels. )
: eg4-display  ( name module -- )
  DisplayDesc.alloc
  swap cstr-new swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  5 swap DisplayDesc.kind!
  _mf-append-disp
;

( A live level/loudness meter [kind 2].  The seven state byte offsets are
  read each frame by the panel: gain-min [GR], in-peak, out-peak, and the
  four LUFS mean-square cells.  Offsets are pushed in that order, count on
  top. )
: meter-display  ( name gmin ipk opk msm mss msum mn -- )
  DisplayDesc.alloc
  DisplayDesc.off6!
  DisplayDesc.off5!
  DisplayDesc.off4!
  DisplayDesc.off3!
  DisplayDesc.off2!
  DisplayDesc.off1!
  DisplayDesc.off0!
  swap cstr-new swap DisplayDesc.name!
  2 swap DisplayDesc.kind!
  _mf-last-disp @64 0 =
  [ dup _mf-md@ MachineDesc.displays! drop ]
  [ dup _mf-last-disp @64 DisplayDesc.next! drop ]
  ifte
  _mf-last-disp !64
;

( Open a named tab.  Rows declared after this belong to the page until the
  next `page`; the panel grows a tab bar.  Mixing top-level rows and pages is
  not supported — use one or the other. )
: page  ( name -- )
  PageDesc.alloc
  swap cstr-new swap PageDesc.name!
  _mf-last-page @64 0 =
  [ dup _mf-md@ MachineDesc.pages! drop ]
  [ dup _mf-last-page @64 PageDesc.next! drop ]
  ifte
  dup _mf-last-page !64
  _mf-cur-page !64
  0 _mf-last-row !64
;

: row  ( height-weight -- )
  RowDesc.alloc
  RowDesc.weight!
  _mf-last-row @64 0 =
  [ _mf-cur-page @64 0 =
    [ dup _mf-md@ MachineDesc.rows! drop ]
    [ dup _mf-cur-page @64 PageDesc.rows! drop ]
    ifte ]
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

( Request a read-only audio asset from the host.  At create the host
  loads `file` [relative to the machine's directory] into f64 mono and
  writes the base pointer, sample count, and native sample-rate into
  PARAMS at the three introspected offsets [params are shared and the
  asset is read-only, so one copy serves every voice].  Kernels read it
  with p@64 / f@64 and index with f@i.  Re-injected after reset. )
: asset  ( name ptr-offset len-offset sr-offset file -- )
  AssetDesc.alloc
  0 swap AssetDesc.kind!
  0 swap AssetDesc.edits-offset!
  0 swap AssetDesc.aa-control!
  0 swap AssetDesc.aa-ratio!
  0 swap AssetDesc.aa-cap!
  swap cstr-new swap AssetDesc.file!
  AssetDesc.sr-offset!
  AssetDesc.len-offset!
  AssetDesc.ptr-offset!
  swap cstr-new swap AssetDesc.name!
  _mf-last-asset @64 0 =
  [ dup _mf-md@ MachineDesc.assets! drop ]
  [ dup _mf-last-asset @64 AssetDesc.next! drop ]
  ifte
  _mf-last-asset !64
;

( Request a keymap: a .wav, a .sfz or a folder of WAVs [relative to the
  machine's directory; src/keymap.zig says how each maps], loaded into
  one sample pool and a table of 128 zones.  The host writes the pool's
  pointer at pool-offset, the zone table's pointer at zones-offset, the
  zone count at count-offset, and a pointer to the per-zone edits
  [level, tune, decay, tone; src/keymap.zig ZoneEdits] at edits-offset,
  all in PARAMS.  LOAD on the panel's waveform display swaps it at
  runtime; a zone-display edits the zones. )
: keymap  ( name pool-offset zones-offset count-offset edits-offset file -- )
  swap >r asset
  1 _mf-last-asset @64 AssetDesc.kind! drop
  r> _mf-last-asset @64 AssetDesc.edits-offset! drop
;

( Low-pass the last keymap's samples ahead of the rate the machine
  stores them at, as a sampler's input filter did: the host filters each
  zone at ratio x the value of control `id` [an 8-pole Butterworth],
  when the keymap loads and whenever that control settles; `cap` stored
  samples' worth of each zone [0 = all of it]. )
: keymap-antialias  ( control-id ratio cap -- )
  _mf-last-asset @64 AssetDesc.aa-cap! drop
  _mf-last-asset @64 AssetDesc.aa-ratio! drop
  cstr-new _mf-last-asset @64 AssetDesc.aa-control! drop
;

( the zone list of a keymap asset: select a zone, edit its level, tune,
  decay and tone; FOLLOW selects the zone that last played. )
: zone-display  ( name asset-name -- )
  DisplayDesc.alloc
  swap cstr-new swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  6 swap DisplayDesc.kind!
  _mf-last-disp @64 0 =
  [ dup _mf-md@ MachineDesc.displays! drop ]
  [ dup _mf-last-disp @64 DisplayDesc.next! drop ]
  ifte
  _mf-last-disp !64
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
