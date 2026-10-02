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
//!
//! Real-time workers (the default; `--no-rt-workers` for none): each worker takes Mach's
//! time-constraint policy for the block period and joins the device's I/O
//! workgroup (setWorkgroup), so the scheduler treats it like the audio
//! thread: it keeps it on performance cores and runs it at real-time
//! priority. Off, workers run at user-interactive QoS.

const std = @import("std");

extern "c" var mach_task_self_: u32;
extern "c" fn semaphore_create(task: u32, sem: *u32, policy: c_int, value: c_int) c_int;
extern "c" fn semaphore_destroy(task: u32, sem: u32) c_int;
extern "c" fn semaphore_signal(sem: u32) c_int;
extern "c" fn semaphore_wait(sem: u32) c_int;
extern "c" fn pthread_set_qos_class_self_np(qos: c_uint, relative: c_int) c_int;
extern "c" fn pthread_self() std.c.pthread_t;
extern "c" fn pthread_mach_thread_np(t: std.c.pthread_t) u32;
extern "c" fn thread_policy_set(thread: u32, flavor: c_uint, policy: *const TimeConstraint, count: c_uint) c_int;
extern "c" fn mach_timebase_info(info: *TimebaseInfo) c_int;
extern "c" fn os_workgroup_join(wg: *anyopaque, token: *JoinToken) c_int;
extern "c" fn os_workgroup_leave(wg: *anyopaque, token: *JoinToken) void;
extern "c" fn os_release(obj: *anyopaque) void;
extern "c" fn usleep(us: c_uint) c_int;
extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;
const QOS_CLASS_USER_INTERACTIVE: c_uint = 0x21;
const SYNC_POLICY_FIFO: c_int = 0;
const THREAD_TIME_CONSTRAINT_POLICY: c_uint = 2;

const TimeConstraint = extern struct {
    period: u32,
    computation: u32,
    constraint: u32,
    preemptible: c_int,
};
const TimebaseInfo = extern struct { numer: u32, denom: u32 };
/// os_workgroup_join_token_s: a signature and 36 opaque bytes.
const JoinToken = extern struct { sig: u32 = 0, bytes: [36]u8 = @splat(0) };

/// Real-time scheduling for the workers: the device's block period.
pub const Rt = struct {
    period_ns: u64,
};

/// Give the calling thread Mach's time-constraint policy: up to half of
/// every `period_ns`, finished within the period. False if refused.
fn setTimeConstraint(period_ns: u64) bool {
    var tb: TimebaseInfo = undefined;
    if (mach_timebase_info(&tb) != 0 or tb.numer == 0) return false;
    const period: u32 = @intCast(@min(period_ns * tb.denom / tb.numer, std.math.maxInt(u32)));
    const policy: TimeConstraint = .{
        .period = period,
        .computation = period / 2,
        .constraint = period,
        .preemptible = 1,
    };
    return thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY, &policy, 4) == 0;
}

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
        rt: ?Rt = null,
        /// The I/O workgroup workers belong to (owned: one retain), and
        /// its generation; workers rejoin when it moves and ack.
        wg: std.atomic.Value(?*anyopaque) = .init(null),
        wg_gen: std.atomic.Value(u32) = .init(0),
        wg_acks: std.atomic.Value(u32) = .init(0),

        pub fn create(alloc: std.mem.Allocator, ctx: *Ctx, workers: usize, rt: ?Rt) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);
            self.* = .{ .ctx = ctx, .rt = rt };
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
            if (self.wg.load(.seq_cst)) |wg| os_release(wg);
            _ = semaphore_destroy(mach_task_self_, self.sem);
            alloc.destroy(self);
        }

        /// UI thread: move the workers into the I/O workgroup `wg` (taking
        /// over its retain; null: none), each as it next wakes. Waits until
        /// every worker has left the old one, then releases it. Without
        /// real-time workers, `wg` is released at once.
        pub fn setWorkgroup(self: *Self, wg: ?*anyopaque) void {
            if (self.rt == null or self.n == 0) {
                if (wg) |w| os_release(w);
                return;
            }
            const old = self.wg.swap(wg, .seq_cst);
            self.wg_acks.store(0, .seq_cst);
            _ = self.wg_gen.fetchAdd(1, .seq_cst);
            // A worker takes any wake-up, so keep waking until all have
            // acked; a spare wake-up finds no block open and sleeps again.
            const n: u32 = @intCast(self.n);
            while (self.wg_acks.load(.seq_cst) < n) {
                for (0..self.n) |_| _ = semaphore_signal(self.sem);
                _ = usleep(500);
            }
            if (old) |w| os_release(w);
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
            if (self.rt) |rt| {
                if (!setTimeConstraint(rt.period_ns))
                    std.log.warn("render worker {}: real-time scheduling refused", .{my_slot});
            }
            var scratch: Scratch = undefined;
            var joined: ?*anyopaque = null;
            var token: JoinToken = .{};
            var gen: u32 = 0;
            while (true) {
                _ = semaphore_wait(self.sem);
                if (self.quit.load(.seq_cst)) {
                    if (joined) |w| os_workgroup_leave(w, &token);
                    return;
                }
                const g = self.wg_gen.load(.seq_cst);
                if (g != gen) {
                    gen = g;
                    if (joined) |w| os_workgroup_leave(w, &token);
                    joined = self.wg.load(.seq_cst);
                    if (joined) |w| {
                        token = .{};
                        if (os_workgroup_join(w, &token) != 0) {
                            std.log.warn("render worker {}: could not join the audio workgroup", .{my_slot});
                            joined = null;
                        }
                    }
                    _ = self.wg_acks.fetchAdd(1, .seq_cst);
                }
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
