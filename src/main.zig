const std = @import("std");
const reader = @import("core.zig");
const tcp = @import("tcp.zig");

fn hello() void {
    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);
        std.debug.print("Hello", .{});
    }
}

pub fn main() !void {
    _ = try tcp.run_server();
    var thread = try std.Thread.spawn(.{}, hello, .{});
    thread.join();
}
