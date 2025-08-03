pub const IO = @import("io.zig").IO;
pub const Time = @import("time.zig").Time;

test "basic IO initialization" {
    const std = @import("std");
    const testing = std.testing;

    var io = try IO.init(32, 0);
    defer io.deinit();

    try testing.expect(true);
}

test "basic Time functionality" {
    const std = @import("std");
    const testing = std.testing;

    var timer = Time{};
    const start_time = timer.monotonic();

    try testing.expect(start_time > 0);
}
