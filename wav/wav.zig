const std = @import("std");
const io = std.io;
const testing = std.testing;

const WaveFormat = enum(u16) {
    PCM = 1,
    IEEEFloat = 3,
    ALaw = 6,
    ULaw = 7,
    Extensible = 0xFFFE,
    UNDEFINED = 0xFFAA, // not a standard value
};

const WaveHeader = struct {
    format: WaveFormat,
    num_channels: u16,
    sample_rate: u32,
    byte_rate: u32,
    block_align: u16,
    bits_per_sample: u16,
    extension_size: u16,
    valid_bits_per_sample: u16,
    channel_mask: u32,
    sub_format: struct {
        format: WaveFormat,
        fixed_string: [14]u8,
    },
};

pub fn WaveReader(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        pub const Error = ReaderType.Error || error{WrongInputFormat};
        pub const Reader = io.Reader(*Self, Error, read);

        source_reader: ReaderType,

        has_failed: bool,

        has_parsed_header: bool,
        header: WaveHeader,

        unread_data_size: usize,

        pub fn read(self: *Self, buf: []u8) Error!usize {
            if (self.has_failed) {
                return error.WrongInputFormat;
            }

            if (!self.has_parsed_header) {
                try self.readHeader();
            }

            if (self.unread_data_size == 0) {
                return 0;
            }

            errdefer self.has_failed = true;

            var n = try self.source_reader.read(buf);
            if (n == 0) {
                // unexpected EOF in data
                return error.WrongInputFormat;
            }

            if (n >= self.unread_data_size) {
                n = self.unread_data_size;
                self.unread_data_size = 0;
                return n;
            }

            self.unread_data_size -= n;
            return n;
        }

        // read into the given buffer fully, EOF means input is invalid.
        fn readFull(self: *Self, buf: []u8) Error!void {
            self.source_reader.readNoEof(buf) catch |err| {
                if (err == error.EndOfStream) {
                    return Error.WrongInputFormat;
                } else {
                    return err;
                }
            };
        }

        pub fn readHeader(self: *Self) Error!void {
            if (self.has_parsed_header) {
                // already read headers
                return;
            }

            self.has_parsed_header = true;
            errdefer self.has_failed = true;

            // we need to read up to 8 bytes at a time to parse wave headers.
            var buf: [8]u8 = undefined;

            try self.readFull(&buf);

            if (!std.mem.eql(u8, buf[0..4], "RIFF")) {
                return Error.WrongInputFormat;
            }

            try self.readFull(buf[0..4]);

            if (!std.mem.eql(u8, buf[0..4], "WAVE")) {
                return Error.WrongInputFormat;
            }

            var has_fmt = false;

            while (true) {
                // keep reading chunks from the input until we have seen both fmt and data chunks, in that order.

                try self.readFull(&buf);
                var chunk_type = buf[0..4];
                var chunk_size = std.mem.readIntLittle(u32, buf[4..8]);

                if (std.mem.eql(u8, chunk_type, "fmt ")) {
                    if (has_fmt) {
                        // multiple fmt chunks
                        return Error.WrongInputFormat;
                    }
                    has_fmt = true;

                    if (chunk_size < 16) {
                        return Error.WrongInputFormat;
                    }

                    // chunk size for supported formats can be 16, 18 or 40
                    // bytes. We create a buffer of 40 bytes so that we can
                    // unmarshal our header struct, but we only use the
                    // fields provided in the file.
                    const maxFmtChunkSize = 40;
                    var fmtbuf_max: [maxFmtChunkSize]u8 = undefined;

                    var fmtbuf_active = fmtbuf_max[0..chunk_size];
                    try self.readFull(fmtbuf_active);

                    var hdr: WaveHeader = undefined;
                    hdr.sub_format.format = WaveFormat.UNDEFINED;

                    // TODO: this can be simplified greatly when packed structs work properly.

                    hdr.format = std.meta.intToEnum(WaveFormat, std.mem.readIntLittle(u16, fmtbuf_active[0..2])) catch {
                        return error.WrongInputFormat;
                    };

                    hdr.num_channels = std.mem.readIntLittle(u16, fmtbuf_active[2..4]);
                    hdr.sample_rate = std.mem.readIntLittle(u32, fmtbuf_active[4..8]);
                    hdr.byte_rate = std.mem.readIntLittle(u32, fmtbuf_active[8..12]);
                    hdr.block_align = std.mem.readIntLittle(u16, fmtbuf_active[12..14]);
                    hdr.bits_per_sample = std.mem.readIntLittle(u16, fmtbuf_active[14..16]);

                    if (chunk_size > 16) {
                        hdr.extension_size = std.mem.readIntLittle(u16, fmtbuf_active[16..18]);
                        if (chunk_size > 18) {
                            hdr.valid_bits_per_sample = std.mem.readIntLittle(u16, fmtbuf_active[18..20]);
                            hdr.channel_mask = std.mem.readIntLittle(u32, fmtbuf_active[20..24]);

                            hdr.sub_format.format = std.meta.intToEnum(WaveFormat, std.mem.readIntLittle(u16, fmtbuf_active[24..26])) catch {
                                return error.WrongInputFormat;
                            };

                            std.mem.copy(u8, hdr.sub_format.fixed_string[0..], fmtbuf_active[26..40]);
                        }
                    }

                    self.header = hdr;
                } else if (std.mem.eql(u8, chunk_type, "data")) {
                    if (!has_fmt) {
                        // data chunk without fmt chunk before it
                        return Error.WrongInputFormat;
                    }

                    self.unread_data_size = chunk_size;
                    return;
                } else {
                    self.source_reader.skipBytes(chunk_size, .{}) catch |err| {
                        if (err == error.EndOfStream) {
                            return Error.WrongInputFormat;
                        } else {
                            return err;
                        }
                    };
                }
            }
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

pub fn waveReader(reader: anytype) WaveReader(@TypeOf(reader)) {
    return .{
        .source_reader = reader,
        .header = undefined,
        .has_parsed_header = false,
        .has_failed = false,
        .unread_data_size = undefined,
    };
}

test "WaveReader" {
    // hexdump -e '8/1 "0x%02x, " "\n"' test.wav
    const bytes = &[_]u8{
        0x52, 0x49, 0x46, 0x46, 0x88, 0x00, 0x00, 0x00,
        0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20,
        0x28, 0x00, 0x00, 0x00, 0xfe, 0xff, 0x01, 0x00,
        0x80, 0x3e, 0x00, 0x00, 0x00, 0xfa, 0x00, 0x00,
        0x04, 0x00, 0x20, 0x00, 0x16, 0x00, 0x20, 0x00,
        0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa,
        0x00, 0x38, 0x9b, 0x71, 0x66, 0x61, 0x63, 0x74,
        0x04, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
        0x64, 0x61, 0x74, 0x61, 0x40, 0x00, 0x00, 0x00,
        0xa9, 0x80, 0xbf, 0x01, 0x7d, 0x06, 0x46, 0x11,
        0x02, 0xe8, 0xbb, 0x22, 0x51, 0x96, 0xf7, 0x31,
        0x04, 0x27, 0xf7, 0x3f, 0x67, 0x4d, 0xe1, 0x4a,
        0xe5, 0x59, 0x85, 0x53, 0xf8, 0x4e, 0x5b, 0x58,
        0x18, 0xa5, 0x63, 0x5a, 0xf8, 0x4e, 0x5b, 0x58,
        0xe5, 0x59, 0x85, 0x53, 0x67, 0x4d, 0xe1, 0x4a,
        0x04, 0x27, 0xf7, 0x3f, 0x51, 0x96, 0xf7, 0x31,
        0x02, 0xe8, 0xbb, 0x22, 0x7d, 0x06, 0x46, 0x11,
    };

    var fbs = io.fixedBufferStream(bytes);
    var wav_reader = waveReader(fbs.reader());
    var wav_stream = wav_reader.reader();
    var cntr = io.countingReader(wav_stream);

    const stream = cntr.reader();

    //read and discard all bytes
    while (stream.readByte()) |_| {} else |err| {
        testing.expect(err == error.EndOfStream);
    }

    std.debug.print("{}\n", .{wav_reader.header});
    std.debug.print("{}\n", .{cntr.bytes_read});
}
