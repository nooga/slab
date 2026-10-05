# 34 — Production wishlist

Prioritize changes that make composing, balancing and exporting more
dependable. These are proposals informed by the Afterimage Express
production session and checked against the 0.0.9 source. They are not
claims that a feature is broken or a committed release schedule.

The session used slabkit, native instruments and effects, offline stems,
measurements and limited desktop inspection. It did not establish
subjective instrument fidelity through a reliable listening pass.

## Existing capabilities to use first

Slab already has GEQ with eight configurable bands, a spectrum display
and −12..+12 dB trim; buses, sends, sidechains and delay compensation;
track and clip automation; note expression; and combined mix/stem CLI
export. The session used eq2 and missed GEQ. The corresponding need is
better discovery and evaluation, not another EQ.

The composing guide now demonstrates these tools. Current formats and
limits belong in [19-project-format.md](19-project-format.md); detailed
production practice belongs in [21-production-guide.md](21-production-guide.md).
Avoid turning historical design plans into competing feature inventories.

## First priorities

### Make export peak readings agree

**Observation:** on the same final session WAV, Slab reported −1.8 dBTP
and FFmpeg's `loudnorm` input measurement reported −1.23 dBTP. Integrated
loudness was approximately −13.3 LUFS in both. This is a reproducible
session observation, not yet an isolated meter defect or a general
accuracy claim. The final sample peak was −3.0 dBFS.

**Proposal:** compare both implementations on controlled near-Nyquist
signals, transients and representative mixes. Document interpolation,
channel aggregation, padding and measurement tolerances. Distinguish
the limiter's sample ceiling from the export meter's true-peak estimate.
Consider an explicitly verified true-peak limiting mode after resolving
the measurement difference.

**Acceptance:** fixtures have stated expected values and tolerances;
export UI and CLI identify sample versus true peak; a promised true-peak
ceiling holds on the same fixtures at supported export rates. A fix
should explain the observed discrepancy rather than just change a label.

### Keep stems from the Python render helper

**Current behavior:** `Song.render(stems=True)` bounces the mix, runs a
second bounce for stem analysis, and removes the temporary stems. The
CLI can already write mix and stems in one pass.

**Proposal:** let callers specify a persistent stem directory and reuse
the combined CLI path. Return the file paths alongside analysis and make
replacement behavior explicit.

**Acceptance:** a caller receives one master and aligned retained stems
from one render, with the chosen tap and track/bus selection. Analysis
does not remove caller-owned files. Existing report-only use remains
clearly documented.

### Help users compare patches at matched loudness

**Observation:** the session needed large level corrections between its
programmed hats, arp and FM parts. The measurements included different
notes, durations, velocities and processing, so they do not prove a
factory preset calibration problem or poor instrument quality.

**Proposal:** provide optional level-matched preset audition with a
repeatable phrase and velocity, and make instrument output controls and
GEQ trim easy to find. Review factory presets by role using sustained,
transient and polyphonic phrases. Preserve intentional dynamics and
character rather than normalizing every sound destructively.

**Acceptance:** switching presets can compare timbre at similar perceived
level without silently changing the saved patch. Users can see and reset
any audition compensation. Document how input level affects nonlinear
processing; a louder patch must not win merely by being louder.

## Workflow improvements

### Preserve edits between Python and the arrangement

`Song.save()` overwrites a generated project's document. Saving UI work
under a second name prevents loss but leaves reconciliation manual.
Consider loading existing projects into slabkit or applying edits to
selected tracks/clips while preserving untouched fields and assets.

**Acceptance:** a project with UI-edited automation, routing, presets and
asset references survives a no-op round trip; a targeted note edit
changes only the intended content. Unsupported fields produce an
explicit outcome rather than disappearing silently.

### Make the initial arrangement useful at smaller sizes

In the session's initial 1400 by 860 content area, an empty piano roll
left room for only about three instrument rows below the drum bus.
Consider fitting the song on first open and collapsing unused editors,
while respecting a saved layout and a selected clip.

**Acceptance:** a new multi-track project opens with useful section and
track context at that size; reopening a deliberately saved layout does
not discard the user's choice. Verify through hands-on interaction.

### Expose stable controls for accessible editing

The available accessibility tree exposed the window and menus but not
tracks, clips, transport or machine controls. Coordinate and keyboard
automation was unreliable in that session; this alone does not establish
a Slab input bug.

Consider semantic accessibility controls, or a documented local control
interface with readable state and undoable actions. Prioritize transport,
selection, parameter edits and saving before comprehensive automation.

**Acceptance:** a client can identify a track and parameter, read its
value and units, set it, verify the result and undo the action without
screen coordinates. Recording and saving failures remain visible to the
user. Test accessible operation independently of one automation tool.

### Keep feature status close to its implementation

The corrected docs had described a pre-code project, 16 tracks, no sends
and no clip automation. Keep dated design milestones, but route new
readers to current release notes, reference docs and runnable examples.

**Acceptance:** documented examples validate against live manifests,
referenced limits match source constants, and guide links resolve. When
behavior changes, update the affected guide in the same change. Avoid
regenerating machine tables by hand.

## Evaluate instrument sound before prescribing DSP changes

Use level-matched listening tests with the same phrase, register,
velocity, voice count and effects state. Include exposed releases,
resonance sweeps, high notes, bass notes, dense chords, mono playback
and the same patches inside a mix. Compare dry and processed versions.

Record audible findings precisely: which machine and patch, the notes
and settings, what sounds wrong, and a short render that reproduces it.
Follow listening with technical checks for aliasing, discontinuities,
voice stealing or unintended level shifts where the evidence points.
Do not infer that an instrument needs replacement from a quiet stem or
from a spectrum alone.

The existing palette was broad enough to complete a substantial native
electronic arrangement. Better feedback and a reliable audition loop
would make the next decisions about sound quality more useful than an
unqualified request for more synths.
