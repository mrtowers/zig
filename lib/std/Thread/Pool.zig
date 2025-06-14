const std = @import("std");
const builtin = @import("builtin");
const Pool = @This();
const WaitGroup = @import("WaitGroup.zig");

mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},
run_queue: std.SinglyLinkedList = .{},
is_running: bool = true,
allocator: std.mem.Allocator,
threads: if (builtin.single_threaded) [0]std.Thread else []std.Thread,
ids: if (builtin.single_threaded) struct {
    inline fn deinit(_: @This(), _: std.mem.Allocator) void {}
    fn getIndex(_: @This(), _: std.Thread.Id) usize {
        return 0;
    }
} else std.AutoArrayHashMapUnmanaged(std.Thread.Id, void),

const Runnable = struct {
    runFn: RunProto,
    node: std.SinglyLinkedList.Node = .{},
};

const RunProto = *const fn (*Runnable, id: ?usize) void;

pub const Options = struct {
    allocator: std.mem.Allocator,
    n_jobs: ?usize = null,
    track_ids: bool = false,
    stack_size: usize = std.Thread.SpawnConfig.default_stack_size,
};

pub fn init(pool: *Pool, options: Options) !void {
    const allocator = options.allocator;

    pool.* = .{
        .allocator = allocator,
        .threads = if (builtin.single_threaded) .{} else &.{},
        .ids = .{},
    };

    if (builtin.single_threaded) {
        return;
    }

    const thread_count = options.n_jobs orelse @max(1, std.Thread.getCpuCount() catch 1);
    if (options.track_ids) {
        try pool.ids.ensureTotalCapacity(allocator, 1 + thread_count);
        pool.ids.putAssumeCapacityNoClobber(std.Thread.getCurrentId(), {});
    }

    // kill and join any threads we spawned and free memory on error.
    pool.threads = try allocator.alloc(std.Thread, thread_count);
    var spawned: usize = 0;
    errdefer pool.join(spawned);

    for (pool.threads) |*thread| {
        thread.* = try std.Thread.spawn(.{
            .stack_size = options.stack_size,
            .allocator = allocator,
        }, worker, .{pool});
        spawned += 1;
    }
}

pub fn deinit(pool: *Pool) void {
    pool.join(pool.threads.len); // kill and join all threads.
    pool.ids.deinit(pool.allocator);
    pool.* = undefined;
}

fn join(pool: *Pool, spawned: usize) void {
    if (builtin.single_threaded) {
        return;
    }

    {
        pool.mutex.lock();
        defer pool.mutex.unlock();

        // ensure future worker threads exit the dequeue loop
        pool.is_running = false;
    }

    // wake up any sleeping threads (this can be done outside the mutex)
    // then wait for all the threads we know are spawned to complete.
    pool.cond.broadcast();
    for (pool.threads[0..spawned]) |thread| {
        thread.join();
    }

    pool.allocator.free(pool.threads);
}

/// Used by spawn functions to limit 'f' return type to void, noreturn or error union with void or noreturn.
fn callFn(f: anytype, args: anytype) void {
    const bad_fn_return = "expected return type of startFn to be 'noreturn', '!noreturn', 'void', or '!void'";

    switch (@typeInfo(@typeInfo(@TypeOf(f)).@"fn".return_type.?)) {
        .void, .noreturn => {
            @call(.auto, f, args);
        },

        .error_union => |info| {
            switch (info.payload) {
                void, noreturn => {
                    @call(.auto, f, args) catch |err| {
                        std.debug.print("error: {s}\n", .{@errorName(err)});
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpStackTrace(trace.*);
                        }
                    };
                },

                else => {
                    @compileError(bad_fn_return);
                },
            }
        },

        else => {
            @compileError(bad_fn_return);
        },
    }
}

/// Runs `func` in the thread pool, calling `WaitGroup.start` beforehand, and
/// `WaitGroup.finish` after it returns.
///
/// In the case that queuing the function call fails to allocate memory, or the
/// target is single-threaded, the function is called directly.
pub fn spawnWg(pool: *Pool, wait_group: *WaitGroup, comptime func: anytype, args: anytype) void {
    wait_group.start();

    if (builtin.single_threaded) {
        callFn(func, args);
        wait_group.finish();
        return;
    }

    const Args = @TypeOf(args);
    const Closure = struct {
        arguments: Args,
        pool: *Pool,
        runnable: Runnable = .{ .runFn = runFn },
        wait_group: *WaitGroup,

        fn runFn(runnable: *Runnable, _: ?usize) void {
            const closure: *@This() = @alignCast(@fieldParentPtr("runnable", runnable));
            callFn(func, closure.arguments);
            closure.wait_group.finish();

            // The thread pool's allocator is protected by the mutex.
            const mutex = &closure.pool.mutex;
            mutex.lock();
            defer mutex.unlock();

            closure.pool.allocator.destroy(closure);
        }
    };

    {
        pool.mutex.lock();

        const closure = pool.allocator.create(Closure) catch {
            pool.mutex.unlock();
            callFn(func, args);
            wait_group.finish();
            return;
        };
        closure.* = .{
            .arguments = args,
            .pool = pool,
            .wait_group = wait_group,
        };

        pool.run_queue.prepend(&closure.runnable.node);
        pool.mutex.unlock();
    }

    // Notify waiting threads outside the lock to try and keep the critical section small.
    pool.cond.signal();
}

/// Runs `func` in the thread pool, calling `WaitGroup.start` beforehand, and
/// `WaitGroup.finish` after it returns.
///
/// The first argument passed to `func` is a dense `usize` thread id, the rest
/// of the arguments are passed from `args`. Requires the pool to have been
/// initialized with `.track_ids = true`.
///
/// In the case that queuing the function call fails to allocate memory, or the
/// target is single-threaded, the function is called directly.
pub fn spawnWgId(pool: *Pool, wait_group: *WaitGroup, comptime func: anytype, args: anytype) void {
    wait_group.start();

    if (builtin.single_threaded) {
        callFn(func, .{0} ++ args);
        wait_group.finish();
        return;
    }

    const Args = @TypeOf(args);
    const Closure = struct {
        arguments: Args,
        pool: *Pool,
        runnable: Runnable = .{ .runFn = runFn },
        wait_group: *WaitGroup,

        fn runFn(runnable: *Runnable, id: ?usize) void {
            const closure: *@This() = @alignCast(@fieldParentPtr("runnable", runnable));
            callFn(func, .{id.?} ++ closure.arguments);
            closure.wait_group.finish();

            // The thread pool's allocator is protected by the mutex.
            const mutex = &closure.pool.mutex;
            mutex.lock();
            defer mutex.unlock();

            closure.pool.allocator.destroy(closure);
        }
    };

    {
        pool.mutex.lock();

        const closure = pool.allocator.create(Closure) catch {
            const id: ?usize = pool.ids.getIndex(std.Thread.getCurrentId());
            pool.mutex.unlock();
            callFn(func, .{id.?} ++ args);
            wait_group.finish();
            return;
        };
        closure.* = .{
            .arguments = args,
            .pool = pool,
            .wait_group = wait_group,
        };

        pool.run_queue.prepend(&closure.runnable.node);
        pool.mutex.unlock();
    }

    // Notify waiting threads outside the lock to try and keep the critical section small.
    pool.cond.signal();
}

pub fn spawn(pool: *Pool, comptime func: anytype, args: anytype) !void {
    if (builtin.single_threaded) {
        callFn(func, args);
        return;
    }

    const Args = @TypeOf(args);
    const Closure = struct {
        arguments: Args,
        pool: *Pool,
        runnable: Runnable = .{ .runFn = runFn },

        fn runFn(runnable: *Runnable, _: ?usize) void {
            const closure: *@This() = @alignCast(@fieldParentPtr("runnable", runnable));
            callFn(func, closure.arguments);

            // The thread pool's allocator is protected by the mutex.
            const mutex = &closure.pool.mutex;
            mutex.lock();
            defer mutex.unlock();

            closure.pool.allocator.destroy(closure);
        }
    };

    {
        pool.mutex.lock();
        defer pool.mutex.unlock();

        const closure = try pool.allocator.create(Closure);
        closure.* = .{
            .arguments = args,
            .pool = pool,
        };

        pool.run_queue.prepend(&closure.runnable.node);
    }

    // Notify waiting threads outside the lock to try and keep the critical section small.
    pool.cond.signal();
}

test spawn {
    const TestFn = struct {
        fn checkRun(completed: *bool) void {
            completed.* = true;
        }
    };

    var completed: bool = false;

    {
        var pool: Pool = undefined;
        try pool.init(.{
            .allocator = std.testing.allocator,
        });
        defer pool.deinit();
        try pool.spawn(TestFn.checkRun, .{&completed});
    }

    try std.testing.expectEqual(true, completed);
}

fn worker(pool: *Pool) void {
    pool.mutex.lock();
    defer pool.mutex.unlock();

    const id: ?usize = if (pool.ids.count() > 0) @intCast(pool.ids.count()) else null;
    if (id) |_| pool.ids.putAssumeCapacityNoClobber(std.Thread.getCurrentId(), {});

    while (true) {
        while (pool.run_queue.popFirst()) |run_node| {
            // Temporarily unlock the mutex in order to execute the run_node
            pool.mutex.unlock();
            defer pool.mutex.lock();

            const runnable: *Runnable = @fieldParentPtr("node", run_node);
            runnable.runFn(runnable, id);
        }

        // Stop executing instead of waiting if the thread pool is no longer running.
        if (pool.is_running) {
            pool.cond.wait(&pool.mutex);
        } else {
            break;
        }
    }
}

pub fn waitAndWork(pool: *Pool, wait_group: *WaitGroup) void {
    var id: ?usize = null;

    while (!wait_group.isDone()) {
        pool.mutex.lock();
        if (pool.run_queue.popFirst()) |run_node| {
            id = id orelse pool.ids.getIndex(std.Thread.getCurrentId());
            pool.mutex.unlock();
            const runnable: *Runnable = @fieldParentPtr("node", run_node);
            runnable.runFn(runnable, id);
            continue;
        }

        pool.mutex.unlock();
        wait_group.wait();
        return;
    }
}

pub fn getIdCount(pool: *Pool) usize {
    return @intCast(1 + pool.threads.len);
}
