const std = @import("std");
const flac = @cImport({
    @cInclude("config.h");
    @cInclude("share/compat.h");

    @cInclude("FLAC/metadata.h");
    @cInclude("FLAC/stream_decoder.h");
    @cInclude("FLAC/stream_encoder.h");
});

const in_file  = "Men I Trust - Equus Caballus/Men I Trust - Equus Caballus - 01 To Ease You.flac";
const out_file = "Men I Trust - Equus Caballus - 01 To Ease You.flac";

pub fn main() !void {

    const decoder: ?*flac.FLAC__StreamDecoder = flac.FLAC__stream_decoder_new();
    if (decoder == null) return error.CreateDecoder;
    defer flac.FLAC__stream_decoder_delete(decoder);
    _ = flac.FLAC__stream_decoder_set_md5_checking(decoder, 1);

    const encoder: ?*flac.FLAC__StreamEncoder = flac.FLAC__stream_encoder_new();
    if (encoder == null) return error.CreateEncoder;
    defer flac.FLAC__stream_encoder_delete(encoder);

    var transcoder: Transcoder = .{ .decoder = decoder.?, .encoder = encoder.?, };
    const init_status = flac.FLAC__stream_decoder_init_file(
        decoder, in_file,
        decoder_write_callback, decoder_metadata_callback, decoder_error_callback,
        &transcoder
    );

    if (init_status != flac.FLAC__STREAM_DECODER_INIT_STATUS_OK) {
        const msg = flac.FLAC__StreamDecoderInitStatusString[init_status];
        std.debug.print("{s}\n", .{ msg });
        return error.InitDecoder;
    }

    var ok: flac.FLAC__bool = 1;
    ok = flac.FLAC__stream_decoder_process_until_end_of_stream(decoder);
    std.debug.assert(ok == 1);

    std.debug.print("\n", .{ });

    const state = flac.FLAC__stream_encoder_get_state(encoder);
    std.debug.print("\tstate: {s}\n", .{ flac.FLAC__StreamEncoderStateString[state] });
    std.debug.assert(state == flac.FLAC__STREAM_ENCODER_OK);

    ok = flac.FLAC__stream_encoder_finish(encoder);
    std.debug.assert(ok == 1);
}

const Transcoder = struct {
    decoder: *flac.FLAC__StreamDecoder,
    encoder: *flac.FLAC__StreamEncoder,

    target_sample_rate:     ?u32 = null,
    target_bits_per_sample: ?u32 = null,
};

fn decoder_write_callback(
    decoder: [*c]const flac.FLAC__StreamDecoder,
    frame:   [*c]const flac.FLAC__Frame,
    buffer:  [*c]const [*c]const flac.FLAC__int32,
    client_data: ?*anyopaque
) callconv(.c) flac.FLAC__StreamDecoderWriteStatus {
    const self: *Transcoder = @alignCast(@ptrCast(client_data.?));
    _ = decoder;
    _ = flac.FLAC__stream_encoder_process(self.encoder, buffer, frame.*.header.blocksize);
    return flac.FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

fn decoder_metadata_callback(
    decoder:  [*c]const flac.FLAC__StreamDecoder,
    metadata: [*c]const flac.FLAC__StreamMetadata,
    client_data: ?*anyopaque
) callconv(.c) void {
    const self: *Transcoder = @alignCast(@ptrCast(client_data.?));
    _ = decoder;

    // https://xiph.org/flac/api/group__flac__metadata__level1.html
    if (metadata.*.@"type" == flac.FLAC__METADATA_TYPE_STREAMINFO) {
        const sample_rate     = metadata.*.data.stream_info.sample_rate;
        const channels        = metadata.*.data.stream_info.channels;
        const bits_per_sample = metadata.*.data.stream_info.bits_per_sample;
        const total_samples   = metadata.*.data.stream_info.total_samples;
        
        std.debug.print("sample rate    : {} Hz\n", .{ sample_rate });
        std.debug.print("channels       : {}\n",    .{ channels });
        std.debug.print("bits per sample: {}\n",    .{ bits_per_sample });
        std.debug.print("total samples  : {}\n",    .{ total_samples });

        var ok: flac.FLAC__bool = 1;
        ok &= flac.FLAC__stream_encoder_set_verify(self.encoder, 1);
        ok &= flac.FLAC__stream_encoder_set_compression_level(self.encoder, 4);
        ok &= flac.FLAC__stream_encoder_set_channels(self.encoder, channels);
        ok &= flac.FLAC__stream_encoder_set_bits_per_sample(self.encoder, bits_per_sample);
        ok &= flac.FLAC__stream_encoder_set_sample_rate(self.encoder, sample_rate);
        ok &= flac.FLAC__stream_encoder_set_total_samples_estimate(self.encoder, total_samples);

        const init_status = flac.FLAC__stream_encoder_init_file(
            self.encoder, out_file,
            encoder_progress_callback,
            self
        );

        if (init_status != flac.FLAC__STREAM_ENCODER_INIT_STATUS_OK) {
            const msg = flac.FLAC__StreamEncoderInitStatusString[init_status];
            std.debug.print("{s}\n", .{ msg });
            @panic("failed to init encoder");
        }

        const state = flac.FLAC__stream_encoder_get_state(self.encoder);
        std.debug.print("\tstate: {s}\n", .{ flac.FLAC__StreamEncoderStateString[state] });
        std.debug.assert(state == flac.FLAC__STREAM_ENCODER_OK);
    }
}

fn decoder_error_callback(
    decoder: [*c]const flac.FLAC__StreamDecoder,
    status:  flac.FLAC__StreamDecoderErrorStatus,
    client_data: ?*anyopaque
) callconv(.c) void {
    const self: *Transcoder = @alignCast(@ptrCast(client_data.?));
    _ = decoder;
    _ = status;
    _ = self;
}

fn encoder_progress_callback(
    encoder: [*c]const flac.FLAC__StreamEncoder,
    bytes_written:   flac.FLAC__uint64,
    samples_written: flac.FLAC__uint64,
    frames_written: u32,
    total_frames_estimate: u32,
    client_data: ?*anyopaque
) callconv(.c) void {
    const self: *Transcoder = @alignCast(@ptrCast(client_data.?));
    _ = encoder;
    _ = self;
    std.debug.print(
        "wrote {} bytes, {} samples, {}/{} frames\r",
        .{ bytes_written, samples_written, frames_written, total_frames_estimate }
    );
}
