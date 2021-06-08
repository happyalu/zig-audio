pub const waveReaderFloat32 = @import("src/wav/wav.zig").waveReaderFloat32;
pub const waveReaderPCM16 = @import("src/wav/wav.zig").waveReaderFloat16;
pub const frameMaker = @import("src/dsp/frame.zig").frameMaker;
pub const FFT = @import("src/dsp/fft.zig").FFT;
pub const mfccMaker = @import("src/dsp/melfreq.zig").mfccMaker;
