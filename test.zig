const std = @import("std");

pub fn main() void {
    std.debug.print("Hello, world! {x}\n", .{@sizeOf(u32)});
}
