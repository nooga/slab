# 46 — Autosave, crash recovery, logs and undo

What keeps work and evidence when something goes wrong.

Source: `src/recovery.zig` (autosave files), `Autosave` in `src/main.zig`
(the timer), `src/diag.zig` and `src/native_diag.c` (log and crash report),
`applyReusing` in `src/document.zig` (undo).

## Autosave and recovery

Every 30 seconds, while a project has unsaved changes (the `*` in the
title) and the mouse is not mid-drag, Slab writes the project to
`~/Library/Application Support/Slab/Recovery/<pid>.recovery`. That works
for the untitled project too. Saving, or quitting with nothing unsaved,
removes the file; a copy is only rewritten when the project changed.

At the next start with no project to open, Slab looks for recovery files
whose process is gone. It restores the newest one (the project keeps its
path, or stays untitled), marks it unsaved and says so in the status
line; the older ones are dropped, as are those more than two weeks old.
Quitting with unsaved changes also leaves its file, so the work comes
back even without a crash. Opening a project by double-click or from the
command line leaves any recovery file for a later start.

## Logs and crash reports

Everything Slab prints (warnings, errors, panic messages) goes to
`~/Library/Logs/Slab/slab.log` when Slab was not started from a terminal;
the previous run's log is `slab.log.1`. A fatal signal (a bad memory
access in JIT code, an illegal instruction, an abort from a panic) writes
`crash-<start time>.txt` there: Slab version, macOS version, the signal,
the fault address and a backtrace of the faulting thread. The newest five
are kept. macOS also writes its own report to
`~/Library/Logs/DiagnosticReports`.

To report a problem, send the `~/Library/Logs/Slab` folder (and the
project, if it can be shared). The status line after a restore names the
folder. `SLAB_LOGS` and `SLAB_RECOVERY` override both folders.

What else goes in `slab.log` for a report of drawing or freezes: `gl:` (GPU
and driver), `display:` (window points, framebuffer pixels, DPI, monitor; again
whenever one changes, as when the window moves to another display), `ui: draw
list peak` (how full the frame's command list gets; an overflow is an error),
and `ui: no frame for 5 s` when the UI thread stops drawing (a heartbeat on the
idle-wake thread), with `frames are back` when it recovers. Bounces and
freezes log their start like an export's phases.

## Undo and redo

Undo and redo restore the project from a snapshot. Tracks that the snapshot
leaves unchanged keep their live machines: only the tracks an edit touched
are built again (each machine is a fy compile, which used to make every ⌘Z
take seconds on a big project). The master chain is likewise kept when its
settings did not change. The selected track and clip stay selected where
they still exist. Undoing across a project switch (Open, New) rebuilds
everything, as before.

## Offline renders and the UI thread

An export, bounce or freeze owns the engine on a worker thread with the audio
device stopped. The UI thread never waits for it or for what it needs:

- Before a render starts, every source's transients and pitch must be done
  (the audio must not depend on how fast they were found). The UI polls
  `AudioPool.analysesPending` each frame: an export waits with "Analyzing
  sources…" on the status line and starts on the frame they finish; a bounce or
  freeze asks the user to try again.
- `Stall` watches the worker's progress. Thirty seconds without a new frame
  before the render's end logs "no progress ... the render is stuck" and says so
  on the status line. The worker cannot be killed (it is inside a machine), but
  the window stays usable and the project stays recoverable. Past the render's
  end the worker converts and writes files, which may be slow: not a stall.
- A quit cancels the worker and waits up to five seconds (`QUIT_WAIT_MS`). If
  it is still going, Slab writes the recovery file and exits without tearing
  down what the worker uses.
- A failed export setup clears its job, so the sheet is never left busy
  without a worker.

## Export phases

An export logs each phase to slab.log with the time since the last: the wait
for source analyses, the worker's start, the render at every tenth, the
render's end (frames done, cancelled or not), then per file the conversion,
the loudness measure and the write, and the audio device's restart. It also
notes how many stems are held in memory. A render that stops shows its last
line there.
