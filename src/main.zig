const std = @import("std");
const Transcoder = @import("Transcoder.zig");

const in_file  = "Men I Trust - Equus Caballus/Men I Trust - Equus Caballus - 01 To Ease You.flac";
const out_file = "Men I Trust - Equus Caballus - 01 To Ease You.flac";

fn printHelp(program_path: []const u8) void {
    const program_basename = std.fs.path.basename(program_path);
    std.debug.print(
        \\Usage: {s} [INPUT_FILE] [OUTPUT_FILE]
        \\
        \\
        ,
        .{ program_basename },
    );
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    //const program_path = args_iter.next() orelse unreachable;
    //const input_path = args_iter.next() orelse { 
    //    printHelp(program_path);
    //    return error.InvalidUsage;
    //};

    //const output_path = args_iter.next() orelse { 
    //    printHelp(program_path);
    //    return error.InvalidUsage;
    //};

    //var transcoder = try Transcoder.init(allocator, .{
    //    .in_file  = input_path,
    //    .out_file = output_path,
    //});
    var transcoder = try Transcoder.init(allocator, .{
        .in_file  = in_file,
        .out_file = out_file,
    });
    defer transcoder.deinit();

    try transcoder.run();
}

