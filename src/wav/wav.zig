const std = @import("std");
const g711 = @import("./g711.zig");
const io = std.io;

pub const Header = struct {
    const Self = @This();

    format: u16,
    num_channels: u16,
    sample_rate: u32,
    byte_rate: u32,
    block_align: u16,
    bits_per_sample: u16,
    extension_size: u16,
    valid_bits_per_sample: u16,
    channel_mask: u32,
    sub_format: struct { format: u16, fixed_string: [14]u8 },

    pub const Format = enum(u16) {
        PCM = 1,
        IEEEFloat = 3,
        ALaw = 6,
        ULaw = 7,
        Extensible = 0xFFFE,
    };

    fn getFormat(self: Self) !Format {
        const fmt = std.meta.intToEnum(Format, self.format) catch return error.UnsupportedFormat;

        if (fmt == Format.Extensible) {
            return std.meta.intToEnum(Format, self.sub_format.format) catch return error.UnsupportedFormat;
        }

        return fmt;
    }
};

pub fn WaveReader(comptime ReaderType: type, comptime SampleType: type, comptime sampleBufSize: u32) type {
    return struct {
        const Self = @This();
        pub const Error = ReaderType.Error || error{ BadHeader, UnexpectedEOF, BadState, UnsupportedFormat, UnsupportedSampleType };
        const max_bits_per_sample = 32;
        const data_buf_size = (max_bits_per_sample / 8) * sampleBufSize;
        const SampleFifoType = std.fifo.LinearFifo(SampleType, .{ .Static = sampleBufSize });

        source: ReaderType,
        source_unread_data_size: usize = 0,

        header: ?Header = null,

        source_buf: [data_buf_size]u8 = undefined,
        sample_fifo: SampleFifoType = SampleFifoType.init(),

        sample_i32_buf: [sampleBufSize]i32 = undefined,

        has_error: bool = false,

        pub fn readSamples(self: *Self, dst: []SampleType) Error!usize {
            if (self.has_error) return Error.BadState;

            errdefer self.has_error = true;

            if (self.header == null) {
                const hdr = try self.getHeader();
            }

            if (self.sample_fifo.count > 0) {
                return self.sample_fifo.read(dst);
            }

            // sample fifo is empty; fill it up.

            if (self.source_unread_data_size == 0) {
                return 0; // valid eof
            }

            // depending on bits_per_sample, we may not be able to read into source_buf fully.
            const bytes_per_sample = self.header.?.bits_per_sample / 8;
            const max_samples_in_buf = (self.sample_i32_buf.len / bytes_per_sample);
            var buf_len = std.math.min(self.source_unread_data_size, max_samples_in_buf * bytes_per_sample);

            const n = try self.source.readAll(self.source_buf[0..buf_len]);
            if (n == 0) return Error.UnexpectedEOF;

            self.source_unread_data_size -= n;

            if ((n % bytes_per_sample) != 0) {
                return Error.UnexpectedEOF;
            }

            try self.decodeSamples(self.source_buf[0..n], self.sample_i32_buf[0..]);

            const num_samples = (n / bytes_per_sample);

            for (self.sample_i32_buf[0..num_samples]) |v| {
                switch (SampleType) {
                    i16 => {
                        var out = if (std.math.cast(i16, v >> 16)) |value| value else |err| std.math.maxInt(i16);
                        self.sample_fifo.writeItemAssumeCapacity(out);
                    },
                    f32 => {
                        var out = @intToFloat(f32, v);
                        out /= (1 + @intToFloat(f32, std.math.maxInt(@TypeOf(v))));
                        self.sample_fifo.writeItemAssumeCapacity(out);
                    },
                    else => {
                        return Error.UnsupportedSampleType;
                    },
                }
            }

            return self.sample_fifo.read(dst);
        }

        fn decodeSamples(self: *Self, src: []u8, dst: []i32) !void {
            switch (try self.header.?.getFormat()) {
                Header.Format.PCM => {
                    switch (self.header.?.bits_per_sample) {
                        8 => {
                            const samples = std.mem.bytesAsSlice(u8, src);
                            for (samples) |s, idx| {
                                dst[idx] = (@as(i32, s) << 24) ^ std.math.minInt(i32);
                            }
                        },
                        16 => {
                            const samples = std.mem.bytesAsSlice(i16, src);
                            for (samples) |s, idx| {
                                dst[idx] = @as(i32, s) << 16;
                            }
                        },
                        24 => {
                            // sizeof(i24)= 4 therefore mem.bytesAsSlice does not do what we want.
                            var i: usize = 0;
                            while (i < src.len) : (i += 3) {
                                const sample = std.mem.readIntLittle(i24, src[i..][0..3]);
                                dst[i / 3] = @as(i32, sample) << 8;
                            }
                        },
                        32 => {
                            const samples = std.mem.bytesAsSlice(i32, src);
                            for (samples) |s, idx| {
                                dst[idx] = s;
                            }
                        },
                        else => {
                            return Error.UnsupportedFormat;
                        },
                    }
                },
                Header.Format.IEEEFloat => {
                    switch (self.header.?.bits_per_sample) {
                        32 => {
                            const samples = std.mem.bytesAsSlice(f32, src);
                            for (samples) |s, idx| {
                                var out: i32 = undefined;

                                var tmp: f64 = s;
                                const max_sample_f32 = @intToFloat(f32, std.math.maxInt(i32));
                                const min_sample_f32 = @intToFloat(f32, std.math.minInt(i32));
                                tmp *= (1.0 + max_sample_f32);

                                if (tmp < 0) {
                                    if (tmp <= min_sample_f32 - 0.5) {
                                        out = std.math.minInt(i32);
                                    } else {
                                        out = @floatToInt(i32, tmp - 0.5);
                                    }
                                } else {
                                    if (tmp >= max_sample_f32 + 0.5) {
                                        out = std.math.maxInt(i32);
                                    } else {
                                        out = @floatToInt(i32, tmp + 0.5);
                                    }
                                }

                                dst[idx] = out;
                            }
                        },
                        else => {
                            return Error.UnsupportedFormat;
                        },
                    }
                },
                Header.Format.ULaw => {
                    switch (self.header.?.bits_per_sample) {
                        8 => {
                            const samples = std.mem.bytesAsSlice(u8, src);
                            for (samples) |s, idx| {
                                dst[idx] = @as(i32, g711.ulaw_to_i16[s]) << 16;
                            }
                        },
                        else => {
                            return Error.UnsupportedFormat;
                        },
                    }
                },
                Header.Format.ALaw => {
                    switch (self.header.?.bits_per_sample) {
                        8 => {
                            const samples = std.mem.bytesAsSlice(u8, src);
                            for (samples) |s, idx| {
                                dst[idx] = @as(i32, g711.alaw_to_i16[s]) << 16;
                            }
                        },
                        else => {
                            return Error.UnsupportedFormat;
                        },
                    }
                },
                else => {
                    return Error.UnsupportedFormat;
                },
            }
        }

        /// read header and seek source reader to the start of wave data.
        pub fn getHeader(self: *Self) Error!Header {
            if (self.header != null) return self.header.?;

            if (self.has_error) return Error.BadState;

            errdefer self.has_error = true;

            var buf: [8]u8 = undefined;

            try self.readFull(&buf);
            if (!std.mem.eql(u8, buf[0..4], "RIFF")) {
                return Error.BadHeader;
            }

            try self.readFull(buf[0..4]);

            if (!std.mem.eql(u8, buf[0..4], "WAVE")) {
                return Error.BadHeader;
            }

            while (true) {
                try self.readFull(&buf);
                const chunk_type = buf[0..4];
                const chunk_size = std.mem.readIntLittle(u32, buf[4..8]);

                if (std.mem.eql(u8, chunk_type, "data")) {
                    if (self.header == null) {
                        return Error.BadHeader;
                    }
                    self.source_unread_data_size = chunk_size;
                    return self.header.?;
                } else if (!std.mem.eql(u8, chunk_type, "fmt ")) {
                    // discard all chunks other than data and fmt
                    self.source.skipBytes(chunk_size, .{}) catch |err| {
                        if (err == error.EndOfStream) {
                            return Error.UnexpectedEOF;
                        } else {
                            self.has_error = true;
                            return Error.BadState;
                        }
                    };
                    continue;
                }

                // now reading fmt chunk
                var fmt_buf_max: [40]u8 = undefined; // fmt chunk max size is 40.
                var fmt_buf = fmt_buf_max[0..chunk_size];
                try self.readFull(fmt_buf);

                var hdr: Header = undefined;

                hdr.format = std.mem.readIntLittle(u16, fmt_buf[0..2]);
                hdr.num_channels = std.mem.readIntLittle(u16, fmt_buf[2..4]);
                hdr.sample_rate = std.mem.readIntLittle(u32, fmt_buf[4..8]);
                hdr.byte_rate = std.mem.readIntLittle(u32, fmt_buf[8..12]);
                hdr.block_align = std.mem.readIntLittle(u16, fmt_buf[12..14]);
                hdr.bits_per_sample = std.mem.readIntLittle(u16, fmt_buf[14..16]);

                if (chunk_size > 16) {
                    hdr.extension_size = std.mem.readIntLittle(u16, fmt_buf[16..18]);
                    if (chunk_size > 18) {
                        hdr.valid_bits_per_sample = std.mem.readIntLittle(u16, fmt_buf[18..20]);
                        hdr.channel_mask = std.mem.readIntLittle(u32, fmt_buf[20..24]);
                        hdr.sub_format.format = std.mem.readIntLittle(u16, fmt_buf[24..26]);
                        std.mem.copy(u8, hdr.sub_format.fixed_string[0..], fmt_buf[26..40]);
                    }
                }

                // validate the header
                const fmt = try hdr.getFormat();
                switch (hdr.bits_per_sample) {
                    8, 16, 24, 32 => {},
                    else => {
                        return Error.UnsupportedFormat;
                    },
                }

                self.header = hdr;
                continue;
            }
        }

        // read into the given buffer fully, EOF means input is invalid.
        fn readFull(self: *Self, buf: []u8) Error!void {
            const n = try self.source.readAll(buf);
            if (n < buf.len) {
                return Error.UnexpectedEOF;
            }
        }
    };
}

pub fn waveReaderFloat32(reader: anytype) WaveReader(@TypeOf(reader), f32, 1024) {
    return .{ .source = reader };
}

pub fn waveReaderPCM16(reader: anytype) WaveReader(@TypeOf(reader), i16, 1024) {
    return .{ .source = reader };
}

fn testReader(comptime truthType: anytype, comptime wavFile: []const u8, comptime truthFile: []const u8) !void {
    var r = std.io.fixedBufferStream(@embedFile(wavFile)).reader();
    var wavr = WaveReader(@TypeOf(r), truthType, 1024){ .source = r };

    var truthReader = std.io.fixedBufferStream(@embedFile(truthFile)).reader();

    var got: [512]truthType = undefined;

    while (true) {
        const n = try wavr.readSamples(got[0..]);
        if (n == 0) {
            try std.testing.expectError(error.EndOfStream, truthReader.readByte());
            break;
        }

        for (got[0..n]) |g| {
            switch (truthType) {
                i16 => {
                    const want = try truthReader.readIntLittle(i16);
                    if (wavr.header.?.bits_per_sample > 16) {
                        // converting from 24/32 bit to 16 bit can lead to rounding differences.
                        try std.testing.expectApproxEqRel(@intToFloat(f32, want), @intToFloat(f32, g), 1.0);
                    } else {
                        try std.testing.expectEqual(want, g);
                    }
                },
                f32 => {
                    const want = @bitCast(f32, try truthReader.readIntLittle(i32));
                    try std.testing.expectApproxEqRel(want, g, 0.001);
                },
                else => {
                    return error.UnknownType;
                },
            }
        }
    }
}

test "wavereader src=pcm08" {
    try testReader(i16, "testdata/test_pcm08.wav", "testdata/test_pcm08.i16.raw");
    try testReader(f32, "testdata/test_pcm08.wav", "testdata/test_pcm08.f32.raw");
}

test "wavereader src=pcm16" {
    try testReader(i16, "testdata/test_pcm16.wav", "testdata/test_pcm16.i16.raw");
    try testReader(f32, "testdata/test_pcm16.wav", "testdata/test_pcm16.f32.raw");
}

test "wavereader src=pcm24" {
    try testReader(i16, "testdata/test_pcm24.wav", "testdata/test_pcm24.i16.raw");
    try testReader(f32, "testdata/test_pcm24.wav", "testdata/test_pcm24.f32.raw");
}

test "wavereader src=pcm32" {
    try testReader(i16, "testdata/test_pcm32.wav", "testdata/test_pcm32.i16.raw");
    try testReader(f32, "testdata/test_pcm32.wav", "testdata/test_pcm32.f32.raw");
}

test "wavereader src=flt32" {
    try testReader(i16, "testdata/test_flt32.wav", "testdata/test_flt32.i16.raw");
    try testReader(f32, "testdata/test_flt32.wav", "testdata/test_flt32.f32.raw");
}

test "wavereader src=u-law" {
    try testReader(i16, "testdata/test_u-law.wav", "testdata/test_u-law.i16.raw");
    try testReader(f32, "testdata/test_u-law.wav", "testdata/test_u-law.f32.raw");
}

test "wavereader src=a-law" {
    try testReader(i16, "testdata/test_a-law.wav", "testdata/test_a-law.i16.raw");
    try testReader(f32, "testdata/test_a-law.wav", "testdata/test_a-law.f32.raw");
}

test "invalid inputs" {
    try std.testing.expectError(error.UnexpectedEOF, testReader(i16, "testdata/bad_empty.wav", "testdata/test_pcm16.i16.raw"));
    try std.testing.expectError(error.UnexpectedEOF, testReader(i16, "testdata/bad_data_eof.wav", "testdata/test_pcm16.i16.raw"));
    try std.testing.expectError(error.BadHeader, testReader(i16, "testdata/bad_no_riff.wav", "testdata/test_pcm16.i16.raw"));
    try std.testing.expectError(error.BadHeader, testReader(i16, "testdata/bad_no_fmt.wav", "testdata/test_pcm16.i16.raw"));
}
