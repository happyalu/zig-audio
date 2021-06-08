const std = @import("std");
const audio = @import("audio");

pub fn main() anyerror!void {
    runMain() catch |err| {
        std.debug.warn("error: {s}\n", .{err});
    };
}

fn runMain() !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = &gpa.allocator;

    const size = 256;

    var f = try audio.FFT.init(alloc, size);
    defer f.deinit();

    var buf1 = try alloc.alignedAlloc(u8, 4, size * @sizeOf(f32));
    var buf2 = try alloc.alignedAlloc(u8, 4, size * @sizeOf(f32));
    defer alloc.free(buf1);
    defer alloc.free(buf2);

    try stdin.readNoEof(buf1);
    var s = std.mem.bytesAsSlice(f32, buf1);

    try f.fftr(std.mem.bytesAsSlice(f32, buf1), std.mem.bytesAsSlice(f32, buf2));

    try stdout.writeAll(buf1);
    try stdout.writeAll(buf2);
}
