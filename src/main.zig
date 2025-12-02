const std = @import("std");
const Transcoder = @import("Transcoder.zig");

const in_file  = "Men I Trust - Equus Caballus/Men I Trust - Equus Caballus - 01 To Ease You.flac";
const out_file = "Men I Trust - Equus Caballus - 01 To Ease You.flac";

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var transcoder = try Transcoder.init(allocator, .{
        .in_file  = in_file,
        .out_file = out_file,
    });
    defer transcoder.deinit();

    try transcoder.run();
}

