//! Render workers (docs/07 §Parallel rendering): threads that help the
//! audio thread render a block's ready nodes. Each block the audio thread
//! wakes up to one worker per node it could hand out (`begin`), renders
//! and mixes alongside them, and closes the block (`end`) once every node
//! is mixed, waiting only for workers still inside it.
//!
//! Real-time rules: waking is a Mach semaphore signal and nothing here
//! allocates or locks. A worker woken late (descheduled, or a stale signal)
//! finds the block closed and goes back to sleep; the audio thread renders
//! whatever no worker took, so a missing worker costs time, never output.

const std = @import("std");

extern "c" var mach_task_self_: u32;
extern "c" fn semaphore_create(task: u32, sem: *u32, policy: c_int, value: c_int) c_int;
extern "c" fn semaphore_destroy(task: u32, sem: u32) c_int;
extern "c" fn semaphore_signal(sem: u32) c_int;
extern "c" fn semaphore_wait(sem: u32) c_int;
extern "c" fn pthread_set_qos_class_self_np(qos: c_uint, relative: c_int) c_int;
extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;
const QOS_CLASS_USER_INTERACTIVE: c_uint = 0x21;
const SYNC_POLICY_FIFO: c_int = 0;

pub const MAX_WORKERS = 7;

/// This thread's render slot: 0 on the audio thread (and any other that
/// renders), 1… on the workers. For per-thread load (Engine.thread_busy).
pub threadlocal var slot: usize = 0;

/// Workers to run by default: one fewer than the performance cores (the
/// audio thread is the other), at most MAX_WORKERS.
pub fn defaultWorkers() usize {
    var n: c_int = 0;
    var len: usize = @sizeOf(c_int);
    const cores: usize = if (sysctlbyname("hw.perflevel0.logicalcpu", &n, &len, null, 0) == 0 and n > 0)
        @intCast(n)
    else
        std.Thread.getCpuCount() catch 1;
    return @min(cores -| 1, MAX_WORKERS);
}

/// A pool running `work(ctx, scratch)` until the block closes; `work`
/// returns false when it found nothing to do. `Scratch` lives on each
/// worker's stack.
pub fn Pool(comptime Ctx: type, comptime Scratch: type, comptime work: fn (*Ctx, *Scratch) bool) type {
    return struct {
        const Self = @This();

        threads: [MAX_WORKERS]std.Thread = undefined,
        n: usize = 0,
        sem: u32 = 0,
        ctx: *Ctx,
        /// A block is open: workers may take its nodes.
        active: std.atomic.Value(bool) = .init(false),
        /// Workers inside a block, which `end` waits out.
        inflight: std.atomic.Value(u32) = .init(0),
        quit: std.atomic.Value(bool) = .init(false),

        pub fn create(alloc: std.mem.Allocator, ctx: *Ctx, workers: usize) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);
            self.* = .{ .ctx = ctx };
            if (semaphore_create(mach_task_self_, &self.sem, SYNC_POLICY_FIFO, 0) != 0) return error.SemaphoreCreate;
            errdefer _ = semaphore_destroy(mach_task_self_, self.sem);
            const n = @min(workers, MAX_WORKERS);
            errdefer self.stopWorkers();
            while (self.n < n) : (self.n += 1) {
                self.threads[self.n] = try std.Thread.spawn(.{}, run, .{ self, self.n + 1 });
            }
            return self;
        }

        pub fn destroy(self: *Self, alloc: std.mem.Allocator) void {
            self.stopWorkers();
            _ = semaphore_destroy(mach_task_self_, self.sem);
            alloc.destroy(self);
        }

        fn stopWorkers(self: *Self) void {
            self.quit.store(true, .seq_cst);
            for (0..self.n) |_| _ = semaphore_signal(self.sem);
            for (self.threads[0..self.n]) |t| t.join();
            self.n = 0;
        }

        /// Open a block with `nodes` nodes and wake up to nodes - 1
        /// workers. False when none were woken: no `end` needed.
        pub fn begin(self: *Self, nodes: usize) bool {
            const k = @min(self.n, nodes -| 1);
            if (k == 0) return false;
            self.active.store(true, .seq_cst);
            for (0..k) |_| _ = semaphore_signal(self.sem);
            return true;
        }

        /// Close the block (all its nodes are done): wait for the workers
        /// still inside it to leave.
        pub fn end(self: *Self) void {
            self.active.store(false, .seq_cst);
            while (self.inflight.load(.seq_cst) != 0) std.atomic.spinLoopHint();
        }

        fn run(self: *Self, my_slot: usize) void {
            slot = my_slot;
            _ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            var scratch: Scratch = undefined;
            while (true) {
                _ = semaphore_wait(self.sem);
                if (self.quit.load(.seq_cst)) return;
                // Enter, then look: `end` either sees us inside or we see
                // the block closed (one total order over both atomics).
                _ = self.inflight.fetchAdd(1, .seq_cst);
                while (self.active.load(.seq_cst)) {
                    if (!work(self.ctx, &scratch)) std.atomic.spinLoopHint();
                }
                _ = self.inflight.fetchSub(1, .seq_cst);
            }
        }
    };
}
