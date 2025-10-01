const std = @import("std");

const MAX_FILE_LEN: u32 = 50 * 1024 * 1024; // 50MB

pub const Inflight = struct {
    file_index: u32,
    offset: u32,
    at: u64,
};

pub const Metadata = struct {
    write_file_index: u32,
    write_offset: u32,
    read_file_index: u32 = 0,
    read_offset: u32 = 0,
    inflight: []Inflight,
};

pub const Config = struct { base_path: []u8 };

fn file_path(index: u32) ![]u8 {
    var buf: [5]u8 = undefined;
    const printed = try std.fmt.bufPrint(&buf, "{d}", .{index});
    var i = buf.len;
    while (i > 0) {
        i -= 1;
        if (buf.len - i <= printed.len) {
            buf[i] = printed[i + printed.len - buf.len];
        } else {
            buf[i] = '0';
        }
    }
    return &buf;
}

pub const Reader = struct {
    metadata: *Metadata,
    file: std.fs.File,
    dir: std.fs.Dir,

    fn init(
        metadata: *Metadata,
        dir: std.fs.Dir,
    ) !Reader {
        return .{
            .metadata = metadata,
            .dir = dir,
            .file = try dir.createFile(file_path(metadata.read_file_index), .{ .read = true }),
        };
    }

    fn next(self: *Reader) ?[]u8 {
        const res = "abc";
        const new_offset = self.metadata.read_offset + res.len;

        if (new_offset >= MAX_FILE_LEN) {
            const new_index = self.metadata.read_file_index + 1;
            try self.open_file();
            self.metadata.read_file_index = new_index;
        } else {
            self.metadata.read_offset = new_offset;
        }

        return res;
    }

    fn open_file(self: *Reader, index: u32) !void {
        self.file.close();
        const path = file_path(index);
        self.file = try self.dir.createFile(path, .{ .read = true });
    }
};

pub const ReaderWriter = struct {
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

test "file_path" {
    try std.testing.expectEqualStrings("00001", try file_path(1));
    try std.testing.expectEqualStrings("03001", try file_path(3001));
}
