//! FyMachine — thin shim that bridges fy's audio and UI callbacks into
//! Slab's Machine vtable.  Both fn pointers are atomic for hot-patch.

const std = @import("std");
const c = @import("../c.zig");
const Fy = @import("fy").Fy;
const machine = @import("../machine.zig");
const fy_host_mod = @import("../fy_host.zig");
const FyHost = fy_host_mod.FyHost;
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");

pub const FyMachine = struct {
    host: *FyHost,
    render_fn: std.atomic.Value(?*const fn () callconv(.c) void),
    ui_fn: std.atomic.Value(?*const fn () callconv(.c) void),
    name_buf: [64]u8,
    name_len: usize,
    panel_w: f32 = 108,

    pub fn init(
        host: *FyHost,
        name: []const u8,
        audio_cb: *const fn () callconv(.c) void,
        ui_cb: ?*const fn () callconv(.c) void,
    ) FyMachine {
        var m = FyMachine{
            .host = host,
            .render_fn = std.atomic.Value(?*const fn () callconv(.c) void).init(audio_cb),
            .ui_fn = std.atomic.Value(?*const fn () callconv(.c) void).init(ui_cb),
            .name_buf = undefined,
            .name_len = 0,
        };
        const n = @min(name.len, 63);
        @memcpy(m.name_buf[0..n], name[0..n]);
        m.name_len = n;
        return m;
    }

    pub fn swapAudioCallback(self: *FyMachine, cb: *const fn () callconv(.c) void) void {
        self.render_fn.store(cb, .release);
    }

    pub fn swapUiCallback(self: *FyMachine, cb: ?*const fn () callconv(.c) void) void {
        self.ui_fn.store(cb, .release);
    }

    pub fn machineInterface(self: *FyMachine) machine.Machine {
        return .{
            .name = self.name_buf[0..self.name_len],
            .state = self,
            .render = renderImpl,
            .draw_panel = drawPanelImpl,
            .reset = resetImpl,
            .panel_w = self.panel_w,
        };
    }
};

fn renderImpl(
    state: *anyopaque,
    ctx: *const machine.MachineCtx,
    l: []f32,
    r: []f32,
) void {
    const self: *FyMachine = @ptrCast(@alignCast(state));
    const cb = self.render_fn.load(.acquire) orelse return;
    Fy.Builtins.fyPtr = @intFromPtr(&self.host.fy);
    FyHost.setCtx(ctx);
    FyHost.setAudioBuffers(l.ptr, r.ptr);
    cb();
    FyHost.clearCtx();
    FyHost.clearAudioBuffers();
}

fn drawPanelImpl(state: *anyopaque, r: c.rl.Rectangle, m: widgets.Mouse) void {
    const self: *FyMachine = @ptrCast(@alignCast(state));
    Fy.Builtins.fyPtr = @intFromPtr(&self.host.fy);
    FyHost.setUiContext(r, m);
    defer FyHost.clearUiContext();

    const cb = self.ui_fn.load(.acquire) orelse {
        // Fallback: plain label.
        c.rl.DrawRectangleRec(r, theme.pane_alt);
        widgets.drawLabelF("FY SINE", r.x + 4, r.y + 4, theme.fsTiny(), theme.text_mute);
        return;
    };
    cb();
}

fn resetImpl(state: *anyopaque) void {
    _ = state;
}
