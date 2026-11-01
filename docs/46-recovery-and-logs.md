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

## Undo and redo

Undo and redo restore the project from a snapshot. Tracks that the snapshot
leaves unchanged keep their live machines: only the tracks an edit touched
are built again (each machine is a fy compile, which used to make every ⌘Z
take seconds on a big project). The master chain is likewise kept when its
settings did not change. The selected track and clip stay selected where
they still exist. Undoing across a project switch (Open, New) rebuilds
everything, as before.
