//! Explode (docs/30 §Explode): what to take out of an audio clip. A
//! `dialog` (modal; main suppresses the input behind it while `active`).
//! With the Extract pack the song is split into stems first and each part
//! comes from its stem; without it, from the clip itself.

const std = @import("std");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const dialog = @import("dialog.zig");

const Ui = core.Ui;
const Rect = core.Rect;

pub const State = struct {
    active: bool = false,
    stems: bool = true,
    drums: bool = true,
    bass: bool = true,
    chords: bool = true,
    melody: bool = true,
    /// The Extract pack is installed (stems can be made).
    have_pack: bool = false,
    /// While stems are made: segments done of all.
    done: u32 = 0,
    total: u32 = 0,
    busy: bool = false,

    pub fn split(self: State) bool {
        return self.stems and self.have_pack;
    }

    pub fn any(self: State) bool {
        return self.split() or self.drums or (self.bass and self.split()) or self.chords or self.melody;
    }
};

pub const Result = enum { none, cancel, go };

const W: i32 = 420;
const H: i32 = 236;
const ROW_H: i32 = 20;

const Row = struct { label: []const u8, field: []const u8, with_stems: []const u8, without: []const u8 };
const ROWS = [_]Row{
    .{ .label = "STEMS", .field = "stems", .with_stems = "DRUMS, BASS, OTHER, VOCALS ON FOUR TRACKS", .without = "NEEDS THE EXTRACT PACK (BROWSER, PACKS)" },
    .{ .label = "DRUMS", .field = "drums", .with_stems = "A SAMPLER KIT AND A PATTERN, FROM THE DRUM STEM", .without = "A SAMPLER KIT AND A PATTERN, FROM ITS HITS" },
    .{ .label = "BASS", .field = "bass", .with_stems = "THE BASSLINE AS NOTES, FROM THE BASS STEM", .without = "NEEDS STEMS: WITHOUT THEM A CLIP HAS ONE LINE" },
    .{ .label = "CHORDS", .field = "chords", .with_stems = "THE CHORDS ON A PAD, FROM BASS AND OTHER", .without = "THE CHORDS ON A PAD" },
    .{ .label = "MELODY", .field = "melody", .with_stems = "THE SUNG LINE AS NOTES, FROM THE VOCALS", .without = "ITS LINE AS NOTES" },
};

pub fn draw(ui: *Ui, screen: Rect, state: *State, clip_name: []const u8) Result {
    if (!state.active) return .none;
    const f = dialog.begin(ui, screen, "explode-dialog", "EXPLODE", W, H);
    defer dialog.end(ui);
    var name_buf: [40]u8 = undefined;
    ui.textIn(&ui.fonts.legend, f.title, std.ascii.upperString(&name_buf, clip_name[0..@min(clip_name.len, name_buf.len)]), style.text_dim, .right, false);
    var body = f.body;
    if (state.busy) {
        _ = body.cutTop(30);
        dialog.section(ui, &body, "SPLITTING INTO STEMS");
        const bar = body.cutTop(12).insetXY(8, 0);
        const frac: f32 = if (state.total > 0) @as(f32, @floatFromInt(state.done)) / @as(f32, @floatFromInt(state.total)) else 0;
        ui.rect(bar, style.well);
        ui.rect(Rect.xywh(bar.x, bar.y, @intFromFloat(@as(f32, @floatFromInt(bar.w)) * frac), bar.h), style.vfd);
        _ = body.cutTop(8);
        var pb: [48]u8 = undefined;
        dialog.hint(ui, &body, std.fmt.bufPrint(&pb, "SEGMENT {d} OF {d}", .{ state.done, state.total }) catch "", 8);
        if (dialog.buttons(ui, f.buttons, &.{"CANCEL"}, null) != null or f.escape) return .cancel;
        return .none;
    }
    dialog.section(ui, &body, "TAKE OUT");
    const split = state.split();
    inline for (ROWS) |row| {
        var r = dialog.rowW(ui, &body, row.label, ROW_H, 64);
        const v = &@field(state, row.field);
        const is_stems = comptime std.mem.eql(u8, row.field, "stems");
        const needs_stems = comptime std.mem.eql(u8, row.field, "bass");
        const disabled = (is_stems and !state.have_pack) or (needs_stems and !split);
        var on = v.* and !disabled;
        if (ctl.ledToggle(ui, r.cutLeft(16).center(12, 12), row.field, &on, disabled)) v.* = on;
        _ = r.cutLeft(6);
        const about = if (split) row.with_stems else row.without;
        ui.textIn(&ui.fonts.legend, r, about, if (disabled) style.text_mute else style.text_dim, .left, false);
    }
    _ = body.cutTop(4);
    dialog.hint(ui, &body, if (split) "EVERYTHING LANDS UNDER THE CLIP; THE CLIP IS MUTED" else "EVERYTHING LANDS UNDER THE CLIP", 0);
    if (dialog.buttons(ui, f.buttons, &.{ "CANCEL", "EXPLODE" }, 1)) |i| return if (i == 0) .cancel else if (state.any()) .go else .none;
    if (f.escape) return .cancel;
    if (f.enter and state.any()) return .go;
    return .none;
}
