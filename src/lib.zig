//! fy library entry point.
//!
//! Re-exports the fy runtime as a Zig module so embedders (slab) can
//! `@import("fy").Fy` and call the runtime directly — no C-ABI, no
//! opaque handles, no error-code translation.

const main = @import("main.zig");

pub const Fy = main.Fy;

test {
    _ = @import("tests.zig");
    _ = @import("asm.zig");
}
