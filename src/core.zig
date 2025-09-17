const std = @import("std");

pub const ReaderWriter = struct {
    read_index: u64 = 0,
    read_offset: u64 = 0,
    write_offset: u64 = 0,

    file: std.fs.File,

    fn next_len(self: *ReaderWriter) !u32 {
        var len_buf: [4]u8 = undefined;
        _ = try self.file.pread(&len_buf, self.read_offset);
        const len = std.mem.readInt(u32, &len_buf, .little);
        return len;
    }

    pub fn next(self: *ReaderWriter) !Message {
        const len = try self.next_len();
        const data = try std.heap.page_allocator.alloc(u8, len);
        _ = try self.file.pread(data, self.read_offset + @bitSizeOf(u32) / 8);
        return Message{ .data = data, .len = len };
    }

    pub fn write(self: *ReaderWriter, message: Message) !void {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, message.len, .little);
        _ = try self.file.pwrite(&len_buf, self.write_offset);
        _ = try self.file.pwrite(message.data, self.write_offset + @bitSizeOf(u32) / 8);
        self.write_offset += @bitSizeOf(u32) / 8 + message.len;
    }

    pub fn ack(self: *ReaderWriter) !void {
        const len = try self.next_len();
        self.read_offset += @bitSizeOf(u32) / 8 + len;
    }
};

pub const Message = struct {
    len: u32,
    data: []u8,

    pub fn deinit(self: Message) void {
        std.heap.page_allocator.free(self.data);
    }
};

test "write read a message from a file" {
    const file = try std.fs.cwd().createFile("test.txt", .{
        .truncate = true,
        .read = true,
    });
    defer file.close();
    defer std.fs.cwd().deleteFile("test.txt") catch {};

    var reader_writer = ReaderWriter{ .file = file };
    const data = try std.heap.page_allocator.dupe(u8, "hello world");
    const in = Message{
        .data = data,
        .len = 11,
    };
    defer in.deinit();

    try reader_writer.write(in);

    const out = try reader_writer.next();
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 11), out.len);
    try std.testing.expectEqualStrings("hello world", out.data);
}

test "write 2 messages and read them" {
    const file = try std.fs.cwd().createFile("test.txt", .{
        .truncate = true,
        .read = true,
    });
    defer file.close();
    defer std.fs.cwd().deleteFile("test.txt") catch {};

    var reader_writer = ReaderWriter{ .file = file };

    const data1 = try std.heap.page_allocator.dupe(u8, "hello world");
    const in1 = Message{
        .data = data1,
        .len = 11,
    };
    defer in1.deinit();

    const data2 = try std.heap.page_allocator.dupe(u8, "goodbye world");
    const in2 = Message{
        .data = data2,
        .len = 13,
    };
    defer in2.deinit();

    try reader_writer.write(in1);
    try reader_writer.write(in2);

    const out1 = try reader_writer.next();
    defer out1.deinit();
    try std.testing.expectEqual(@as(usize, 11), out1.len);
    try std.testing.expectEqualStrings("hello world", out1.data);

    const out2 = try reader_writer.next();
    defer out2.deinit();
    try std.testing.expectEqual(@as(usize, 11), out2.len);
    try std.testing.expectEqualStrings("hello world", out2.data);

    try reader_writer.ack();
    const out3 = try reader_writer.next();
    defer out3.deinit();
    try std.testing.expectEqual(@as(usize, 13), out3.len);
    try std.testing.expectEqualStrings("goodbye world", out3.data);
}
