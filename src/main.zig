const std = @import("std");
const Transcoder = @import("Transcoder.zig");

fn printHelp(program_path: []const u8) void {
    const program_basename = std.fs.path.basename(program_path);
    std.debug.print(
        \\Usage: {s} [SAMPLE_RATE] [INPUT_FILE] [OUTPUT_FILE]
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

    const program_path = args_iter.next() orelse unreachable;
    const target_sample_rate_string = args_iter.next() orelse { 
        printHelp(program_path);
        return error.InvalidUsage;
    };

    const target_sample_rate = try std.fmt.parseInt(u32, target_sample_rate_string, 10);

    const input_path = args_iter.next() orelse { 
        printHelp(program_path);
        return error.InvalidUsage;
    };

    const output_path = args_iter.next() orelse { 
        printHelp(program_path);
        return error.InvalidUsage;
    };

    const options: Transcoder.Options = .{
        .target_sample_rate = target_sample_rate,
        .in_file  = input_path,
        .out_file = output_path
    };

    var transcoder = try Transcoder.init(allocator, options);
    defer transcoder.deinit();

    try transcoder.run();
}

