//! Frozen clip/note data published by the UI thread and consumed
//! read-only by the audio thread.
//!
//! Double-buffer invariant: the UI writes to the *non-published* slot,
//! then flips the atomic index with Release ordering. The audio thread
//! reads the *published* slot with Acquire ordering and holds the pointer
//! for the duration of one renderChunk call — never across a UI publish
//! cycle. Two buffers (not three) is sufficient because miniaudio's
//! callback fires at ~1.3ms intervals while the UI publishes at ~60Hz,
//! giving the audio thread well over one block of headroom.

pub const MAX_CLIPS_PER_TRACK: usize = 64;
pub const MAX_NOTES_PER_TRACK: usize = 2048;
pub const MAX_AUDIO_CLIPS_PER_TRACK: usize = 64;

pub const NoteSnap = struct {
    start_beat: f64,
    length_beats: f64,
    pitch: u8,
    velocity: u8,
};

pub const ClipHeader = struct {
    start_beat: f64,
    length_beats: f64,
    notes_start: u32,
    notes_count: u32,
};

/// A placed audio clip, frozen for the audio thread. `data`/`len` point at
/// the pool source's decoded f64 mono buffer — valid because pool sources
/// are never freed mid-session. `data` is null when the source went
/// missing (skipped on playback).
pub const AudioClipSnap = struct {
    start_beat: f64,
    length_beats: f64,
    data: ?[*]const f64 = null,
    len: u32 = 0,
    source_rate: f64 = 0,
    /// First source sample this clip reads (= start_sec * source_rate).
    start_sample: f64 = 0,
    /// Played window length and fade lengths, in source samples.
    dur_samples: f64 = 0,
    fade_in_samples: f64 = 0,
    fade_out_samples: f64 = 0,
    gain: f32 = 1.0,
};

pub const TrackSnapshot = struct {
    clips: [MAX_CLIPS_PER_TRACK]ClipHeader = undefined,
    clip_count: u32 = 0,
    notes: [MAX_NOTES_PER_TRACK]NoteSnap = undefined,
    note_count: u32 = 0,
    audio_clips: [MAX_AUDIO_CLIPS_PER_TRACK]AudioClipSnap = undefined,
    audio_clip_count: u32 = 0,
};
