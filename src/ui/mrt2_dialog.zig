//! Render with MRT2 (docs/42 §The dialog): the prompt and seed a pattern
//! clip's notes are played with. A `dialog` (modal; main suppresses the
//! input behind it while `active`). While the render runs it shows the
//! renderer's progress and CANCEL.

const std = @import("std");
const core = @import("core.zig");
const style = @import("style.zig");
const dialog = @import("dialog.zig");
const text_field = @import("text_field.zig");

const Ui = core.Ui;
const Rect = core.Rect;

pub const State = struct {
    active: bool = false,
    prompt: text_field.TextBuf = text_field.TextBuf.init("solo grand piano, warm, expressive", 96),
    seed: text_field.TextBuf = text_field.TextBuf.init("0", 9),
    /// The MRT2 pack is installed.
    have_pack: bool = false,
    busy: bool = false,
    /// The renderer's last line while busy.
    line: []const u8 = "",
    /// A field had focus last frame: Enter and Esc are the field's.
    editing: bool = false,

    pub fn seedValue(self: *const State) ?u32 {
        return std.fmt.parseInt(u32, std.mem.trim(u8, self.seed.text(), " "), 10) catch null;
    }

    fn ready(self: *const State) bool {
        return self.have_pack and self.seedValue() != null and std.mem.trim(u8, self.prompt.text(), " ").len > 0;
    }
};

pub const Result = enum { none, cancel, go };

const W: i32 = 440;
const H: i32 = 176;
const ROW_H: i32 = 20;
const LABEL_W: i32 = 64;

pub fn draw(ui: *Ui, screen: Rect, state: *State, clip_name: []const u8) Result {
    if (!state.active) return .none;
    const f = dialog.begin(ui, screen, "mrt2-dialog", "RENDER WITH MRT2", W, H);
    defer dialog.end(ui);
    var name_buf: [40]u8 = undefined;
    ui.textIn(&ui.fonts.legend, f.title, std.ascii.upperString(&name_buf, clip_name[0..@min(clip_name.len, name_buf.len)]), style.text_dim, .right, false);
    var body = f.body;
    if (state.busy) {
        _ = body.cutTop(30);
        dialog.section(ui, &body, "RENDERING");
        var lb: [96]u8 = undefined;
        dialog.hint(ui, &body, std.ascii.upperString(&lb, state.line[0..@min(state.line.len, lb.len)]), 8);
        if (dialog.buttons(ui, f.buttons, &.{"CANCEL"}, null) != null or f.escape) return .cancel;
        return .none;
    }

    const editing = state.editing;
    state.editing = false;
    const h = ROW_H - 2;
    {
        const r = dialog.rowW(ui, &body, "PROMPT", ROW_H, LABEL_W);
        _ = text_field.field(ui, Rect.xywh(r.x, r.y + 1, r.w - 8, h), "prompt", &state.prompt, .{});
        if (ui.focus == ui.id("prompt")) state.editing = true;
    }
    {
        const r = dialog.rowW(ui, &body, "SEED", ROW_H, LABEL_W);
        _ = text_field.field(ui, Rect.xywh(r.x, r.y + 1, 80, h), "seed", &state.seed, .{});
        if (ui.focus == ui.id("seed")) state.editing = true;
        ui.textIn(&ui.fonts.legend, Rect.xywh(r.x + 88, r.y, r.w - 88, r.h), "SAME NOTES, PROMPT AND SEED: THE SAME AUDIO", style.text_mute, .left, false);
    }
    _ = body.cutTop(6);
    dialog.hint(ui, &body, if (state.have_pack) "A NEW TRACK UNDER THE CLIP, 48 KHZ STEREO" else "NEEDS THE MRT2 PACK (BROWSER, PACKS)", 0);

    if (dialog.buttons(ui, f.buttons, &.{ "CANCEL", "RENDER" }, 1)) |i| return if (i == 0) .cancel else if (state.ready()) .go else .none;
    if (editing) return .none;
    if (f.escape) return .cancel;
    if (f.enter and state.ready()) return .go;
    return .none;
}
