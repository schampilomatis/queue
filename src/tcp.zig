const std = @import("std");
const posix = std.posix;
const net = std.net;

const log = std.log.scoped(.tcp);
// https://www.openmymind.net/TCP-Server-In-Zig-Part-5b-Poll/

pub fn run_server() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var server = try Server.init(allocator, 4096);
    defer server.deinit();
    const address = try net.Address.parseIp("127.0.0.1", 8081);
    try server.run(address);
}

fn writeMessage(socket: posix.socket_t, msg: []const u8) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, @intCast(msg.len), .little);
    var vec = [2]posix.iovec_const{
        .{ .len = 4, .base = &buf },
        .{ .len = msg.len, .base = msg.ptr },
    };
    try writeAllVectored(socket, &vec);
}

fn writeAllVectored(socket: posix.socket_t, vec: []posix.iovec_const) !void {
    var i: usize = 0;
    while (true) {
        var n = try posix.writev(socket, vec);
        while (n >= vec[i].len) {
            n -= vec[i].len;
            i += 1;
            if (i >= vec.len) return;
        }
        vec[i].len -= n;
        vec[i].base += n;
    }
}

const Client = struct {
    reader: Reader,
    socket: posix.socket_t,
    address: std.net.Address,

    fn init(allocator: std.mem.Allocator, socket: posix.socket_t, address: std.net.Address) !Client {
        const reader = try Reader.init(allocator, 4096);
        errdefer reader.deinit(allocator);
        return .{
            .reader = reader,
            .socket = socket,
            .address = address,
        };
    }

    fn deinit(self: *const Client, allocator: std.mem.Allocator) void {
        self.reader.deinit(allocator);
    }

    fn readMessage(self: *Client) !?[]const u8 {
        return self.reader.readMessage(self.socket) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
    }
};

const Reader = struct {
    buf: []u8,
    pos: usize = 0,
    start: usize = 0,

    fn init(allocator: std.mem.Allocator, size: usize) !Reader {
        const buf = try allocator.alloc(u8, size);
        return .{
            .pos = 0,
            .start = 0,
            .buf = buf,
        };
    }

    fn deinit(self: *const Reader, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }

    fn readMessage(self: *Reader, socket: posix.socket_t) ![]u8 {
        var buf = self.buf;
        while (true) {
            if (try self.bufferedMessage()) |msg| {
                return msg;
            }
            const pos = self.pos;
            const n = try posix.read(socket, buf[pos..]);
            if (n == 0) {
                return error.Closed;
            }
            self.pos = pos + n;
        }
    }

    fn bufferedMessage(self: *Reader) !?[]u8 {
        const buf = self.buf;
        const pos = self.pos;
        const start = self.start;
        std.debug.assert(pos >= start);
        const unprocessed = buf[start..pos];
        if (unprocessed.len < 4) {
            self.ensureSpace(4 - unprocessed.len) catch unreachable;
            return null;
        }
        const message_len = std.mem.readInt(u32, unprocessed[0..4], .little);

        const total_len = message_len + 4;
        std.debug.print("total size {d}\n", .{total_len});
        if (unprocessed.len < total_len) {
            try self.ensureSpace(total_len);
            return null;
        }
        self.start += total_len;
        return unprocessed[4..total_len];
    }

    fn ensureSpace(self: *Reader, space: usize) !void {
        const buf = self.buf;
        if (buf.len < space) {
            return error.BufferTooSmall;
        }
        const start = self.start;
        const spare = buf.len - start;
        if (spare >= space) {
            return;
        }
        const unprocessed = buf[start..self.pos];
        std.mem.copyForwards(u8, buf[0..unprocessed.len], unprocessed);
        self.start = 0;
        self.pos = unprocessed.len;
    }
};

const Server = struct {
    allocator: std.mem.Allocator,
    connected: usize,
    polls: []posix.pollfd,
    clients: []Client,
    client_polls: []posix.pollfd,

    fn init(allocator: std.mem.Allocator, max: usize) !Server {
        const polls = try allocator.alloc(posix.pollfd, max + 1);
        errdefer allocator.free(polls);

        const clients = try allocator.alloc(Client, max);
        errdefer allocator.free(clients);

        return .{
            .polls = polls,
            .clients = clients,
            .client_polls = polls[1..],
            .connected = 0,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Server) void {
        self.allocator.free(self.polls);
        self.allocator.free(self.clients);
    }

    fn accept(self: *Server, listener: posix.socket_t) !void {
        while (true) {
            var client_address: net.Address = undefined;
            var client_address_len: posix.socklen_t = @sizeOf(net.Address);

            const socket = posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            const client = Client.init(self.allocator, socket, client_address) catch |err| {
                posix.close(socket);
                log.err("failed to initialize client: {}", .{err});
                return;
            };

            self.clients[self.connected] = client;
            self.client_polls[self.connected] = .{
                .fd = socket,
                .revents = 0,
                .events = posix.POLL.IN,
            };

            self.connected += 1;
        }
    }

    fn run(self: *Server, address: std.net.Address) !void {
        const listener = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 128);

        self.polls[0] = .{
            .fd = listener,
            .revents = 0,
            .events = posix.POLL.IN,
        };

        while (true) {
            _ = try posix.poll(self.polls[0 .. self.connected + 1], -1);
            if (self.polls[0].revents != 0) {
                self.accept(listener) catch |err| log.err("failed to accept: {}", .{err});
            }

            var i: usize = 0;
            while (i < self.connected) {
                const revents = self.client_polls[i].revents;
                if (revents == 0) {
                    i += 1;
                    continue;
                }

                if (revents & posix.POLL.IN == posix.POLL.IN) {
                    var client = &self.clients[i];
                    std.debug.print("reading from: {f}\n", .{client.address});

                    while (true) {
                        const msg = client.readMessage() catch {
                            self.removeClient(i);
                            break;
                        } orelse {
                            i += 1;
                            break;
                        };
                        std.debug.print("got: {s}\n", .{msg});
                    }
                }
            }
        }
    }

    fn removeClient(self: *Server, at: usize) void {
        var client = self.clients[at];
        posix.close(client.socket);
        client.deinit(self.allocator);

        self.clients[at] = self.clients[self.connected - 1];
        self.client_polls[at] = self.client_polls[self.connected - 1];
        self.connected -= 1;
    }
};
