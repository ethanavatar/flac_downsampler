const std = @import("std");
const deunicode = @import("deunicode");
const c = @cImport({
    @cInclude("config.h");
    @cInclude("share/compat.h");

    @cInclude("FLAC/metadata.h");
    @cInclude("FLAC/stream_decoder.h");
    @cInclude("FLAC/stream_encoder.h");
});

const Self = @This();

pub const Options = struct {
    target_sample_rate: u32,
    in_file:  []const u8, 
    out_file: []const u8, 
};

options: Options,

allocator: std.mem.Allocator,
decoder: *c.FLAC__StreamDecoder,
encoder: *c.FLAC__StreamEncoder,

chunk: ?[]c.FLAC__int32 = null,
filtered_window: ?[][]c.FLAC__int32 = null,
window: ?[][]c.FLAC__int32 = null,
last_buffer: ?[][]c.FLAC__int32 = null,

coefficients: []f64,
decimate_factor: u32,

pub fn init(allocator: std.mem.Allocator, options: Options) !Self {
    var ok = c.true;

    const decoder: ?*c.FLAC__StreamDecoder = c.FLAC__stream_decoder_new();
    if (decoder == null) return error.CreateDecoder;
    ok = c.FLAC__stream_decoder_set_md5_checking(decoder, 1);
    std.debug.assert(ok == c.true);

    const encoder: ?*c.FLAC__StreamEncoder = c.FLAC__stream_encoder_new();
    if (encoder == null) return error.CreateEncoder;
    
    const stream_info, const metadata = try getMetadataAlloc(allocator, options.in_file);
    ok = c.FLAC__stream_encoder_set_metadata(encoder, @ptrCast(metadata), @intCast(metadata.len));
    std.debug.assert(ok == c.true);

    if (options.target_sample_rate > stream_info.sample_rate) @panic("upsampling not supported right now");
    const decimate_factor = stream_info.sample_rate / options.target_sample_rate;

    ok &= c.FLAC__stream_encoder_set_verify(encoder, 1);
    ok &= c.FLAC__stream_encoder_set_compression_level(encoder, 4);
    ok &= c.FLAC__stream_encoder_set_channels(encoder, stream_info.channels);
    ok &= c.FLAC__stream_encoder_set_bits_per_sample(encoder, stream_info.bits_per_sample);
    ok &= c.FLAC__stream_encoder_set_sample_rate(encoder, options.target_sample_rate);
    ok &= c.FLAC__stream_encoder_set_total_samples_estimate(encoder, stream_info.total_samples / 2);
    std.debug.assert(ok == c.true);

    // TODO: Kaiser estimate to find number of taps
    const taps = 200;
    const target_nyquist = options.target_sample_rate / 2;
    const coefficients = try designFirLowpassAlloc(allocator, taps, target_nyquist, stream_info.sample_rate);

    return .{
        .allocator = allocator,
        .options = options,
        .decoder = decoder.?,
        .encoder = encoder.?,
        .coefficients = coefficients,
        .decimate_factor = decimate_factor,
    };
}

pub fn deinit(self: *Self) void {
    c.FLAC__stream_decoder_delete(self.decoder);
    c.FLAC__stream_encoder_delete(self.encoder);
}

pub fn run(self: *Self) !void {
    {
        const init_status = c.FLAC__stream_decoder_init_file(
            self.decoder, @ptrCast(self.options.in_file),
            decoder_write_callback, decoder_metadata_callback, decoder_error_callback,
            self
        );

        if (init_status != c.FLAC__STREAM_DECODER_INIT_STATUS_OK) {
            const msg = c.FLAC__StreamDecoderInitStatusString[init_status];
            std.debug.print("{s}\n", .{ msg });
            return error.InitDecoder;
        }
    }

    {
        const init_status = c.FLAC__stream_encoder_init_file(
            self.encoder, @ptrCast(self.options.out_file),
            encoder_progress_callback,
            self
        );

        if (init_status != c.FLAC__STREAM_ENCODER_INIT_STATUS_OK) {
            const msg = c.FLAC__StreamEncoderInitStatusString[init_status];
            std.debug.print("{s}\n", .{ msg });
            return error.InitEncoder;
        }
    }

    var ok = c.true;
    ok = c.FLAC__stream_decoder_process_until_end_of_stream(self.decoder);
    std.debug.assert(ok == c.true);

    std.debug.print("\n", .{ });

    const state = c.FLAC__stream_encoder_get_state(self.encoder);
    std.debug.assert(state == c.FLAC__STREAM_ENCODER_OK);

    ok = c.FLAC__stream_encoder_finish(self.encoder);
    std.debug.assert(ok == c.true);
}

fn sinc(x: f64) f64 {
    if (x == 0.0) return 1.0;
    return @sin(@as(f64, std.math.pi) * x) / (@as(f64, std.math.pi) * x);
}

fn designFirLowpassAlloc(
    allocator: std.mem.Allocator,
    taps_count: usize,
    cutoff_frequency_int: u32,
    sample_rate_int: u32
) ![]f64 {
    const cutoff_frequency: f64 = @floatFromInt(cutoff_frequency_int);
    const sample_rate: f64 = @floatFromInt(sample_rate_int);

    const M: f64 = @floatFromInt(taps_count - 1);
    var coefficients = try allocator.alloc(f64, taps_count);

    const normalized_cutoff = cutoff_frequency / (sample_rate / 2.0);

    var sum: f64 = 0.0;
    for (0..coefficients.len) |n_int| {
        const n = @as(f64, @floatFromInt(n_int));
        const h = sinc(normalized_cutoff * (n - M / 2.0));
        const w = 0.54 - 0.46 * @cos(2.0 * std.math.pi * n / M); // Hamming window
        const val = h * w;
        coefficients[n_int] = val;
        sum += val;
    }

    for (coefficients) |*f| f.* /= sum;
    return coefficients;
}

fn applyFirFilter(signal: []const i32, output: []i32, coefficients: []f64) void {
    for (0..signal.len) |signal_i| {
        var accumulator: f64 = 0.0;
        for (0..coefficients.len) |coefficients_i| {
            if (signal_i >= coefficients_i) {
                const sample: f64 = @floatFromInt(signal[signal_i - coefficients_i]);
                accumulator +=  coefficients[coefficients_i] * sample;
            }
        }
        const int_result: i32 = @intFromFloat(accumulator);
        output[signal_i] = std.math.clamp(int_result, std.math.minInt(i24), std.math.maxInt(i24));
    }
}

fn decoder_write_callback(
    _: [*c]const c.FLAC__StreamDecoder,
    frame:  [*c]const c.FLAC__Frame,
    buffer: [*c]const [*c]const c.FLAC__int32,
    client_data: ?*anyopaque
) callconv(.c) c.FLAC__StreamDecoderWriteStatus {
    const self: *Self = @alignCast(@ptrCast(client_data.?));
    const header = frame.*.header;
    const abort = c.FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;

    // Does the blocksize ever change? Like, maybe the very last frame is smaller?

    const channels: usize = 2; // TODO: Get from the source file
    var have_last_buffer = true;

    if (header.number.sample_number == 0) {
        self.chunk = self.allocator.alloc(c.FLAC__int32, header.blocksize) catch return abort;
        self.filtered_window = self.allocator.alloc([]c.FLAC__int32, channels) catch return abort;
        self.filtered_window.?[0] = self.allocator.alloc(c.FLAC__int32, header.blocksize * 2) catch return abort;
        self.filtered_window.?[1] = self.allocator.alloc(c.FLAC__int32, header.blocksize * 2) catch return abort;

        // this should really be a circular buffer
        self.window = self.allocator.alloc([]c.FLAC__int32, channels) catch return abort;
        self.window.?[0] = self.allocator.alloc(c.FLAC__int32, header.blocksize * 2) catch return abort;
        self.window.?[1] = self.allocator.alloc(c.FLAC__int32, header.blocksize * 2) catch return abort;

        self.last_buffer = self.allocator.alloc([]c.FLAC__int32, channels) catch return abort;
        self.last_buffer.?[0] = self.allocator.alloc(c.FLAC__int32, header.blocksize * 2) catch return abort;
        self.last_buffer.?[1] = self.allocator.alloc(c.FLAC__int32, header.blocksize * 2) catch return abort;

        have_last_buffer = false;
    }

    var chunk = self.chunk.?;
    var filtered_window = self.filtered_window.?;
    var window = self.window.?;

    if (have_last_buffer) {
        @memcpy(window[0][0..header.blocksize], self.last_buffer.?[0][0..header.blocksize]);
        @memcpy(window[1][0..header.blocksize], self.last_buffer.?[1][0..header.blocksize]);
        @memcpy(window[0][header.blocksize..header.blocksize*2], buffer[0][0..header.blocksize]);
        @memcpy(window[1][header.blocksize..header.blocksize*2], buffer[1][0..header.blocksize]);
    }

    for (0..channels) |channel| {
        if (have_last_buffer) {
            applyFirFilter(
                window[channel][0..header.blocksize * 2],
                filtered_window[channel][0..header.blocksize * 2],
                self.coefficients
            );
        } else {
            applyFirFilter(
                buffer[channel][0..header.blocksize],
                filtered_window[channel][0..header.blocksize],
                self.coefficients
            );
        }
    }

    var filled: usize = 0;
    var timer: usize = 0;
    for (0..header.blocksize) |i| {
        timer += 1;
        if (timer != self.decimate_factor) continue;
        timer = 0;

        if (have_last_buffer) {
            for (0..channels) |channel| chunk[filled * channels + channel] = filtered_window[channel][i + header.blocksize];
        } else {
            for (0..channels) |channel| chunk[filled * channels + channel] = filtered_window[channel][i];
        }
        filled += 1;
    }

    _ = c.FLAC__stream_encoder_process_interleaved(
        self.encoder,
        @ptrCast(chunk),
        @intCast(filled)
    );

    @memcpy(self.last_buffer.?[0][0..header.blocksize], buffer[0][0..header.blocksize]);
    @memcpy(self.last_buffer.?[1][0..header.blocksize], buffer[1][0..header.blocksize]);

    return c.FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

fn decoder_metadata_callback(
    _: [*c]const c.FLAC__StreamDecoder,
    metadata: [*c]const c.FLAC__StreamMetadata,
    client_data: ?*anyopaque
) callconv(.c) void {
    const self: *Self = @alignCast(@ptrCast(client_data.?));
    _ = self;
    _ = metadata;

}

fn decoder_error_callback(
    _: [*c]const c.FLAC__StreamDecoder,
    status: c.FLAC__StreamDecoderErrorStatus,
    client_data: ?*anyopaque
) callconv(.c) void {
    const self: *Self = @alignCast(@ptrCast(client_data.?));
    _ = status;
    _ = self;
}

fn encoder_progress_callback(
    _: [*c]const c.FLAC__StreamEncoder,
    bytes_written:   c.FLAC__uint64,
    samples_written: c.FLAC__uint64,
    frames_written:  u32,
    total_frames_estimate: u32,
    client_data: ?*anyopaque
) callconv(.c) void {
    const self: *Self = @alignCast(@ptrCast(client_data.?));
    _ = self;

    std.debug.print(
        "wrote {} bytes, {} samples, {}/{} frames\r",
        .{ bytes_written, samples_written, frames_written, total_frames_estimate }
    );
}

fn getMetadataAlloc(
    allocator: std.mem.Allocator,
    file: []const u8
) !struct {
    c.FLAC__StreamMetadata_StreamInfo,
    []*c.FLAC__StreamMetadata
} {
    var results: std.ArrayList(*c.FLAC__StreamMetadata) = .empty;

    var ok = c.true;

    const iter = c.FLAC__metadata_simple_iterator_new();
    ok = c.FLAC__metadata_simple_iterator_init(iter, @ptrCast(file), c.true, c.true);
    std.debug.assert(ok == c.true);
    defer c.FLAC__metadata_simple_iterator_delete(iter);

    var stream_info: ?c.FLAC__StreamMetadata_StreamInfo = null;

    var block: ?*c.FLAC__StreamMetadata = null;
    var more = c.true;
    while (more == c.true): (more = c.FLAC__metadata_simple_iterator_next(iter)) {
        block = c.FLAC__metadata_simple_iterator_get_block(iter);

        switch (block.?.@"type") {
            c.FLAC__METADATA_TYPE_STREAMINFO => {
                stream_info = block.?.data.stream_info;
                continue;
            },
            c.FLAC__METADATA_TYPE_PADDING => { },

            c.FLAC__METADATA_TYPE_APPLICATION => 
                @panic("I dont know what the application variant is for"),

            c.FLAC__METADATA_TYPE_SEEKTABLE => {
                var seek_table = &block.?.data.seek_table;
                seek_table.points = @ptrCast(try allocator.dupe(
                    c.FLAC__StreamMetadata_SeekPoint,
                    seek_table.points[0..seek_table.num_points]
                ));
            },

            c.FLAC__METADATA_TYPE_VORBIS_COMMENT => {
                var vorbis_comment = &block.?.data.vorbis_comment;

                vorbis_comment.vendor_string.entry = @ptrCast(try allocator.dupeZ(
                    c.FLAC__byte,
                    vorbis_comment.vendor_string.entry[0..vorbis_comment.vendor_string.length]
                ));

                for (0..vorbis_comment.num_comments) |i| {
                    var comment = &vorbis_comment.comments[i];
                    comment.entry = @ptrCast(try allocator.dupeZ(
                        c.FLAC__byte,
                        comment.entry[0..comment.length]
                    ));
                }

                vorbis_comment.comments = @ptrCast(try allocator.dupe(
                    c.FLAC__StreamMetadata_VorbisComment_Entry,
                    vorbis_comment.comments[0..vorbis_comment.num_comments]
                ));
            },
            c.FLAC__METADATA_TYPE_CUESHEET => {
                @panic(
                    \\ zig-translate-c doesnt support bitfields atm
                    \\ https://github.com/ziglang/translate-c/issues/179
                );

                //var cue_sheet = &block.?.data.cue_sheet;

                //var tracks: [*]c.FLAC__StreamMetadata_CueSheet_Track = @ptrCast(cue_sheet.tracks.?);
                //for (0..cue_sheet.num_tracks) |i| {
                //    var track = &tracks[i];
                //    track.indices = @ptrCast(try allocator.dupe(
                //        c.FLAC__StreamMetadata_CueSheet_Index,
                //        track.indices[0..track.num_indices]
                //    ));
                //}

                //cue_sheet.tracks = @ptrCast(try allocator.dupe(
                //    c.FLAC__StreamMetadata_CueSheet_Track,
                //    tracks[0..cue_sheet.num_tracks]
                //));
            },
            c.FLAC__METADATA_TYPE_PICTURE => {
                var picture = &block.?.data.picture;

                picture.mime_type   = @ptrCast(try allocator.dupeZ(u8, std.mem.span(picture.mime_type)));
                picture.description = @ptrCast(try allocator.dupeZ(u8, std.mem.span(picture.description)));
                picture.data = @ptrCast(try allocator.dupeZ(
                    c.FLAC__byte,
                    picture.data[0..picture.data_length]
                ));
            },

            c.FLAC__METADATA_TYPE_UNDEFINED => return error.Unknown,
            c.FLAC__MAX_METADATA_TYPE       => return error.Max,

            else => unreachable,
        }

        const new = try allocator.create(c.FLAC__StreamMetadata);
        new.* = block.?.*;
        try results.append(allocator, new);
    }

    return .{ stream_info.?, results.items };
}

//fn printMetadata(file: []const u8) !void {
//    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//    defer arena.deinit();
//
//    const allocator = arena.allocator();
//    _, const metadata = try getMetadataAlloc(allocator, file);
//
//    for (metadata) |block| {
//        switch (block.@"type") {
//            c.FLAC__METADATA_TYPE_STREAMINFO  => std.debug.print("{any}\n", .{ block.data.stream_info }),
//            c.FLAC__METADATA_TYPE_PADDING     => std.debug.print("{any}\n", .{ block.data.padding }),
//            c.FLAC__METADATA_TYPE_APPLICATION => std.debug.print("{any}\n", .{ block.data.application }),
//            c.FLAC__METADATA_TYPE_SEEKTABLE   => std.debug.print("{any}\n", .{ block.data.seek_table }),
//            c.FLAC__METADATA_TYPE_VORBIS_COMMENT => {
//                const s = block.data.vorbis_comment;
//                std.debug.print("{s}\n", .{ s.vendor_string.entry });
//
//                for (0..s.num_comments) |i| {
//                    const comment_slice = std.mem.span(s.comments[i].entry);
//                    const comment_ascii = try deunicode.deunicodeAlloc(allocator, comment_slice);
//                    std.debug.print("{s}\n", .{ comment_ascii });
//                }
//            },
//            c.FLAC__METADATA_TYPE_CUESHEET    => std.debug.print("{any}\n", .{ block.data.cue_sheet }),
//            c.FLAC__METADATA_TYPE_PICTURE     => std.debug.print("{any}\n", .{ block.data.picture }),
//            c.FLAC__METADATA_TYPE_UNDEFINED   => std.debug.print("{any}\n", .{ block.data.unknown }),
//            c.FLAC__MAX_METADATA_TYPE         => std.debug.print("<MAX>\n", .{ }),
//            else => unreachable,
//        }
//    }
//}
