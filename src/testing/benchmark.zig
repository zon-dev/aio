const std = @import("std");
const IO = @import("../aio.zig").IO;
const Time = @import("../aio.zig").Time;

test "benchmark: IO.init/deinit performance" {
    // 测试 IO 初始化和清理的性能，这是事件循环的基础操作
    // 使用 1000 次迭代以获得稳定的平均值，同时保持测试速度
    const iterations = 1000;
    var timer = try std.time.Timer.start();

    var total_time: u64 = 0;
    var min_time: ?u64 = null;
    var max_time: u64 = 0;

    // 测量每次 init/deinit 循环的耗时
    // 在 Darwin 上，这主要涉及 kqueue() 系统调用和资源清理
    for (0..iterations) |_| {
        const start = timer.read();
        var io = try IO.init(32, 0);
        io.deinit();
        const elapsed = timer.read() - start;

        total_time += elapsed;
        if (min_time) |m| {
            min_time = @min(m, elapsed);
        } else {
            min_time = elapsed;
        }
        max_time = @max(max_time, elapsed);
    }

    const avg_ns = total_time / iterations;
    const min_ns = min_time.?;

    // 性能断言：确保操作在合理时间内完成
    // 这些阈值确保库保持良好的性能特征
    // 10ms 平均值允许系统调用开销，1ms 最小值确保最佳情况下的快速初始化
    try std.testing.expect(avg_ns < 10_000_000); // Average should be < 10ms
    try std.testing.expect(min_ns < 1_000_000); // Best case should be < 1ms
}

test "benchmark: Time.monotonic() performance" {
    // 测试单调时钟查询的性能，这是超时管理的核心操作
    // 使用大量迭代（100k）因为单次调用应该非常快
    const iterations = 100_000;
    var timer = try std.time.Timer.start();
    var time = Time{};

    // 批量测量以减少计时器开销的影响
    const start = timer.read();
    for (0..iterations) |_| {
        _ = time.monotonic();
    }
    const elapsed = timer.read() - start;

    const avg_ns = elapsed / iterations;

    // Time.monotonic() 应该非常快（通常 < 100ns 每次调用）
    // 1μs 阈值确保即使在最坏情况下也能保持高效
    try std.testing.expect(avg_ns < 1_000); // Average should be < 1μs
}

test "benchmark: IO.run() overhead performance" {
    // 测试空事件循环的开销，这是用户代码中最频繁调用的操作
    // 即使没有待处理的 IO，run() 也需要检查超时和系统调用
    const iterations = 10_000;
    var io = try IO.init(32, 0);
    defer io.deinit();

    var timer = try std.time.Timer.start();
    const start = timer.read();

    // 测量空循环的性能（无待处理的 IO 或超时）
    for (0..iterations) |_| {
        try io.run();
    }

    const elapsed = timer.read() - start;
    const avg_ns = elapsed / iterations;

    // 空的 IO.run() 应该非常快（通常 < 1μs 每次调用）
    // 10μs 阈值考虑了系统调用（如 kevent）的开销
    try std.testing.expect(avg_ns < 10_000); // Average should be < 10μs
}

test "benchmark: IO.timeout() performance" {
    // 测试超时操作的端到端性能，包括提交和处理
    // 使用 0 超时确保立即触发，专注于操作本身的开销
    const iterations = 1_000;
    var io = try IO.init(32, 0);
    defer io.deinit();

    var timer = try std.time.Timer.start();
    var completions = try std.testing.allocator.alloc(IO.Completion, iterations);
    defer std.testing.allocator.free(completions);
    var callback_called = try std.testing.allocator.alloc(bool, iterations);
    defer std.testing.allocator.free(callback_called);
    @memset(callback_called, false);

    const Context = struct {
        called: *bool,
    };

    const callback = struct {
        fn on_timeout(
            context_ptr: *Context,
            _: *IO.Completion,
            _: IO.TimeoutError!void,
        ) void {
            context_ptr.called.* = true;
        }
    }.on_timeout;

    const start = timer.read();
    // 提交所有超时操作到队列
    for (0..iterations) |i| {
        var context = Context{ .called = &callback_called[i] };
        io.timeout(*Context, &context, callback, &completions[i], 0); // Zero timeout = immediate
    }

    // 处理所有超时：每次 run() 处理一个已过期的超时
    // 这模拟了真实场景中的超时处理模式
    for (0..iterations) |_| {
        try io.run();
    }

    const elapsed = timer.read() - start;
    const avg_ns = elapsed / iterations;

    // 超时操作应该高效，包括队列操作、超时检查和回调执行
    // 100μs 阈值考虑了完整的操作链开销
    try std.testing.expect(avg_ns < 100_000); // Average should be < 100μs per timeout
}

test "benchmark: multiple timeout operations performance" {
    // 测试批量超时操作的性能，模拟真实应用场景
    // 批量处理可以更好地利用缓存和减少系统调用开销
    const batch_size = 100;
    const batches = 10;
    var io = try IO.init(32, 0);
    defer io.deinit();

    var timer = try std.time.Timer.start();
    var completions = try std.testing.allocator.alloc(IO.Completion, batch_size);
    defer std.testing.allocator.free(completions);
    var callback_called = try std.testing.allocator.alloc(bool, batch_size);
    defer std.testing.allocator.free(callback_called);

    const Context = struct {
        called: *bool,
    };

    const callback = struct {
        fn on_timeout(
            context_ptr: *Context,
            _: *IO.Completion,
            _: IO.TimeoutError!void,
        ) void {
            context_ptr.called.* = true;
        }
    }.on_timeout;

    const start = timer.read();

    // 执行多批次的批量操作，测试队列的持续性能
    for (0..batches) |_| {
        @memset(callback_called, false);

        // 批量提交超时：一次性提交多个超时操作
        // 这测试了队列在高负载下的性能
        for (0..batch_size) |i| {
            var context = Context{ .called = &callback_called[i] };
            io.timeout(*Context, &context, callback, &completions[i], 0);
        }

        // 批量处理：逐个处理已过期的超时
        // 每次 run() 可能处理多个超时（如果它们同时过期）
        for (0..batch_size) |_| {
            try io.run();
        }
    }

    const elapsed = timer.read() - start;
    const total_ops = batch_size * batches;
    const avg_ns = elapsed / total_ops;

    // 批量操作应该更高效，因为缓存局部性和减少的开销
    // 50μs 阈值反映了批量处理的性能优势
    try std.testing.expect(avg_ns < 50_000); // Average should be < 50μs per operation in batch
}
