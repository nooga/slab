# 23 — Routing: buses, sends, sidechains, the mixer

Where a track's audio goes after its insert chain, and how one track's
signal reaches another's effect. It covers step 11 of
[17-direction.md](17-direction.md) (Track E). **Status: phases 1–3 built** (buses,
outputs, sends, the format, slabkit, the bus section, the mixer page,
sidechain keys) except the patch bay; phases 4–5 open. Supersedes the send/return sketch in
[07-transport.md §The graph](07-transport.md#the-graph) (the topological order
there becomes §Render order below). Code, as it lands: `src/routing.zig`
(the graph and its order), the routing fields in `track.zig`,
`engine.zig`, `document.zig`, the mixer in `src/ui/mixer.zig`.

Prior art: Live's return tracks and group tracks, Reaper's "every track
is a bus", an SSL console's normalled patch bay.

The acceptance test comes from docs/17: **snare → send → reverb on a
bus → gate keyed by the snare.** Glass Horizon's KIT track, rebuilt that
way, should sound like its GATED insert does today.

## Model

Three things route signal, and all of them sit on the Live-style graph
(docs/17 D9). None of them needs a node editor.

| | What it is | Signal |
|---|---|---|
| **Output** | where a track's post-fader signal goes: the master or one bus | the whole signal, serial |
| **Send** | a copy of a track's signal into a bus at a level, pre- or post-fader; the track still goes to its output | parallel |
| **Key** | an effect's sidechain input: another track's pre-fader signal drives its detector | control only; nothing is summed |

Racks (parallel chains inside one device) already exist as a machine
(`rack`) and are not routing.

### One bus kind

Returns and groups are the same thing to the engine: a track with no
instrument and no clips, whose input is a sum. A return is fed by sends,
and a group by other tracks' outputs. Slab has **one `bus` kind** that
takes both. `Track.Kind.ret` is renamed `bus`.

- A bus has an insert chain, a fader, pan, mute/solo, a meter, an
  output and sends, like any track. So a bus can feed another bus
  (nested groups, or a reverb return feeding a drum group).
- The UI names a bus by use: GROUP when outputs feed it, RETURN when
  only sends do. This is a label; nothing else changes.
- Groups are drawn above their members in the arrangement and fold;
  returns sit in a section of their own under the tracks (§Arrangement).

### Taps

A track's signal is read at two points:

| Tap | Where | Feeds |
|---|---|---|
| **pre** | after the insert chain, before volume and pan | pre-fader sends, keys |
| **post** | after volume and pan | the output, post-fader sends |

A send has no pan of its own. A post-fader send carries the track's pan;
a pre-fader send is the stereo pre tap as is.

## Semantics

**Mute** silences the track's output and its sends. A muted track still
renders when something keys from it, so a muted "ghost kick" track can
still duck the bass. A track that feeds nothing unmuted is skipped as
it is today.

**Solo** keeps a soloed track and everything **downstream** of it
audible: its output bus, the buses its sends reach, and so on down the
graph. Soloing the snare keeps the reverb return and the drum group
audible, which is what you want to hear. Soloing a bus keeps its sources
audible: everything **upstream** of it along outputs and sends. Keys
don't count here: soloing the bass doesn't un-mute the kick that ducks
it (the kick still renders for the key, as for mute).

**Cycles are refused at edit time.** An output, send or key that would
close a loop is not offered: the menu item or patch-bay cell is
disabled. This replaces docs/17's "one hears the other a block late".
Refusing is deterministic, renders the same offline and live, and
costs nothing. A true feedback path can come later as an explicit
"feedback send", one block late by design.

**Levels.** Send levels are dB, −inf..+6, stored as linear gain like
`volume` (0..2). Moving a send level ramps per sample across the block,
as the fader does (docs/22 §Track volume and pan).

## Render order

The graph is small (at most 32 nodes) and changes only when a routing
edit happens, so the UI thread computes the order and publishes it
(§Engine). A node's dependencies are:

- a bus depends on every track whose output or send reaches it;
- a track depends on every track any of its effects keys from.

The order is a topological sort of that graph (Kahn), ties broken by
track index, so an unrouted project renders in the same order as today.
The master is last and is not in the graph.

## Sidechain keys

*Built.* The manifest word `sidechain` sets the flag
(`Machine.takes_key`); the engine hands a keyed effect 4 `audio_in`
ports; `fy_raw_machine` fills `io.det` from the key pair. The KEY latch
sits in the effect's title strip in the bay (lit and naming the source
when set; the menu disables sources that would close a loop), the mixer
lists keyed inserts as `Comp ← KICK`, slabkit takes `fx(..., key=track)`
and refuses it on a machine without the flag. Tests: the engine test
with a muted key source, comp2 following its key's level, and verb2
GATED opening on the key and not its input. **Acceptance:** Glass
Horizon rebuilt with the kit sending to a verb2 bus keyed by the kit
renders the same gated envelope as the insert (hold, then a ~35 dB cut
within 20 ms), 2 dB hotter at a −9 dB send.

Every stereo-linked dynamics kernel already reads one detector lane,
`io.det` = max(|L|, |R|) of its input (`kernels/00-primitives/ctx.fy`):
`comp.fy`, `gate.fy`, `limiter.fy`. A key is the host filling `det` from
another signal:

- An effect whose manifest declares **`sidechain`** gets a KEY selector.
  The flag is opt-in because a key only means something to a
  detector-driven kernel.
- With a key set, the host writes `det` from the key track's pre tap
  instead of from the effect's own input. The kernel doesn't change.
- `ctx.audio_in` carries 4 ports then (in L, in R, key L, key R), so a
  native or future machine can read the key audio itself.
- No key: `det` is the input, bit for bit as now.

Machines that get the flag: **comp2**, **gate2**, **verb2**.

- verb2's GATED mode keys its gate from the dry input with `x fabs`
  (per channel). It moves to `io.det`: stereo-linked, so L and R open
  together, and sidechainable. On a bus, keyed by the snare, it is the
  acceptance test. GATED renders change slightly (a linked detector);
  the goldens get re-recorded after an A/B look. PLATE stays bit-exact.
- limiter2 doesn't get it: a keyed brickwall isn't a useful tool.

Later: a **note key**, a key made from a track's note-ons (a trigger
pulse) instead of its audio, so a MIDI kick pattern can duck without an
audible track. Not in this doc's phases.

## Latency

Tracks already disagree in latency today: limiter2's lookahead (2 ms at
its default), and whatever the 4x oversamplers in sat2 and the Moog
ladder add, which nobody has measured. With sends, the same signal
arrives at the master along paths of different latency, which smears
transients and combs parallel compression.

Plugin delay compensation follows docs/07 §PDC: machines declare
latency in their manifest, the host delays the shorter paths at each sum
(bus inputs and the master). It is its own phase (4) because it needs
the latency numbers first; the bench measures them (an impulse through
each effect, with the peak offset reported next to ns/smp).

## Engine

### Data

On `Track`, UI-owned, persisted:

| Field | |
|---|---|
| `kind` | `audio`, `bus` (master stays separate) |
| `output` | `null` = master, or a bus's track index |
| `sends[MAX_SENDS]` | `{ bus: u8, pre: bool, level: atomic f32 }`, `send_count`. `MAX_SENDS` = 8. |
| `Effect.key` | `null`, or a track index; only on effects with `sidechain` |

Track indices only move on a delete or a duplicate, and those remap
every `output`, `sends[].bus` and `key` (`Track.forgetTrack`,
`Track.makeRoomAt`), as automation remaps effect uids. Reordering, when
it lands, will do the same.

`MAX_TRACKS` goes from 16 to 32, counting buses. The cost is the
snapshots: a `TrackSnapshot` is ~400 KB (note and point arrays), two per
track, so ~26 MB of heap at 32. A bus doesn't need them, but trimming
that isn't worth a second track type yet.

### Publishing

A `Routing` snapshot, double-buffered on the `Engine` like track
snapshots: the render order, and per track its output, send targets
(bus, pre) and each effect's key. The UI rebuilds and flips it after any
routing edit. Send levels are atomics on the track and are not in the
snapshot, so dragging a send knob publishes nothing. Mute and solo stay
atomics too; the engine derives the audible set from them and the
snapshot's edges once per block (32 nodes, a few hundred ops).

### Buffers

Engine-owned, fixed, no allocation (512 KB at 32 tracks):

- `pre[MAX_TRACKS]` stereo, one block each: every track's pre tap, kept
  until the block ends so keys and pre sends can read it.
- `bus_in[MAX_TRACKS]` stereo accumulators, zeroed per block for buses
  only.

### Per block

```
zero bus_in of every bus, and master_l/r
audible = mute/solo propagated over the snapshot's edges
for track in routing.order:
    if not audible and nothing unmuted keys from it: skip
    src = bus ? bus_in[track] : instrument + audio clips
    effects in order; a keyed effect gets pre[key] as its key
    pre[track] = result
    post = pre × fader gains (ramped)
    if audible:
        dst(output) += post          (master_l/r or bus_in[output])
        for send: bus_in[send.bus] += (send.pre ? pre : post) × level (ramped)
    meter from post
finishMaster (unchanged)
```

Because the order is topological, every `bus_in` is complete before its
bus runs and every `pre[key]` is ready before its reader. The offline
render runs the same loop.

## Project format

Additions to docs/19's track, all optional (a project without them
loads as today):

```json
{"name": "KIT", "output": 11,
 "sends": [{"to": 10, "level": 0.5, "pre": false}],
 "effects": [{"machine": "comp2", "params": {}, "key": 1}]}
{"name": "SNARE VERB", "kind": "bus", "effects": [ … ]}
```

| Field | Meaning |
|---|---|
| `kind` | `"bus"`; missing = an audio track |
| `folded` | on a bus: its members are hidden in the arrangement and mixer (UI only) |
| `output` | index into `tracks` of a bus; missing = master |
| `sends` | `to` a bus's index, `level` linear gain (0..2, 1 = 0 dB), `pre` true for pre-fader |
| `effects[].key` | index into `tracks` whose pre tap keys this effect |

References to a non-bus, a missing track, or anything closing a cycle
are dropped on load, with a log line.

Automation: a send level is target `send<N>:level`, `N` the send's slot,
as `fx<N>` names an effect by position. Phase 5.

## slabkit

```python
verb = song.bus("SNARE VERB", fx=[fx("verb2", "gated-drum-room", mix=1.0, key=snare)])
drums = song.bus("DRUMS", fx=[fx("comp2", "drum-bus")])
snare = song.track("SNARE", "sampler", …, output=drums)
snare.send(verb, -6)            # dB; pre=True for pre-fader
bass.fx[1].key(kick)            # or key=kick in fx(...)
```

`output=` and `send` take a bus object; the builder writes indices.
`song.bus(..., folded=True)` saves a group folded.

## UI

### Mixer page

*Built* (`src/ui/mixer.zig`). **M** or the MIX latch (beside the
arrangement's `+`) swaps the arrangement for the mixer; the mixer also
takes the clip editor's room, and Tab still toggles the clip editor.
Strips for the tracks and groups on the left, in the arrangement's
display order (a group's strip before its members', each member with a
rail in the group's colour; folding a group from its title's triangle
hides its members here too); on the right, pinned like a console's
return section, the returns and then the master. Only the left
strips scroll: sideways with the wheel, or a thin bar under them once
they overflow. Every strip has the same rows, so they line up:

| Row | Control |
|---|---|
| title | colour bar, number or bus letter, name (scrolls while hovered when it doesn't fit). Click edits the strip in the bay; right-click is the routing menu |
| inserts | the chain's machine names, bypassed ones dimmed, `+N more` past four; a name too long for the display scrolls |
| sends | a small knob per return, lettered (A, B, …), two to a row (sends to a group are made from the menu). Half travel is 0 dB, full +6 dB. Turning one up from nothing creates the send (an undo step); right-click an existing one for pre/post and remove. A bus that would feed back is disabled |
| output | `→ MASTER` or a bus; click for the output list |
| pan | bipolar knob at full size; BAL on the master |
| fader | volume with the stereo meter and its scale beside it, dB readout below |
| buttons | M, S, and R on audio tracks |

Strips are fixed width (84 px). The machine bay below follows the
selected strip. `+ TRACK` and `+ BUS` in the mixer's header add strips;
the arrangement has `+` and, under it and MIX, `+ BUS`.

### Deleting a track

The name's right-click menu (a header or a strip title) ends with
*Delete track* / *Delete bus*. An empty one goes at once; one with
clips, machines, automation lanes, or anything routed into it asks
first, saying what it holds. Every output, send and key that pointed
at it goes (an output falls back to the master), the tracks above it
move down one, and the whole thing is one undo step. Refused while
recording.
Level, pan, mute and solo moves aren't undo steps, as in the arrangement
headers; creating, removing or retapping a send is.

### Patch bay

A second page of the mixer (a `BAY` latch in its header): the routing
as a normalled jack field, for the connections a strip has no room to
show at once.

- **Rows** are sources: each track's POST and PRE taps.
- **Columns** are destinations: each bus's input, then each
  sidechain-capable effect's KEY, grouped under its track.
- A cell is a jack. **Normals** (every POST to the master) aren't
  drawn as cables; patching a POST into a bus moves its output there,
  which breaks the normal. A POST or PRE into a bus beyond the output
  is a send at 0 dB (its level on the strip). A PRE into a KEY sets the
  key, one source per KEY column.
- Patched cells are lit in the accent, which here means active. Cells
  that would close a cycle are drawn dead and don't take a click.

The bay edits the same fields as the strips. It's an index of what's
connected, not a second model, and it doesn't draw a free graph.

### Arrangement

*Built.* Rows are drawn in a display order, not index order. Indices
never move, so routing references stay valid; only where a row is
drawn does.

- **Groups** sit among the tracks. A bus is a *group* when some
  track's output goes to it (a *return* when only sends feed it, as
  §One bus kind names them). A group is drawn above its members, at
  the place of its first member, and its members follow it in index
  order, each with a rail in the group's colour. A group whose output is
  another group nests inside it, one rail per level.
- **Returns** follow in a section of their own under a RETURNS divider,
  above the pinned master strip.
- **Folding.** A group's header has a fold triangle. A folded group
  hides its members' rows (in the mixer too) but keeps playing them;
  its lane shows every member's clips as silhouettes in their
  colours, folded or not. The fold state is saved (`"folded": true`).
- Audio tracks are numbered 1, 2, … in display order, folded ones
  included, so the numbers don't jump as groups fold; buses are
  lettered A, B, … in index order, as Live letters its returns.
- A bus header has the same minis as a track (volume, pan, M/S, meter,
  A for lanes) and no arm latch.
- A bus lane is a flat dark well with bar lines (for its automation
  lanes) and names what feeds it: `← KIT · BASS (send)`.
- Clips never land on a bus: creation, import and paste refuse, and
  clip drags and pastes move by the visible audio rows, skipping group
  and return rows.
- The overview strip shows audio tracks only, folded ones included.
- *Output ▸ New bus* on a track names the new bus GROUP 1, 2, …; the
  mixer's and the arrangement's `+ BUS` make BUS 1, 2, ….

Routing a track into a bus is what makes the group, so grouping needs
no track reordering. Reordering by drag is still to come.

### Duplicating a track

*Duplicate track* / *Duplicate bus* in the name menu puts a copy right
under the original: clips, instrument, effects, automation, output and
sends, named `KIT 2` (the next free number). The tracks above move up
one and every reference is renumbered, so nothing else's routing
changes; keys that listened to the original keep listening to it. A
bus is copied alone (a copied group gets no members, so it shows as a
return until something is routed into it). One undo step.

## Phasing

1. **Engine: buses, outputs, sends.** `Kind.bus`, the routing snapshot
   and order, cycle checks, mute/solo propagation, per-track pre taps
   and bus accumulators, `MAX_TRACKS` 32, the project format, slabkit,
   engine tests (a send renders as the sum of its dry and wet paths; a
   group equals the sum of its members through the group's chain;
   unrouted projects render bit-exact). A minimal UI to create a bus and
   set outputs and sends from the track header menu. *Built: right-click
   a header's name for Output ▸ and Sends ▸ (each with New bus); sends
   made there are post-fader at 0 dB; levels and PRE wait for the mixer.
   Buses are ordinary rows until then and refuse new clips.*
2. **Mixer page.** Strips, send knobs, output selectors, M. *Built.*
3. **Keys.** The `sidechain` manifest flag, `det` from the key, 4-port
   `audio_in`, verb2 on `io.det`, the KEY selector in the effect title
   strip, the patch bay page. **Exit: the gated snare works end to
   end** in Glass Horizon. *Built but the patch bay; the exit holds.*
4. **PDC.** Latency in manifests, measured on the bench, delay at sums.
5. **Later.** Send-level automation, track reordering by drag, note keys, a channel-strip machine
   (HPF → gate → EQ → comp → sat, docs/17 Track E), feedback sends.
