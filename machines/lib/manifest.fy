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
  ptr key-flag       ( int: params byte offset + 1 where the host writes 1.0
                       while a sidechain key is connected, else 0.0; 0 = none )
  ptr control        ( cstr or 0 — voice machines: a dsp: word [ctx state
                       params --] the host calls on each voice every
                       control-period samples, before the render that follows )
  ptr control-period ( int samples )
  ptr latency        ( int: params byte offset + 1 of the f64 holding the
                       machine's latency in samples, kept current by its
                       derive or block-prepare word; 0 = none [docs/07 PDC] )
  ptr tail           ( float seconds the output can stay silent while the
                       machine still holds sound it will play unprompted,
                       beyond its buffers; negative = never idle-skip it;
                       0 = none [docs/04 Idle skipping] )
  ptr mods           ( ModDesc chain or 0 - modulation sources and
                       destinations the panel shows [docs/15 §Modulation] )
  ptr matrix         ( cstr or 0 - the mod matrix's control-id prefix )
  ptr matrix-slots   ( int slot count )
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
  ptr span           ( int: 1 = takes a whole strip column [`span-rows`] )
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
( kind 0 a source [index = its SRC option, flag 1 = bipolar], 1 a
  destination [name = the control id, index = its DEST option]; offset is
  the state f64 holding its live value. )
struct: ModDesc  ptr next  ptr kind  ptr name  ptr index  ptr offset  ptr flag ;
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
:: _mf-last-mod   8 alloc ;

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
  0 _mf-last-mod !64
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
: key-flag!  ( offset -- )  1 + _mf-md@ MachineDesc.key-flag! drop ;

( "word" period control! : a voice's control-rate hook [docs/04], run every
  `period` samples of each voice, counted from its note-on )
: control!  ( str period -- )
  _mf-md@ MachineDesc.control-period! drop
  cstr-new _mf-md@ MachineDesc.control! drop ;
( offset latency! : the params f64 at `offset` is the machine's latency in
  samples - how much later its output is than its input - which the host
  compensates on parallel paths [docs/07 PDC] )
: latency!  ( offset -- )  1 + _mf-md@ MachineDesc.latency! drop ;
( seconds tail! : the host keeps rendering the machine this long after its
  input and output fall silent, on top of its buffers' length, which it
  counts already [a delay's ring]; a negative time never lets it skip the
  machine - one that makes sound from nothing [docs/04 Idle skipping] )
: tail!  ( f -- )  _mf-md@ MachineDesc.tail! drop ;
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

( the control takes a whole column of its strip, beside the grid the
  others fill - a tall LED list next to its knobs )
: span-rows  _mf-last-ctl @64 1 swap ControlDesc.span! drop ;

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

( The same, with the knee read from state f64 at `knee` [dB] instead of
  the prefix-knee control - for a machine whose knee follows a mode. )
:: _mf-knee 8 alloc ;
: dyn-display-knee  ( name prefix gr lvl knee -- )
  _mf-knee !64
  dyn-display
  _mf-knee @64 _mf-last-disp @64 DisplayDesc.off2! drop
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

( A delay's repeat train [kind 9], from the machine's own controls:
  `<prefix>-time` / -sync / -div / -ratio / -offset / -fb / -mode /
  -char / -drive, and the host tempo. )
: taps-display  ( name prefix -- )
  DisplayDesc.alloc
  swap cstr-new swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  9 swap DisplayDesc.kind!
  _mf-last-disp @64 0 =
  [ dup _mf-md@ MachineDesc.displays! drop ]
  [ dup _mf-last-disp @64 DisplayDesc.next! drop ]
  ifte
  _mf-last-disp !64
;

( A reverb's decay [kind 10]: the predelay gap, the early reflections and
  the low / mid / high decay lines, from the machine's `<prefix>-decay` /
  -bass / -damp / -early / -algo / -size / -predelay / -pre-sync / -mode /
  -gate-hold controls and the host tempo. )
: decay-display  ( name prefix -- )
  DisplayDesc.alloc
  swap cstr-new swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  10 swap DisplayDesc.kind!
  _mf-last-disp @64 0 =
  [ dup _mf-md@ MachineDesc.displays! drop ]
  [ dup _mf-last-disp @64 DisplayDesc.next! drop ]
  ifte
  _mf-last-disp !64
;

( A graphic EQ's face [kind 11]: a spectrum analyser over the response
  of the machine's `<prefix>-b1`..`-b8` band gains, `-q` mode and `-out`
  trim.  sources is "prefix,buffer": the kernel writes its output into
  host buffer `buffer` as a ring with its write head at state f64
  `wpos`.  The log axis puts the bands evenly across the field. )
: graphic-display  ( name sources wpos -- )
  DisplayDesc.alloc
  DisplayDesc.off0!
  swap cstr-new swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  11 swap DisplayDesc.kind!
  _mf-append-disp
;

( An oscillator's wavetable [kind 12]: every frame of the table it plays
  stacked in depth, the played frame lit with its warp, and beside it the
  played cycle over its first 32 harmonics.  sources is
  "prefix,bank,user": controls `<prefix>-table` [an option named USER
  reads asset `user`, the others `frames`-frame tables of asset `bank`],
  -pos, -warp [OFF SYNC PWM BEND FM], -wamt and -on if there is one.  The
  newest voice's position and warp amount are the state f64s at pos-off
  and warp-off. )
: wavetable-display  ( name sources pos-off warp-off frames -- )
  DisplayDesc.alloc
  DisplayDesc.off2!
  DisplayDesc.off1!
  DisplayDesc.off0!
  swap cstr-new swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  12 swap DisplayDesc.kind!
  _mf-append-disp
;

( A filter's response [kind 13], 20 Hz to 20 kHz: `<prefix>-mode` [by
  option name: LP24 LP18 LP12 BP HP12 HP24 NOTCH, else flat], -cut
  and -res as the knobs set them, and lit where the newest voice has
  them: cutoff Hz at state f64 cut-off, resonance [-res's units] at
  res-off. )
: filter-display  ( name prefix cut-off res-off -- )
  DisplayDesc.alloc
  DisplayDesc.off1!
  DisplayDesc.off0!
  swap cstr-new swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  13 swap DisplayDesc.kind!
  _mf-append-disp
;

( An LFO [kind 14]: one cycle of `<prefix>-shape` [SINE TRI SAW UP
  SAW DN SQUARE S&H] with -uni, -rate / -sync and -mode in its caption,
  and the newest voice's phase [state ph-off, 0..1] and value [val-off]
  riding it. )
: lfo-display  ( name prefix ph-off val-off -- )
  DisplayDesc.alloc
  DisplayDesc.off1!
  DisplayDesc.off0!
  swap cstr-new swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  14 swap DisplayDesc.kind!
  _mf-append-disp
;

( An envelope [kind 15]: an adsr-display of `module` with the newest
  voice riding it, from its env_dig level and stage at state level-off
  and stage-off. )
: env-display  ( name module level-off stage-off -- )
  DisplayDesc.alloc
  DisplayDesc.off1!
  DisplayDesc.off0!
  swap cstr-new swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  15 swap DisplayDesc.kind!
  _mf-append-disp
;

( The modulation dock [kind 16]: a chip per `mod-source`, each with its
  live value; drag one onto a `mod-dest` knob or a matrix slot's SRC to
  route it. )
: mod-dock  ( name -- )
  DisplayDesc.alloc
  0 swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  16 swap DisplayDesc.kind!
  _mf-append-disp
;

( The machine's output as a scope [kind 17], two cycles of the newest
  voice's note, triggered on a rising zero crossing. )
: scope-display  ( name -- )
  DisplayDesc.alloc
  0 swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  17 swap DisplayDesc.kind!
  _mf-append-disp
;

( The mod matrix on one display [kind 18]: a row per `mod-matrix` slot,
  SOURCE -> DEST and the amount, with what the row adds now.  Edits go
  to the slots' own controls. )
: matrix-display  ( name -- )
  DisplayDesc.alloc
  0 swap DisplayDesc.sources!
  swap cstr-new swap DisplayDesc.name!
  18 swap DisplayDesc.kind!
  _mf-append-disp
;

( --- modulation [docs/15 §Modulation] ------------------------------- )
: _mf-append-mod  ( m -- )
  _mf-last-mod @64 0 =
  [ dup _mf-md@ MachineDesc.mods! drop ]
  [ dup _mf-last-mod @64 ModDesc.next! drop ]
  ifte
  _mf-last-mod !64
;

( A modulation source for the dock: its label, its index among the
  matrix's SRC options, the state f64 with its live value, 1 if it
  swings both ways. )
: mod-source  ( label src state-off bipolar -- )
  ModDesc.alloc
  ModDesc.flag!
  ModDesc.offset!
  ModDesc.index!
  swap cstr-new swap ModDesc.name!
  0 swap ModDesc.kind!
  _mf-append-mod
;

( Control `id` is a modulation destination: index `dst` among the
  matrix's DEST options; the state f64 at `state-off` is what the newest
  voice has it at, in the control's units.  Its knob shows a ring there
  and takes dropped sources. )
: mod-dest  ( control-id dst state-off -- )
  ModDesc.alloc
  ModDesc.offset!
  ModDesc.index!
  swap cstr-new swap ModDesc.name!
  1 swap ModDesc.kind!
  _mf-append-mod
;

( A built-in route: knob `control-id` sets how much SRC option `src`
  moves DEST option `dst` outside the matrix [a filter's ENV amount, its
  KEY tracking].  The matrix display lists it as a fixed row whose amount
  is that knob. )
: mod-fixed  ( control-id src dst -- )
  ModDesc.alloc
  ModDesc.offset!
  ModDesc.index!
  swap cstr-new swap ModDesc.name!
  2 swap ModDesc.kind!
  _mf-append-mod
;

( The mod matrix: `slots` slots of controls `<prefix><n>-src`, -dst and
  -amt, n from 1. )
: mod-matrix  ( prefix slots -- )
  _mf-md@ MachineDesc.matrix-slots! drop
  cstr-new _mf-md@ MachineDesc.matrix! drop
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

( Request a wavetable: a WAV of single-cycle frames [2048 samples each,
  or what a Serum `clm ` chunk says; a shorter file is one frame],
  relative to the machine's directory.  The host band-limits every frame
  into octave mip levels [src/wavetable.zig] and writes the table's
  pointer at ptr-offset and its frame count [f64] at frames-offset, both
  in PARAMS.  kernels/01-oscillators/wavetable.fy reads it.  LOAD on a
  waveform-display of it swaps the file while playing. )
: wavetable  ( name ptr-offset frames-offset file -- )
  over swap asset
  2 _mf-last-asset @64 AssetDesc.kind! drop
;

( Request a keymap: a .wav or .flac, a .sfz or a folder of them [relative to the
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
