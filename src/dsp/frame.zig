const std = @import("std");
const io = std.io;

pub fn length(sample_rate: u32, frame_length_msec: u8) u16 {
    return @intCast(u16, sample_rate / 1000) * frame_length_msec;
}

pub fn shift(sample_rate: u32, frame_shift_msec: u8) u16 {
    return @intCast(u16, sample_rate / 1000) * frame_shift_msec;
}

pub const FrameOpts = struct {
    length: u16 = 256,
    shift: u16 = 100,
};

pub fn FrameMaker(comptime ReaderType: type, comptime SampleType: type) type {
    return struct {
        const Self = @This();
        pub const Error = ReaderType.Error || error{ IncorrectFrameSize, UnexpectedEOF, BufferTooShort };
        pub const Reader = io.Reader(*Self, Error, readFn);

        allocator: *std.mem.Allocator,
        source: ReaderType,
        opts: FrameOpts,

        buf: []SampleType,
        buf_read_idx: usize,
        buf_write_idx: usize,

        readfn_scratch: []SampleType,
        frame_count: usize = 0,

        pub fn init(allocator: *std.mem.Allocator, source: ReaderType, opts: FrameOpts) !Self {
            var buf = try allocator.alloc(SampleType, opts.length);

            // fill half the length with zeros for the first frame and advance the write index.
            std.mem.set(SampleType, buf[0 .. opts.length / 2], 0);
            const buf_write_idx = (opts.length) / 2; // ceil division in case length is odd
            const buf_read_idx = 0;

            var scratch = try allocator.alloc(SampleType, opts.length);
            return Self{
                .allocator = allocator,
                .source = source,
                .opts = opts,
                .buf = buf,
                .buf_read_idx = buf_read_idx,
                .buf_write_idx = buf_write_idx,
                .readfn_scratch = scratch,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buf);
            self.allocator.free(self.readfn_scratch);
        }

        // reads the next frame from source, padded with zeros at the end.
        // returns true when frame is successfully read, false if source is
        // fully read.
        pub fn readFrame(self: *Self, dst: []SampleType) !bool {
            if (dst.len != self.opts.length) return Error.IncorrectFrameSize;
            defer self.frame_count += 1;

            var n = if (self.frame_count == 0) (self.opts.length + 1) / 2 else self.opts.shift;
            if (!try self.readBuf(n)) return false; // done

            for (dst) |*d| {
                d.* = self.buf[self.buf_read_idx];
                self.buf_read_idx = (self.buf_read_idx + 1) % self.buf.len;
            }

            self.buf_read_idx = (self.buf_read_idx + self.opts.shift) % self.buf.len;
            return true;
        }

        /// reads exactly n items into buf. if source has eof, it pads with 0.
        /// if at least one sample was read from source, returns true.
        fn readBuf(self: *Self, n: usize) !bool {
            var tmp: [512]SampleType = undefined;
            var unread_count: usize = n;
            var ret_val = false;

            while (unread_count > 0) {
                const len = if (unread_count < tmp.len) unread_count else tmp.len;
                const r = try self.readSamples(tmp[0..len]);
                if (r > 0) {
                    ret_val = true;
                    for (tmp[0..r]) |v| {
                        self.buf[self.buf_write_idx] = v;
                        self.buf_write_idx = (self.buf_write_idx + 1) % self.buf.len;
                    }
                    unread_count -= r;
                } else {
                    // source had eof, pad with zeros.
                    while (unread_count > 0) {
                        self.buf[self.buf_write_idx] = 0;
                        self.buf_write_idx = (self.buf_write_idx + 1) % self.buf.len;
                        unread_count -= 1;
                    }
                }
            }

            return ret_val;
        }

        fn readSamples(self: *Self, dst: []SampleType) Error!usize {
            if (comptime std.meta.trait.hasFn("readSamples")(ReaderType)) {
                // read samples directly from the source, since it's a wave reader.
                return try self.source.readSamples(dst);
            }

            // we are dealing with a raw reader, read samples by reinterpreting bytes.
            var dst_u8 = std.mem.sliceAsBytes(dst);
            const n = try self.source.readAll(dst_u8);

            if (n % @sizeOf(SampleType) != 0) {
                return Error.UnexpectedEOF;
            }

            return n / @sizeOf(SampleType);
        }

        /// implements the io.Reader interface. Provided buffer must be long
        /// enough to hold an entire frame.
        fn readFn(self: *Self, buf: []u8) Error!usize {
            if (buf.len < self.opts.length * @sizeOf(SampleType)) {
                return Error.BufferTooShort;
            }

            if (!try self.readFrame(self.readfn_scratch)) {
                return 0;
            }

            const scratch_u8 = std.mem.sliceAsBytes(self.readfn_scratch);
            std.mem.copy(u8, buf, scratch_u8);

            return scratch_u8.len;
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

pub fn frameMaker(allocator: *std.mem.Allocator, reader: anytype, opts: FrameOpts) !FrameMaker(@TypeOf(reader), f32) {
    return FrameMaker(@TypeOf(reader), f32).init(allocator, reader, opts);
}

test "framemaker src=io.Reader" {
    var r = std.io.fixedBufferStream(@embedFile("testdata/test_pcm16.f32.raw")).reader();
    var fm = try frameMaker(std.testing.allocator, r, .{});
    defer fm.deinit();

    var truthReader = std.io.fixedBufferStream(@embedFile("testdata/test_pcm16.f32.frames")).reader();

    var got = try std.testing.allocator.alloc(f32, fm.opts.length);
    defer std.testing.allocator.free(got);

    var frame: usize = 0;
    while (true) {
        if (!try fm.readFrame(got)) {
            try std.testing.expectError(error.EndOfStream, truthReader.readByte());
            break;
        }

        for (got) |g, idx| {
            const want = @bitCast(f32, try truthReader.readIntLittle(i32));
            std.testing.expectApproxEqRel(want, g, 0.001) catch |err| {
                std.debug.warn("failed at frame={d} index={d}", .{ frame, idx });
                return err;
            };
        }
        frame += 1;
    }
}

test "framemaker src=WaveReader" {
    const wav = @import("../wav/wav.zig");
    var r = std.io.fixedBufferStream(@embedFile("testdata/test_pcm16.wav")).reader();
    var wavr = wav.waveReaderFloat32(r);
    var fm = try frameMaker(std.testing.allocator, wavr, .{});
    defer fm.deinit();

    var truthReader = std.io.fixedBufferStream(@embedFile("testdata/test_pcm16.f32.frames")).reader();

    var got = try std.testing.allocator.alloc(f32, fm.opts.length);
    defer std.testing.allocator.free(got);

    var frame: usize = 0;
    while (true) {
        if (!try fm.readFrame(got)) {
            try std.testing.expectError(error.EndOfStream, truthReader.readByte());
            break;
        }

        for (got) |g, idx| {
            const want = @bitCast(f32, try truthReader.readIntLittle(i32));
            std.testing.expectApproxEqRel(want, g, 0.001) catch |err| {
                std.debug.warn("failed at frame={d} index={d}", .{ frame, idx });
                return err;
            };
        }
        frame += 1;
    }
}

test "framemaker src=WaveReader as io.Reader" {
    const wav = @import("../wav/wav.zig");
    var r = std.io.fixedBufferStream(@embedFile("testdata/test_pcm16.wav")).reader();
    var wavr = wav.waveReaderFloat32(r).reader();
    var fm = try frameMaker(std.testing.allocator, wavr, .{});
    defer fm.deinit();
    const got = try fm.reader().readAllAlloc(std.testing.allocator, std.math.maxInt(usize));
    defer std.testing.allocator.free(got);

    var truth = std.io.fixedBufferStream(@embedFile("testdata/test_pcm16.f32.frames")).reader();
    const want = try truth.readAllAlloc(std.testing.allocator, std.math.maxInt(usize));
    defer std.testing.allocator.free(want);

    try std.testing.expectEqualSlices(u8, want, got);
}
