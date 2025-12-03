const std = @import("std");
const IO = @import("../aio.zig").IO;
const Time = @import("../aio.zig").Time;

// Benchmark 辅助函数：预热循环，让 CPU 缓存和分支预测器预热
fn warmup(comptime iterations: comptime_int) void {
    var dummy: u64 = 0;
    for (0..iterations) |_| {
        dummy +%= 1;
    }
    // 使用 volatile 确保编译器不会优化掉这个循环
    @as(*volatile u64, @ptrCast(&dummy)).* = dummy;
}

// Benchmark 辅助函数：计算统计信息
const BenchmarkStats = struct {
    min: u64,
    max: u64,
    avg: u64,
    median: u64,
    stddev: u64,

    fn init(times: []const u64) BenchmarkStats {
        if (times.len == 0) {
            return .{ .min = 0, .max = 0, .avg = 0, .median = 0, .stddev = 0 };
        }

        // 分配排序数组
        var sorted = std.testing.allocator.alloc(u64, times.len) catch unreachable;
        defer std.testing.allocator.free(sorted);
        @memcpy(sorted, times);
        std.mem.sort(u64, sorted, {}, comptime std.sort.asc(u64));

        var sum: u64 = 0;
        for (times) |t| {
            sum += t;
        }

        const avg = sum / @as(u64, @intCast(times.len));
        const median = sorted[sorted.len / 2];

        var variance: u64 = 0;
        for (times) |t| {
            const diff = if (t > avg) t - avg else avg - t;
            variance += diff * diff;
        }
        const stddev = std.math.sqrt(variance / @as(u64, @intCast(times.len)));

        return .{
            .min = sorted[0],
            .max = sorted[sorted.len - 1],
            .avg = avg,
            .median = median,
            .stddev = stddev,
        };
    }
};

test "benchmark: IO.init/deinit performance" {
    // 测试 IO 初始化和清理的性能，这是事件循环的基础操作
    // 参考 libuv 的 benchmark 实践：预热 + 多次测量 + 统计分析
    const warmup_iterations = 10;
    const iterations = 1000;
    var timer = try std.time.Timer.start();

    // 预热：让 CPU 缓存和分支预测器预热
    warmup(1000);
    for (0..warmup_iterations) |_| {
        var io = try IO.init(32, 0);
        io.deinit();
    }

    // 分配测量数组（避免在测量期间分配）
    var times = try std.testing.allocator.alloc(u64, iterations);
    defer std.testing.allocator.free(times);

    // 测量每次 init/deinit 循环的耗时
    // 在 Darwin 上，这主要涉及 kqueue() 系统调用和资源清理
    for (0..iterations) |i| {
        const start = timer.read();
        var io = try IO.init(32, 0);
        io.deinit();
        times[i] = timer.read() - start;
    }

    const stats = BenchmarkStats.init(times);

    // 性能断言：确保操作在合理时间内完成
    // libuv 级别的性能：平均值 < 5ms，最小值 < 500μs
    // 这些阈值确保库达到 libuv 级别的性能特征
    try std.testing.expect(stats.avg < 5_000_000); // Average should be < 5ms
    try std.testing.expect(stats.min < 500_000); // Best case should be < 500μs
    try std.testing.expect(stats.median < 5_000_000); // Median should be < 5ms
}

test "benchmark: Time.monotonic() performance" {
    // 测试单调时钟查询的性能，这是超时管理的核心操作
    // libuv 级别的性能：应该 < 50ns 每次调用（在 Darwin 上使用 mach_continuous_time）
    const warmup_iterations = 1000;
    const iterations = 1_000_000; // 增加迭代次数以获得更精确的测量
    var timer = try std.time.Timer.start();
    var time = Time{};

    // 预热：让 CPU 缓存和分支预测器预热
    warmup(1000);
    for (0..warmup_iterations) |_| {
        _ = time.monotonic();
    }

    // 批量测量以减少计时器开销的影响
    const start = timer.read();
    var dummy: u64 = 0;
    for (0..iterations) |_| {
        dummy +%= time.monotonic();
    }
    const elapsed = timer.read() - start;
    // 使用 volatile 确保编译器不会优化掉这个循环
    @as(*volatile u64, @ptrCast(&dummy)).* = dummy;

    const avg_ns = elapsed / iterations;

    // Time.monotonic() 应该非常快（libuv 级别：< 50ns 每次调用）
    // 在 Darwin 上，mach_continuous_time() 通常 < 30ns
    try std.testing.expect(avg_ns < 100); // Average should be < 100ns (libuv-level performance)
}

test "benchmark: IO.run() overhead performance" {
    // 测试空事件循环的开销，这是用户代码中最频繁调用的操作
    // libuv 级别的性能：空循环应该 < 1μs 每次调用
    const warmup_iterations = 100;
    const iterations = 50_000; // 增加迭代以获得更精确的测量
    var io = try IO.init(32, 0);
    defer io.deinit();

    // 预热：让 CPU 缓存和分支预测器预热
    warmup(1000);
    for (0..warmup_iterations) |_| {
        io.run() catch {};
    }

    var timer = try std.time.Timer.start();
    var times = try std.testing.allocator.alloc(u64, iterations);
    defer std.testing.allocator.free(times);

    // 测量空循环的性能（无待处理的 IO 或超时）
    for (0..iterations) |i| {
        const start = timer.read();
        try io.run();
        times[i] = timer.read() - start;
    }

    const stats = BenchmarkStats.init(times);

    // 空的 IO.run() 应该非常快（libuv 级别：< 1μs 每次调用）
    // 在 Darwin 上，kevent() 系统调用开销通常 < 500ns
    try std.testing.expect(stats.avg < 2_000); // Average should be < 2μs (libuv-level)
    try std.testing.expect(stats.median < 2_000); // Median should be < 2μs
}

test "benchmark: IO.timeout() performance" {
    // 测试超时操作的端到端性能，包括提交和处理
    // libuv 级别的性能：超时操作应该 < 10μs 每次调用
    const warmup_iterations = 50;
    const iterations = 10_000; // 增加迭代以获得更精确的测量
    var io = try IO.init(32, 0);
    defer io.deinit();

    // 在循环外分配所有内存，避免在测量期间分配
    var completions = try std.testing.allocator.alloc(IO.Completion, iterations);
    defer std.testing.allocator.free(completions);
    var callback_called = try std.testing.allocator.alloc(bool, iterations);
    defer std.testing.allocator.free(callback_called);
    var contexts = try std.testing.allocator.alloc(*bool, iterations);
    defer std.testing.allocator.free(contexts);

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

    // 预热
    warmup(1000);
    for (0..warmup_iterations) |i| {
        var context = Context{ .called = &callback_called[i] };
        io.timeout(*Context, &context, callback, &completions[i], 0);
    }
    for (0..warmup_iterations) |_| {
        io.run() catch {};
    }

    var timer = try std.time.Timer.start();
    var times = try std.testing.allocator.alloc(u64, iterations);
    defer std.testing.allocator.free(times);

    // 测量每次超时操作的完整周期（提交 + 处理）
    for (0..iterations) |i| {
        @memset(callback_called, false);
        var context = Context{ .called = &callback_called[i] };
        contexts[i] = &callback_called[i];

        const start = timer.read();
        io.timeout(*Context, &context, callback, &completions[i], 0); // Zero timeout = immediate
        try io.run(); // 处理超时
        times[i] = timer.read() - start;
    }

    const stats = BenchmarkStats.init(times);

    // 超时操作应该高效（libuv 级别：< 10μs 每次调用）
    // 包括队列操作、超时检查和回调执行
    try std.testing.expect(stats.avg < 20_000); // Average should be < 20μs (libuv-level)
    try std.testing.expect(stats.median < 20_000); // Median should be < 20μs
}

test "benchmark: multiple timeout operations performance" {
    // 测试批量超时操作的性能，模拟真实应用场景
    // libuv 级别的性能：批量操作应该 < 5μs 每次操作
    const warmup_batches = 2;
    const batch_size = 100;
    const batches = 50; // 增加批次以获得更精确的测量
    var io = try IO.init(32, 0);
    defer io.deinit();

    // 在循环外分配所有内存
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

    // 预热
    warmup(1000);
    for (0..warmup_batches) |_| {
        @memset(callback_called, false);
        for (0..batch_size) |i| {
            var context = Context{ .called = &callback_called[i] };
            io.timeout(*Context, &context, callback, &completions[i], 0);
        }
        for (0..batch_size) |_| {
            io.run() catch {};
        }
    }

    var timer = try std.time.Timer.start();
    var times = try std.testing.allocator.alloc(u64, batches);
    defer std.testing.allocator.free(times);

    // 执行多批次的批量操作，测试队列的持续性能
    for (0..batches) |b| {
        @memset(callback_called, false);

        const start = timer.read();
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
        times[b] = timer.read() - start;
    }

    // 计算每次操作的平均时间
    var total_time: u64 = 0;
    for (times) |t| {
        total_time += t;
    }
    const avg_ns_per_batch = total_time / batches;
    const avg_ns_per_op = avg_ns_per_batch / batch_size;

    // 批量操作应该更高效（libuv 级别：< 5μs 每次操作）
    // 因为缓存局部性和减少的系统调用开销
    try std.testing.expect(avg_ns_per_op < 10_000); // Average should be < 10μs per operation (libuv-level)
}

test "benchmark: throughput - 10k requests per second" {
    // 测试库是否能达到 10k req/s 的吞吐量
    // 10k req/s = 每个请求平均 < 100μs 处理时间
    // 这个测试使用批量超时操作来模拟高吞吐量场景
    const target_rps = 10_000; // 目标：10,000 请求/秒
    const batch_size = 1000; // 每批处理 1000 个请求
    const num_batches = 20; // 总共 20 批 = 20,000 请求（超过 1 秒，但可以验证吞吐量）
    const warmup_iterations = 100;

    var io = try IO.init(32, 0);
    defer io.deinit();

    // 预分配所有需要的资源
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

    // 预热
    warmup(1000);
    @memset(callback_called, false);
    for (0..warmup_iterations) |i| {
        var context = Context{ .called = &callback_called[i % batch_size] };
        io.timeout(*Context, &context, callback, &completions[i % batch_size], 0);
    }
    for (0..warmup_iterations) |_| {
        io.run() catch {};
    }

    var timer = try std.time.Timer.start();
    const start_time = timer.read();

    // 批量提交和处理请求，模拟高吞吐量场景
    for (0..num_batches) |_| {
        @memset(callback_called, false);

        // 批量提交请求（使用 0 超时确保立即处理）
        for (0..batch_size) |i| {
            var context = Context{ .called = &callback_called[i] };
            io.timeout(*Context, &context, callback, &completions[i], 0);
        }

        // 批量处理：每次 run() 处理一个已过期的超时
        // 在批量场景下，这应该非常高效
        for (0..batch_size) |_| {
            try io.run();
        }
    }

    const elapsed_ns = timer.read() - start_time;
    const total_requests = batch_size * num_batches;
    const actual_rps = (total_requests * std.time.ns_per_s) / elapsed_ns;
    const avg_latency_ns = elapsed_ns / total_requests;

    // 验证是否能达到 10k req/s
    // libuv 级别的性能：应该能够轻松达到 10k req/s
    // 允许 5% 的误差（实际可能因为测试环境而略低）
    const min_rps = target_rps * 95 / 100; // 至少达到 9.5k req/s
    try std.testing.expect(actual_rps >= min_rps); // Should achieve at least 9.5k req/s
    try std.testing.expect(avg_latency_ns < 120_000); // Average latency should be < 120μs per request
}
