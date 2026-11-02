//! The update card (docs/47): what the release brings and the one button
//! that fits where Slab is installed. A chip at the screen's corner opens
//! it while an update is waiting; About's UPDATES button opens it to
//! check. A `dialog` (modal; main suppresses the input behind it while
//! `active`).

const std = @import("std");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const dialog = @import("dialog.zig");
const updater_mod = @import("../updater.zig");

const Ui = core.Ui;
const Rect = core.Rect;

pub const State = struct {
    active: bool = false,
};

pub const Result = enum { none, close, skip, download, restart, page, check, never };

const W: i32 = 400;
const H: i32 = 220;
const NOTE_LINES = 9;
const CHIP_W: i32 = 168;
const CHIP_H: i32 = 20;

/// The corner chip while an update waits. True when clicked.
pub fn chip(ui: *Ui, screen: Rect, u: *const updater_mod.Updater) bool {
    if (!u.pending()) return false;
    var lb: [48]u8 = undefined;
    const label = std.fmt.bufPrint(&lb, "UPDATE {s}", .{u.tagName()}) catch "UPDATE";
    const r = Rect.xywh(screen.right() - CHIP_W - 8, screen.bottom() - CHIP_H - 8, CHIP_W, CHIP_H);
    var lit = true;
    return ctl.button(ui, r, "update-chip", &lit, .{ .label = label, .lit = style.play });
}

pub fn draw(ui: *Ui, screen: Rect, st: *State, u: *const updater_mod.Updater, check_at_launch: *bool) Result {
    if (!st.active) return .none;
    const f = dialog.begin(ui, screen, "update-dialog", "UPDATE", W, H);
    defer dialog.end(ui);
    var body = f.body;
    var res: Result = .none;
    const state = u.get();
    var tb: [64]u8 = undefined;
    const mine = @import("build_options").version;
    var labels: []const []const u8 = &.{"CLOSE"};
    var default: ?usize = 0;
    switch (state) {
        .idle, .checking => {
            dialog.section(ui, &body, "CHECKING");
            dialog.hint(ui, &body, "ASKING GITHUB FOR THE LATEST RELEASE", 0);
        },
        .current => {
            dialog.section(ui, &body, "UP TO DATE");
            dialog.hint(ui, &body, std.fmt.bufPrint(&tb, "SLAB {s} IS THE LATEST RELEASE", .{mine}) catch "", 0);
        },
        .failed => {
            dialog.section(ui, &body, if (u.fail_in_check) "COULDN'T CHECK" else "UPDATE FAILED");
            dialog.hint(ui, &body, u.errorText(), 0);
            labels = &.{ "CLOSE", "RELEASE PAGE" };
            default = 1;
        },
        .available, .downloading, .ready => {
            dialog.section(ui, &body, std.fmt.bufPrint(&tb, "SLAB {s} IS OUT  (YOU HAVE {s})", .{ std.mem.trimStart(u8, u.tagName(), "v"), mine }) catch "NEW VERSION");
            notes(ui, &body, u.notesText());
            switch (state) {
                .downloading => {
                    labels = &.{"HIDE"};
                    dialog.hint(ui, &body, "DOWNLOADING AND CHECKING THE RELEASE", 0);
                },
                .ready => {
                    labels = &.{ "LATER", "RESTART NOW" };
                    default = 1;
                },
                else => switch (u.mode) {
                    .install => {
                        labels = &.{ "SKIP", "LATER", "UPDATE" };
                        default = 2;
                    },
                    .brew => {
                        labels = &.{ "SKIP", "LATER", "RELEASE PAGE" };
                        default = 1;
                        dialog.hint(ui, &body, "INSTALLED WITH HOMEBREW: brew upgrade --cask slab", 0);
                    },
                    .page => {
                        labels = &.{ "SKIP", "LATER", "RELEASE PAGE" };
                        default = 2;
                    },
                },
            }
        },
    }
    // The launch check's switch.
    const sw = body.cutBottom(16);
    var on = check_at_launch.*;
    var row = sw;
    if (ctl.ledToggle(ui, row.cutLeft(16).center(12, 12), "check-at-launch", &on, false)) {
        check_at_launch.* = on;
        res = .never;
    }
    _ = row.cutLeft(6);
    ui.textIn(&ui.fonts.legend, row, "CHECK FOR UPDATES WHEN SLAB STARTS", style.text_dim, .left, false);

    if (dialog.buttons(ui, f.buttons, labels, default)) |i| res = pick(state, u.mode, labels[i]);
    if (f.escape) res = .close;
    if (f.enter and res == .none) if (default) |d| {
        res = pick(state, u.mode, labels[d]);
    };
    if (res == .close or res == .skip or res == .page or res == .restart) st.active = false;
    return res;
}

fn pick(state: updater_mod.State, mode: updater_mod.Mode, label: []const u8) Result {
    _ = state;
    _ = mode;
    if (std.mem.eql(u8, label, "SKIP")) return .skip;
    if (std.mem.eql(u8, label, "UPDATE")) return .download;
    if (std.mem.eql(u8, label, "RESTART NOW")) return .restart;
    if (std.mem.eql(u8, label, "RELEASE PAGE")) return .page;
    return .close;
}

/// The release notes' first lines, clipped to the card.
fn notes(ui: *Ui, body: *Rect, text: []const u8) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        if (n == NOTE_LINES) {
            ui.textIn(&ui.fonts.legend, body.cutTop(12), "...", style.text_mute, .left, true);
            break;
        }
        ui.textIn(&ui.fonts.legend, body.cutTop(12), line, style.text_dim, .left, true);
        n += 1;
    }
    _ = body.cutTop(4);
}
