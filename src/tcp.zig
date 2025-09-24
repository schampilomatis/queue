const std = @import("std");
const posix = std.posix;
const net = std.net;

const log = std.log.scoped(.tcp);
// https://www.openmymind.net/TCP-Server-In-Zig-Part-7-Kqueue/

pub fn run_server() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var server = try Server.init(allocator, 4096);
    defer server.deinit();
    const address = try net.Address.parseIp("127.0.0.1", 8081);
    try server.run(address);
}

const Client = struct {
    loop: *Epoll,
    reader: Reader,
    socket: posix.socket_t,
    address: std.net.Address,
    to_write: []u8,
    write_buf: []u8,

    fn init(allocator: std.mem.Allocator, socket: posix.socket_t, address: std.net.Address, loop: *Epoll) !Client {
        const reader = try Reader.init(allocator, 4096);
        errdefer reader.deinit(allocator);

        const write_buf = try allocator.alloc(u8, 4096);
        errdefer allocator.free(write_buf);
        return .{
            .loop = loop,
            .reader = reader,
            .socket = socket,
            .address = address,
            .to_write = &.{},
            .write_buf = write_buf,
        };
    }

    fn deinit(self: *const Client, allocator: std.mem.Allocator) void {
        self.reader.deinit(allocator);
        allocator.free(self.write_buf);
    }

    fn readMessage(self: *Client) !?[]const u8 {
        return self.reader.readMessage(self.socket) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
    }

    fn writeMessage(self: *Client, msg: []const u8) !void {
        if (self.to_write.len > 0) {
            return error.PendingMessage;
        }

        if (msg.len + 4 > self.write_buf.len) {
            return error.MessageTooLarge;
        }

        std.mem.writeInt(u32, self.write_buf[0..4], @intCast(msg.len), .little);
        const end = msg.len + 4;
        @memcpy(self.write_buf[4..end], msg);
        self.to_write = self.write_buf[0..end];
        return self.write();
    }

    fn write(self: *Client) !void {
        var buf = self.to_write;
        defer self.to_write = buf;
        while (buf.len > 0) {
            const n = posix.write(self.socket, buf) catch |err| switch (err) {
                error.WouldBlock => return self.loop.writeMode(self),
                else => return err,
            };
            if (n == 0) {
                return error.Closed;
            }
            buf = buf[n..];
        } else {
            return self.loop.readMode(self);
        }
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
    max: usize,
    loop: Epoll,
    allocator: std.mem.Allocator,
    connected: usize,
    client_pool: std.heap.MemoryPool(Client),

    fn init(allocator: std.mem.Allocator, max: usize) !Server {
        const loop = try Epoll.init();
        errdefer loop.deinit();

        return .{
            .max = max,
            .loop = loop,
            .connected = 0,
            .allocator = allocator,
            .client_pool = std.heap.MemoryPool(Client).init(allocator),
        };
    }

    fn deinit(self: *Server) void {
        self.loop.deinit();
        self.client_pool.deinit();
    }

    fn accept(self: *Server, listener: posix.socket_t) !void {
        const available = self.max - self.connected;
        for (0..available) |_| {
            var address: net.Address = undefined;
            var address_len: posix.socklen_t = @sizeOf(net.Address);

            const socket = posix.accept(listener, &address.any, &address_len, 0) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            const client = try self.client_pool.create();
            errdefer self.client_pool.destroy(client);
            client.* = Client.init(self.allocator, socket, address, &self.loop) catch |err| {
                posix.close(socket);
                log.err("failed to initialize client: {}", .{err});
                return;
            };
            try self.loop.newClient(client);

            self.connected += 1;
        } else {
            try self.loop.removeListener(listener);
        }
    }

    fn run(self: *Server, address: std.net.Address) !void {
        const listener = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 128);

        try self.loop.addListener(listener);

        while (true) {
            const ready_events = self.loop.wait();

            for (ready_events) |ready| {
                switch (ready.data.ptr) {
                    0 => self.accept(listener) catch |err| log.err("failed to accept: {}", .{err}),
                    else => |nptr| {
                        const events = ready.events;
                        const client: *Client = @ptrFromInt(nptr);
                        if (events & std.os.linux.EPOLL.IN == std.os.linux.EPOLL.IN) {
                            while (true) {
                                const msg = client.readMessage() catch {
                                    self.closeClient(client);
                                    break;
                                } orelse {
                                    break;
                                };
                                client.writeMessage(msg) catch {
                                    self.closeClient(client);
                                    break;
                                };
                            }
                        } else if (events & std.os.linux.EPOLL.OUT == std.os.linux.EPOLL.OUT) {
                            client.write() catch self.closeClient(client);
                        }
                    },
                }
            }
        }
    }

    fn closeClient(self: *Server, client: *Client) void {
        posix.close(client.socket);
        client.deinit(self.allocator);
        self.client_pool.destroy(client);
        self.connected -= 1;
    }
};

const Epoll = struct {
    efd: posix.fd_t,
    ready_list: [128]std.os.linux.epoll_event = undefined,

    fn init() !Epoll {
        const efd = try posix.epoll_create1(0);
        return .{ .efd = efd };
    }

    fn deinit(self: Epoll) void {
        posix.close(self.efd);
    }

    fn wait(self: *Epoll) []std.os.linux.epoll_event {
        const count = posix.epoll_wait(self.efd, &self.ready_list, -1);
        return self.ready_list[0..count];
    }

    fn addListener(self: Epoll, listener: posix.socket_t) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .ptr = 0 },
        };
        try posix.epoll_ctl(self.efd, std.os.linux.EPOLL.CTL_ADD, listener, &event);
    }

    fn removeListener(self: Epoll, listener: posix.socket_t) !void {
        try posix.epoll_ctl(self.efd, std.os.linux.EPOLL.CTL_DEL, listener, null);
    }

    fn newClient(self: Epoll, client: *Client) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(client) },
        };

        try posix.epoll_ctl(self.efd, std.os.linux.EPOLL.CTL_ADD, client.socket, &event);
    }

    fn readMode(self: Epoll, client: *Client) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(client) },
        };
        try posix.epoll_ctl(self.efd, std.os.linux.EPOLL.CTL_MOD, client.socket, &event);
    }

    fn writeMode(self: Epoll, client: *Client) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.OUT,
            .data = .{ .ptr = @intFromPtr(client) },
        };
        try posix.epoll_ctl(self.efd, std.os.linux.EPOLL.CTL_MOD, client.socket, &event);
    }
};
