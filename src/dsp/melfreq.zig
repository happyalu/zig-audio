const std = @import("std");
const io = std.io;
const FFT = @import("fft.zig").FFT;
const DCT = @import("dct.zig").DCT;

pub const MelOpts = struct {
    const Self = @This();

    frame_length: u16 = 256,
    sample_rate: u32 = 16000,

    remove_dc_offset: bool = true,
    dither: f32 = 1.0,

    preemph_coeff: f32 = 0.97,
    liftering_coeff: f32 = 22.0,
    blackman_coeff: f32 = 0.42,
    window: WindowType = .Hamming,

    filterbank_floor: f32 = 1.0,
    filterbank_num_bins: u8 = 20,

    mfcc_order: u8 = 12,
    output_type: OutputType = .MFCC,

    output_energy: bool = true,
    output_c0: bool = false,

    pub const OutputType = enum {
        MelEnergy,
        MFCC,
    };

    pub const WindowType = enum {
        Hanning,
        Hamming,
        Rectangular,
        Blackman,
        Povey,
    };

    pub fn fftFrameLength(self: Self) !u32 {
        if (std.math.isPowerOfTwo(self.frame_length))
            return self.frame_length * 2;

        return try std.math.ceilPowerOfTwo(u16, self.frame_length);
    }

    pub fn featLength(self: Self) usize {
        var l: usize = switch (self.output_type) {
            .MelEnergy => self.filterbank_num_bins,
            .MFCC => self.mfcc_order,
        };

        if (self.output_energy) l += 1;
        if (self.output_c0) l += 1;
        return l;
    }
};

const FilterBank = struct {
    const Self = @This();
    const mel = 1127.01048;

    bin: []usize,
    weight: []f32,
    floor: f32,
    num_bins: u8,
    allocator: *std.mem.Allocator,

    fn freq_mel(freq: f32) f32 {
        return mel * std.math.ln(freq / 700 + 1.0);
    }

    fn sample_mel(sample: usize, num: u32, sample_rate: u32) f32 {
        const sample_f32 = @intToFloat(f32, sample);
        const num_f32 = @intToFloat(f32, num);
        const rate_f32 = @intToFloat(f32, sample_rate);
        const freq = (sample_f32 + 1) / num_f32 * (rate_f32 / 2);
        return freq_mel(freq);
    }

    pub fn init(allocator: *std.mem.Allocator, floor: f32, sample_rate: u32, frame_length: u32, num_bins: u8) !Self {
        var weight = try allocator.alloc(f32, frame_length / 2);
        var bin = try allocator.alloc(usize, frame_length / 2);
        var count = try allocator.alloc(f32, num_bins + 1);
        defer allocator.free(count);

        const rate = @intToFloat(f32, sample_rate);
        const max_mel = freq_mel(rate / 2);
        var k: usize = 0;
        while (k <= num_bins) : (k += 1) {
            count[k] = @intToFloat(f32, k + 1) / @intToFloat(f32, num_bins + 1) * max_mel;
        }

        var chan_num: usize = 0;
        k = 1;
        while (k < frame_length / 2) : (k += 1) {
            const k_mel = sample_mel(k - 1, frame_length / 2, sample_rate);
            while (count[chan_num] < k_mel and chan_num < num_bins) {
                chan_num += 1;
            }
            bin[k] = chan_num;
        }

        k = 1;
        while (k < frame_length / 2) : (k += 1) {
            chan_num = bin[k];
            const k_mel = sample_mel(k - 1, frame_length / 2, sample_rate);
            weight[k] = (count[chan_num] - k_mel) / count[0];
        }

        return Self{
            .allocator = allocator,
            .bin = bin,
            .weight = weight,
            .floor = floor,
            .num_bins = num_bins,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.weight);
        self.allocator.free(self.bin);
    }

    pub fn apply(self: Self, frame: []f32, dst: []f32) !void {
        if (frame.len != self.bin.len or dst.len != 1 + 2 * self.num_bins) return error.InvalidSize;

        std.mem.set(f32, dst, 0);

        var k: usize = 1;
        while (k < frame.len) : (k += 1) {
            const fnum = self.bin[k];
            if (fnum > 0)
                dst[fnum] += frame[k] * self.weight[k];

            if (fnum <= self.weight.len) {
                dst[fnum + 1] += (1 - self.weight[k]) * frame[k];
            }
        }

        k = 1;
        while (k <= self.num_bins) : (k += 1) {
            if (dst[k] < self.floor) {
                dst[k] = self.floor;
            }
            dst[k] = std.math.ln(dst[k]);
        }
    }
};

pub fn MFCCMaker(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        const Error = ReaderType.Error || error{ IncorrectFrameSize, BufferTooShort, UnexpectedEOF };
        pub const Reader = io.Reader(*Self, Error, readFn);

        allocator: *std.mem.Allocator,
        source: ReaderType,
        fft: FFT,
        dct: DCT,
        opts: MelOpts,
        buf: []f32,
        buf2: []f32,
        window: []f32,
        readfn_scratch: []f32,
        fbank: FilterBank,
        rand: std.rand.DefaultPrng,

        pub fn init(allocator: *std.mem.Allocator, source: ReaderType, opts: MelOpts) !Self {
            var padded_frame_length = try opts.fftFrameLength();
            var buf = try allocator.alloc(f32, padded_frame_length);
            var buf2 = try allocator.alloc(f32, padded_frame_length);
            var readfn_scratch = try allocator.alloc(f32, opts.featLength());

            var window = try allocator.alloc(f32, opts.frame_length);
            const a = std.math.pi * 2.0 / @intToFloat(f32, opts.frame_length - 1);
            for (window) |*v, idx| {
                const i = @intToFloat(f32, idx);

                switch (opts.window) {
                    MelOpts.WindowType.Hanning => {
                        v.* = 0.5 - 0.5 * std.math.cos(a * i);
                    },
                    MelOpts.WindowType.Hamming => {
                        v.* = 0.54 - 0.46 * std.math.cos(a * i);
                    },
                    MelOpts.WindowType.Povey => {
                        v.* = std.math.pow(f32, (0.5 - 0.5 * std.math.cos(a * i)), 0.85);
                    },
                    MelOpts.WindowType.Rectangular => {
                        v.* = 1.0;
                    },
                    MelOpts.WindowType.Blackman => {
                        v.* = opts.blackman_coeff - 0.5 * std.math.cos(a * i) + (0.5 - opts.blackman_coeff) * std.math.cos(2 * a * i);
                    },
                }
            }

            const fft = try FFT.init(allocator, padded_frame_length);
            const fbank = try FilterBank.init(allocator, opts.filterbank_floor, opts.sample_rate, padded_frame_length, opts.filterbank_num_bins);
            const dct = try DCT.init(allocator, opts.filterbank_num_bins);

            var r = std.rand.DefaultPrng.init(0);

            return Self{
                .allocator = allocator,
                .source = source,
                .opts = opts,
                .buf = buf,
                .buf2 = buf2,
                .window = window,
                .readfn_scratch = readfn_scratch,
                .fft = fft,
                .fbank = fbank,
                .dct = dct,
                .rand = r,
            };
        }

        pub fn deinit(self: *Self) void {
            self.fft.deinit();
            self.fbank.deinit();
            self.dct.deinit();
            self.allocator.free(self.buf);
            self.allocator.free(self.buf2);
            self.allocator.free(self.window);
            self.allocator.free(self.readfn_scratch);
        }

        pub fn readFrame(self: *Self, dst: []f32) Error!bool {
            if (dst.len != self.opts.featLength()) return error.IncorrectFrameSize;

            // read input frame into buf for modification in-place
            if (!try self.readSourceFrameIntoBuf()) return false; // end of input

            std.mem.set(f32, self.buf[self.opts.frame_length..], 0.0);

            self.dither();
            self.removeDCOffset();

            const energy: f32 = if (self.opts.output_energy) self.calculateEnergy() else 0;

            var frame = self.buf[0..self.opts.frame_length];
            self.preEmphasize(frame);
            self.applyWindow(frame);

            // buf has real values, set buf2 to zero for imaginary values for computing power spectrum.  output is in the first half of buf.
            std.mem.set(f32, self.buf2, 0);
            self.spec(self.buf, self.buf2);

            var spectrum = self.buf[0 .. self.buf.len / 2];

            // reserve space for filter bank an zero it out.
            var filter_bank = self.buf2[0 .. 1 + 2 * self.opts.filterbank_num_bins];
            std.mem.set(f32, filter_bank, 0);

            self.fbank.apply(spectrum, filter_bank) catch unreachable;
            filter_bank = filter_bank[1 .. 1 + self.opts.filterbank_num_bins];

            var c0: f32 = 0;
            if (self.opts.output_c0) {
                for (filter_bank) |v| {
                    c0 += v;
                }

                c0 *= std.math.sqrt(2.0 / @intToFloat(f32, self.opts.filterbank_num_bins));
            }

            if (self.opts.output_type == .MelEnergy) {
                // ignore first mfcc and save others to dst.
                var k: usize = 0;
                while (k < self.opts.filterbank_num_bins) : (k += 1) {
                    dst[k] = filter_bank[k];
                }

                if (self.opts.output_c0) {
                    dst[k] = c0;
                    k += 1;
                }

                if (self.opts.output_energy) {
                    dst[k] = energy;
                    k += 1;
                }
                return true;
            }

            // compute DCT of filter-bank in place.  output mfcc are in the first part of the buffer.
            var dct_data = self.buf2[1 .. 1 + 2 * self.opts.filterbank_num_bins];
            self.dct.apply(dct_data) catch unreachable;
            var mfcc = dct_data[0 .. self.opts.mfcc_order + 1];

            // liftering
            for (mfcc) |*x, idx| {
                const theta = std.math.pi * @intToFloat(f32, idx) / self.opts.liftering_coeff;
                x.* *= (1.0 + self.opts.liftering_coeff / 2.0 * std.math.sin(theta));
            }

            // ignore first mfcc and save others to dst.
            var k: usize = 1;
            while (k <= self.opts.mfcc_order) : (k += 1) {
                dst[k - 1] = mfcc[k];
            }

            if (self.opts.output_c0) {
                dst[k - 1] = c0;
                k += 1;
            }

            if (self.opts.output_energy) {
                dst[k - 1] = energy;
                k += 1;
            }

            return true;
        }

        fn readSourceFrameIntoBuf(self: *Self) Error!bool {
            if (comptime std.meta.trait.hasFn("readFrame")(ReaderType)) {
                // read samples directly from the source, since it's a frame reader.
                return try self.source.readFrame(self.buf[0..self.opts.frame_length]);
            }

            // we are dealing with a raw reader, read samples by reinterpreting bytes.
            var dst_u8 = std.mem.sliceAsBytes(self.buf[0..self.opts.frame_length]);
            const n = try self.source.readAll(dst_u8);

            if (n == 0) return false;

            if (n != self.opts.frame_length * @sizeOf(f32)) {
                return Error.UnexpectedEOF;
            }

            return true;
        }

        fn removeDCOffset(self: *Self) void {
            if (!self.opts.remove_dc_offset) return;

            var sum: f32 = 0;

            for (self.buf[0..self.opts.frame_length]) |v| {
                sum += v;
            }

            const offset = sum / @intToFloat(f32, self.opts.frame_length);

            for (self.buf[0..self.opts.frame_length]) |*v| {
                v.* -= offset;
            }
        }

        fn dither(self: *Self) void {
            if (self.opts.dither == 0) {
                return;
            }

            for (self.buf[0..self.opts.frame_length]) |*v| {
                v.* += self.rand.random.floatNorm(f32) * self.opts.dither;
            }
        }

        fn calculateEnergy(self: Self) f32 {
            const energy_floor = -1.0E+10;

            var energy: f32 = 0;

            for (self.buf[0..self.opts.frame_length]) |v| {
                energy += v * v;
            }

            return if (energy <= 0) energy_floor else std.math.ln(energy);
        }

        fn preEmphasize(self: Self, buf: []f32) void {
            if (self.opts.preemph_coeff == 0) {
                return;
            }

            var i: usize = self.opts.frame_length - 1;
            while (i > 0) : (i -= 1) {
                buf[i] -= self.opts.preemph_coeff * buf[i - 1];
            }

            buf[0] -= self.opts.preemph_coeff * buf[0];
        }

        fn applyWindow(self: Self, buf: []f32) void {
            for (buf) |*v, idx| {
                v.* *= self.window[idx];
            }
        }

        fn spec(self: Self, real: []f32, imag: []f32) void {
            self.fft.fftr(real, imag) catch unreachable;

            var k: usize = 1;
            while (k < real.len / 2) : (k += 1) {
                real[k] = std.math.sqrt(real[k] * real[k] + imag[k] * imag[k]);
            }
        }

        /// implements the io.Reader interface. Provided buffer must be long
        /// enough to hold an entire frame.
        fn readFn(self: *Self, buf: []u8) Error!usize {
            if (buf.len < self.opts.featLength() * @sizeOf(f32)) {
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

pub fn mfccMaker(allocator: *std.mem.Allocator, reader: anytype, opts: MelOpts) !MFCCMaker(@TypeOf(reader)) {
    return MFCCMaker(@TypeOf(reader)).init(allocator, reader, opts);
}

test "mfcc" {
    var frames = std.io.fixedBufferStream(@embedFile("testdata/test_pcm16.f32.frames"));
    var mm = try mfccMaker(std.testing.allocator, frames.reader(), .{ .output_c0 = true, .dither = 0, .remove_dc_offset = false });
    defer mm.deinit();

    const truth = std.io.fixedBufferStream(@embedFile("testdata/test_pcm16.f32.mfcc")).reader();

    var got: [14]f32 = undefined;
    var want: [14]f32 = undefined;
    while (true) {
        if (!try mm.readFrame(got[0..])) {
            try std.testing.expectError(error.EndOfStream, truth.readByte());
            break;
        }

        const want_u8 = std.mem.sliceAsBytes(want[0..]);
        try truth.readNoEof(want_u8);

        for (got) |g, idx| {
            const w = want[idx];
            try std.testing.expectApproxEqRel(w, g, 0.01);
        }
    }
}
