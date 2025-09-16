const std = @import("std");
const reader = @import("root.zig");

fn hello() void {
    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);
        std.debug.print("Hello", .{});
        reader.foo();
    }
}

pub fn main() !void {
    var thread = try std.Thread.spawn(.{}, hello, .{});
    thread.join();
}
