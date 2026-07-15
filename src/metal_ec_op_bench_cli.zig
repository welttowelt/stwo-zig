const std = @import("std");
const metal = @import("backends/metal/runtime.zig");

fn takeWord(bytes: []const u8, cursor: *usize) !u32 {
    if (cursor.* + 4 > bytes.len) return error.Truncated;
    const value = std.mem.readInt(u32, bytes[cursor.*..][0..4], .little);
    cursor.* += 4;
    return value;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) return error.InvalidArguments;
    const bytes = try std.fs.cwd().readFileAlloc(allocator, args[1], 512 * 1024 * 1024);
    defer allocator.free(bytes);
    if (bytes.len < 32 or !std.mem.eql(u8, bytes[0..8], "STWZECI\x00")) return error.InvalidInput;
    var cursor: usize = 8;
    if (try takeWord(bytes, &cursor) != 1) return error.InvalidInput;
    const rows = try takeWord(bytes, &cursor);
    const segment = try takeWord(bytes, &cursor);
    const n_addresses = try takeWord(bytes, &cursor);
    const n_big = try takeWord(bytes, &cursor);
    const n_small = try takeWord(bytes, &cursor);
    if (rows < 16 or !std.math.isPowerOfTwo(rows)) return error.InvalidInput;
    const aligned: []align(4) const u8 = @alignCast(bytes[cursor..]);
    const input_words = std.mem.bytesAsSlice(u32, aligned);
    const expected_words = @as(usize, n_addresses) + @as(usize, n_big) * 8 + @as(usize, n_small) * 4;
    if (input_words.len != expected_words) return error.InvalidInput;
    const addresses = input_words[0..n_addresses];
    const big_words = input_words[n_addresses .. n_addresses + @as(usize, n_big) * 8];
    const small_words = input_words[n_addresses + @as(usize, n_big) * 8 ..];

    const total_words = @as(usize, n_addresses) + @as(usize, n_big) * 28 + @as(usize, n_small) * 8 +
        @as(usize, rows) * (273 + 488 + 127 * 256) + n_addresses + n_big + n_small + 256 + 1;
    var runtime = try metal.Runtime.init();
    defer runtime.deinit();
    var arena = try runtime.allocateResidentBuffer(total_words * 4);
    defer arena.deinit();
    const words: [*]u32 = @ptrCast(@alignCast(arena.contents));
    var next: u32 = 0;
    var execution_offsets: [37]u32 = undefined;
    execution_offsets[0] = next;
    @memcpy(words[next .. next + addresses.len], addresses);
    next += @intCast(addresses.len);
    for (0..28) |limb| {
        execution_offsets[1 + limb] = next;
        const bit = limb * 9;
        const source_limb = bit / 32;
        const shift: u5 = @intCast(bit % 32);
        for (0..n_big) |index| {
            const source = big_words[index * 8 ..][0..8];
            var value = source[source_limb] >> shift;
            if (shift > 23 and source_limb + 1 < 8) value |= source[source_limb + 1] << @intCast(@as(u6, 32) - shift);
            words[next + index] = value & 0x1ff;
        }
        next += n_big;
    }
    for (0..8) |limb| {
        execution_offsets[29 + limb] = next;
        const bit = limb * 9;
        const source_limb = bit / 32;
        const shift: u5 = @intCast(bit % 32);
        for (0..n_small) |index| {
            const source = small_words[index * 4 ..][0..4];
            var value = source[source_limb] >> shift;
            if (shift > 23 and source_limb + 1 < 4) value |= source[source_limb + 1] << @intCast(@as(u6, 32) - shift);
            words[next + index] = value & 0x1ff;
        }
        next += n_small;
    }
    var trace_offsets: [273]u32 = undefined;
    for (&trace_offsets) |*offset| {
        offset.* = next;
        next += rows;
    }
    const lookup_offset = next;
    next += rows * 488;
    var partial_offsets: [127]u32 = undefined;
    for (&partial_offsets) |*offset| {
        offset.* = next;
        next += rows * 256;
    }
    var multiplicity_offsets: [4]u32 = undefined;
    const multiplicity_lengths = [_]u32{ n_addresses, n_big, n_small, 256 };
    for (&multiplicity_offsets, multiplicity_lengths) |*offset, length| {
        offset.* = next;
        @memset(words[next .. next + length], 0);
        next += length;
    }
    const segment_offset = next;
    words[next] = segment;
    next += 1;
    if (next > total_words) return error.SizeOverflow;
    var plan = try runtime.prepareEcOp(execution_offsets, trace_offsets, partial_offsets, multiplicity_offsets, lookup_offset, segment_offset, partial_offsets[126], rows);
    defer plan.deinit();
    var samples: [5]f64 = undefined;
    for (&samples) |*sample| sample.* = try runtime.ecOpPrepared(arena, plan);
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
    const median = samples[2];
    const result = .{
        .rows = rows,
        .rounds_per_row = 252,
        .gpu_ms_median = median,
        .instances_per_second = @as(f64, @floatFromInt(rows)) * 1000.0 / median,
        .round_steps_per_second = @as(f64, @floatFromInt(rows * 252)) * 1000.0 / median,
        .arena_bytes = arena.byte_length,
        .compatibility_readback_bytes = 0,
        .hot_path_allocations = 0,
    };
    var buffer: [2048]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    try std.json.Stringify.value(result, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
