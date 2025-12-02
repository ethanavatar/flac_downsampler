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

const Options = struct {
    in_file:  []const u8, 
    out_file: []const u8, 
};

options: Options,

decoder: *c.FLAC__StreamDecoder,
encoder: *c.FLAC__StreamEncoder,

allocator: std.mem.Allocator,
chunk: ?[]c.FLAC__int32 = null,

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

    ok &= c.FLAC__stream_encoder_set_verify(encoder, 1);
    ok &= c.FLAC__stream_encoder_set_compression_level(encoder, 4);
    ok &= c.FLAC__stream_encoder_set_channels(encoder, stream_info.channels);
    ok &= c.FLAC__stream_encoder_set_bits_per_sample(encoder, stream_info.bits_per_sample);
    ok &= c.FLAC__stream_encoder_set_sample_rate(encoder, stream_info.sample_rate);
    ok &= c.FLAC__stream_encoder_set_total_samples_estimate(encoder, stream_info.total_samples);
    std.debug.assert(ok == c.true);

    return .{
        .allocator = allocator,
        .options = options,
        .decoder = decoder.?,
        .encoder = encoder.?,
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

fn decoder_write_callback(
    _: [*c]const c.FLAC__StreamDecoder,
    frame:  [*c]const c.FLAC__Frame,
    buffer: [*c]const [*c]const c.FLAC__int32,
    client_data: ?*anyopaque
) callconv(.c) c.FLAC__StreamDecoderWriteStatus {
    const self: *Self = @alignCast(@ptrCast(client_data.?));

    const header = frame.*.header;

    if (self.chunk == null) {
        self.chunk = self.allocator.alloc(c.FLAC__int32, header.blocksize * 2) catch {
            return c.FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
        };
    }

    var chunk = self.chunk.?;

    const channels: usize = 2; // TODO: Get from the source file
    for (0..header.blocksize) |i| {
        for (0..channels) |channel| chunk[i * 2 + channel] = buffer[channel][i];
    }

    _ = c.FLAC__stream_encoder_process_interleaved(
        self.encoder,
        @ptrCast(chunk),
        header.blocksize
    );

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

fn printMetadata(file: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    _, const metadata = try getMetadataAlloc(allocator, file);

    for (metadata) |block| {
        switch (block.@"type") {
            c.FLAC__METADATA_TYPE_STREAMINFO  => std.debug.print("{any}\n", .{ block.data.stream_info }),
            c.FLAC__METADATA_TYPE_PADDING     => std.debug.print("{any}\n", .{ block.data.padding }),
            c.FLAC__METADATA_TYPE_APPLICATION => std.debug.print("{any}\n", .{ block.data.application }),
            c.FLAC__METADATA_TYPE_SEEKTABLE   => std.debug.print("{any}\n", .{ block.data.seek_table }),
            c.FLAC__METADATA_TYPE_VORBIS_COMMENT => {
                const s = block.data.vorbis_comment;
                std.debug.print("{s}\n", .{ s.vendor_string.entry });

                for (0..s.num_comments) |i| {
                    const comment_slice = std.mem.span(s.comments[i].entry);
                    const comment_ascii = try deunicode.deunicodeAlloc(allocator, comment_slice);
                    std.debug.print("{s}\n", .{ comment_ascii });
                }
            },
            c.FLAC__METADATA_TYPE_CUESHEET    => std.debug.print("{any}\n", .{ block.data.cue_sheet }),
            c.FLAC__METADATA_TYPE_PICTURE     => std.debug.print("{any}\n", .{ block.data.picture }),
            c.FLAC__METADATA_TYPE_UNDEFINED   => std.debug.print("{any}\n", .{ block.data.unknown }),
            c.FLAC__MAX_METADATA_TYPE         => std.debug.print("<MAX>\n", .{ }),
            else => unreachable,
        }
    }
}
