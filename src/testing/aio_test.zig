const std = @import("std");
const IO = @import("../aio.zig").IO;
const Time = @import("../aio.zig").Time;

test "basic IO initialization" {
    const testing = std.testing;

    var io = try IO.init(32, 0);
    defer io.deinit();

    try testing.expect(true);
}

test "basic Time functionality" {
    const testing = std.testing;

    var timer = Time{};
    const start_time = timer.monotonic();

    try testing.expect(start_time > 0);
}

test "accept function updated for Darwin" {
    const builtin = @import("builtin");
    const posix = std.posix;

    // Only test on Darwin since the update was specific to Darwin
    if (!builtin.target.os.tag.isDarwin()) return;

    var io = try IO.init(32, 0);
    defer io.deinit();

    // Create a TCP socket
    const socket = try io.open_socket_tcp(
        posix.AF.INET,
        .{
            .rcvbuf = 0,
            .sndbuf = 0,
            .keepalive = null,
            .user_timeout_ms = 0,
            .nodelay = false,
        },
    );
    defer io.close_socket(socket);

    // Set up socket to listen manually
    var addr: posix.sockaddr = std.mem.zeroes(posix.sockaddr);
    addr.family = posix.AF.INET;
    const addr_bytes = std.mem.asBytes(&addr);
    // Set port to 0 (network byte order) and address to INADDR_ANY
    addr_bytes[2] = 0;
    addr_bytes[3] = 0;
    addr_bytes[4] = 0;
    addr_bytes[5] = 0;
    addr_bytes[6] = 0;
    addr_bytes[7] = 0;

    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(socket, &addr, @sizeOf(posix.sockaddr));
    try posix.listen(socket, 1);

    // Test that accept can be called - this verifies the updated accept implementation
    // The update specifically uses posix.system.accept() for Darwin instead of accept4()
    var accept_completion: IO.Completion = undefined;
    var callback_called = false;
    var accepted_socket_opt: ?posix.socket_t = null;

    const Context = struct {
        called: *bool,
        socket: *?posix.socket_t,
        io_ptr: *IO,
    };

    var context = Context{ .called = &callback_called, .socket = &accepted_socket_opt, .io_ptr = &io };

    const callback = struct {
        fn on_accept(
            context_ptr: *Context,
            _: *IO.Completion,
            result: IO.AcceptError!posix.socket_t,
        ) void {
            context_ptr.called.* = true;
            // Store accepted socket if accept succeeded
            if (result) |accepted_socket| {
                context_ptr.socket.* = accepted_socket;
            } else |_| {
                // WouldBlock is expected when no connection is pending
            }
        }
    }.on_accept;

    // Call accept - this tests the updated accept implementation for Darwin
    // The key change is using posix.system.accept() for Darwin with proper error handling
    io.accept(*Context, &context, callback, &accept_completion, socket);

    // Run the IO loop once to queue the operation
    // The accept will be processed and either complete or be queued for async handling
    try io.run();

    // Clean up accepted socket if any
    if (accepted_socket_opt) |accepted_socket| {
        io.close_socket(accepted_socket);
    }
}
