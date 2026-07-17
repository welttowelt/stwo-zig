const std = @import("std");

pub const magic = "STWZFIX\x00".*;
pub const version: u32 = 1;
pub const projected_version: u32 = 2;
pub const expected_graph_hash: u64 = 0x7383de8a8df6398b;
const projected_plan_hash_offset = 28;

pub const Entry = struct {
    component: []u8,
    log_size: u32,
    row_count: u32,
    multiplicity_columns: u32,
    trace_multiplicity_columns: []u32,
    preprocessed_sources: [][]u8,
    lookup_descriptors: []u32,

    pub fn lookupCount(self: Entry) usize {
        return self.lookup_descriptors.len / 4;
    }
};

pub const Bundle = struct {
    allocator: std.mem.Allocator,
    graph_hash: u64,
    preprocessed_identities: [][]u8,
    entries: []Entry,

    pub fn readFile(allocator: std.mem.Allocator, path: []const u8) !Bundle {
        const encoded = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
        defer allocator.free(encoded);
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var buffer: [64 * 1024]u8 = undefined;
        var reader = file.reader(&buffer);
        const in = &reader.interface;
        if (!std.mem.eql(u8, try in.takeArray(8), &magic)) return error.InvalidMagic;
        const encoded_version = try in.takeInt(u32, .little);
        if (encoded_version != version and encoded_version != projected_version)
            return error.UnsupportedVersion;
        const graph_hash = try in.takeInt(u64, .little);
        if (graph_hash != expected_graph_hash) return error.GraphHashMismatch;
        const identity_count = try in.takeInt(u32, .little);
        const entry_count = try in.takeInt(u32, .little);
        if (encoded_version == version) {
            if (identity_count != 161 or entry_count != 22) return error.InvalidCount;
        } else {
            const plan_hash = try in.takeInt(u64, .little);
            if (identity_count == 0 or identity_count > 4096 or entry_count == 0 or
                entry_count > 256)
                return error.InvalidCount;
            if (plan_hash != projectedPlanHash(encoded)) return error.InvalidPlanHash;
        }
        const identities = try allocator.alloc([]u8, identity_count);
        var identities_initialized: usize = 0;
        errdefer {
            for (identities[0..identities_initialized]) |identity| allocator.free(identity);
            allocator.free(identities);
        }
        while (identities_initialized < identities.len) : (identities_initialized += 1) {
            identities[identities_initialized] = try readString(allocator, in);
        }
        const entries = try allocator.alloc(Entry, entry_count);
        var entries_initialized: usize = 0;
        errdefer {
            for (entries[0..entries_initialized]) |entry| deinitEntry(allocator, entry);
            allocator.free(entries);
        }
        while (entries_initialized < entries.len) : (entries_initialized += 1) {
            const component_len = try in.takeInt(u16, .little);
            if (try in.takeInt(u16, .little) != 0 or component_len == 0) return error.InvalidEntry;
            const log_size = try in.takeInt(u32, .little);
            const row_count = try in.takeInt(u32, .little);
            const multiplicity_count = try in.takeInt(u32, .little);
            const trace_count = try in.takeInt(u32, .little);
            const source_count = try in.takeInt(u32, .little);
            const lookup_count = try in.takeInt(u32, .little);
            const descriptor_words = try in.takeInt(u32, .little);
            if (log_size >= 31 or row_count != @as(u32, 1) << @intCast(log_size) or
                multiplicity_count == 0 or trace_count == 0 or trace_count > multiplicity_count or
                source_count > identity_count or lookup_count == 0 or descriptor_words != lookup_count * 4)
                return error.InvalidEntry;
            const component = try allocator.alloc(u8, component_len);
            errdefer allocator.free(component);
            try in.readSliceAll(component);
            const trace_columns = try allocator.alloc(u32, trace_count);
            errdefer allocator.free(trace_columns);
            for (trace_columns) |*word| {
                word.* = try in.takeInt(u32, .little);
                if (word.* >= multiplicity_count) return error.InvalidEntry;
            }
            const sources = try allocator.alloc([]u8, source_count);
            var sources_initialized: usize = 0;
            errdefer {
                for (sources[0..sources_initialized]) |source| allocator.free(source);
                allocator.free(sources);
            }
            while (sources_initialized < sources.len) : (sources_initialized += 1) {
                sources[sources_initialized] = try readString(allocator, in);
            }
            const descriptors = try allocator.alloc(u32, descriptor_words);
            errdefer allocator.free(descriptors);
            for (descriptors) |*word| word.* = try in.takeInt(u32, .little);
            try validateDescriptors(descriptors, source_count, multiplicity_count, row_count);
            entries[entries_initialized] = .{
                .component = component,
                .log_size = log_size,
                .row_count = row_count,
                .multiplicity_columns = multiplicity_count,
                .trace_multiplicity_columns = trace_columns,
                .preprocessed_sources = sources,
                .lookup_descriptors = descriptors,
            };
        }
        var trailing: [1]u8 = undefined;
        if (try in.readSliceShort(&trailing) != 0) return error.TrailingData;
        return .{ .allocator = allocator, .graph_hash = graph_hash, .preprocessed_identities = identities, .entries = entries };
    }

    pub fn deinit(self: *Bundle) void {
        deinitEntries(self.allocator, self.entries);
        deinitStrings(self.allocator, self.preprocessed_identities);
        self.* = undefined;
    }

    pub fn find(self: Bundle, component: []const u8) ?Entry {
        for (self.entries) |entry| if (std.mem.eql(u8, entry.component, component)) return entry;
        return null;
    }

    pub fn identityOrdinal(self: Bundle, identity: []const u8) ?u32 {
        return findIdentity(self.preprocessed_identities, identity);
    }
};

fn projectedPlanHash(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes, 0..) |byte, index| {
        hash ^= if (index >= projected_plan_hash_offset and index < projected_plan_hash_offset + 8)
            0
        else
            byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

fn readString(allocator: std.mem.Allocator, in: *std.Io.Reader) ![]u8 {
    const length = try in.takeInt(u16, .little);
    if (try in.takeInt(u16, .little) != 0 or length == 0) return error.InvalidEntry;
    const value = try allocator.alloc(u8, length);
    errdefer allocator.free(value);
    try in.readSliceAll(value);
    return value;
}

fn findIdentity(identities: []const []u8, identity: []const u8) ?u32 {
    for (identities, 0..) |candidate, ordinal| if (std.mem.eql(u8, candidate, identity)) return @intCast(ordinal);
    return null;
}

fn validateDescriptors(descriptors: []const u32, source_count: usize, multiplicity_count: u32, rows: u32) !void {
    for (0..descriptors.len / 4) |index| {
        const descriptor = descriptors[index * 4 ..][0..4];
        switch (descriptor[0]) {
            0 => if (descriptor[1] >= 0x7fffffff) return error.InvalidDescriptor,
            1 => if (descriptor[1] >= source_count) return error.InvalidDescriptor,
            2 => if (descriptor[1] >= multiplicity_count) return error.InvalidDescriptor,
            3, 4, 5 => {
                if (descriptor[1] >= multiplicity_count or descriptor[2] == 0 or descriptor[3] == 0 or
                    (@as(u64, 1) << @intCast(descriptor[2] * 2)) != rows or
                    (@as(u64, 1) << @intCast(descriptor[3] * 2)) != multiplicity_count)
                    return error.InvalidDescriptor;
            },
            else => return error.InvalidDescriptor,
        }
    }
}

fn deinitEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| deinitEntry(allocator, entry);
    allocator.free(entries);
}

fn deinitEntry(allocator: std.mem.Allocator, entry: Entry) void {
    allocator.free(entry.component);
    allocator.free(entry.trace_multiplicity_columns);
    deinitStrings(allocator, entry.preprocessed_sources);
    allocator.free(entry.lookup_descriptors);
}

fn deinitStrings(allocator: std.mem.Allocator, strings: []const []u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

test "Cairo fixed-table bundle: canonical graph loads" {
    var bundle = try Bundle.readFile(std.testing.allocator, "vectors/cairo/cairo_fixed_tables.bin");
    defer bundle.deinit();
    try std.testing.expectEqual(@as(usize, 22), bundle.entries.len);
    try std.testing.expectEqual(@as(usize, 161), bundle.preprocessed_identities.len);
    var lookup_outputs: usize = 0;
    for (bundle.entries) |entry| lookup_outputs += entry.lookupCount();
    try std.testing.expectEqual(@as(usize, 381), lookup_outputs);
}

test "Cairo fixed-table bundle: projected cardinalities require an authenticated encoding" {
    const allocator = std.testing.allocator;
    var encoded = [_]u8{0} ** 98;
    @memcpy(encoded[0..8], &magic);
    std.mem.writeInt(u32, encoded[8..12], projected_version, .little);
    std.mem.writeInt(u64, encoded[12..20], expected_graph_hash, .little);
    std.mem.writeInt(u32, encoded[20..24], 1, .little);
    std.mem.writeInt(u32, encoded[24..28], 1, .little);
    std.mem.writeInt(u16, encoded[36..38], 5, .little);
    @memcpy(encoded[40..45], "seq_4");
    std.mem.writeInt(u16, encoded[45..47], 1, .little);
    std.mem.writeInt(u32, encoded[49..53], 0, .little);
    std.mem.writeInt(u32, encoded[53..57], 1, .little);
    std.mem.writeInt(u32, encoded[57..61], 1, .little);
    std.mem.writeInt(u32, encoded[61..65], 1, .little);
    std.mem.writeInt(u32, encoded[65..69], 0, .little);
    std.mem.writeInt(u32, encoded[69..73], 1, .little);
    std.mem.writeInt(u32, encoded[73..77], 4, .little);
    encoded[77] = 'x';
    std.mem.writeInt(u32, encoded[78..82], 0, .little);
    std.mem.writeInt(u64, encoded[28..36], projectedPlanHash(&encoded), .little);

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "projected.bin", .data = &encoded });
    const path = try temporary.dir.realpathAlloc(allocator, "projected.bin");
    defer allocator.free(path);
    var bundle = try Bundle.readFile(allocator, path);
    try std.testing.expectEqual(@as(usize, 1), bundle.preprocessed_identities.len);
    try std.testing.expectEqual(@as(usize, 1), bundle.entries.len);
    bundle.deinit();

    encoded[28] ^= 1;
    try temporary.dir.writeFile(.{ .sub_path = "projected.bin", .data = &encoded });
    try std.testing.expectError(error.InvalidPlanHash, Bundle.readFile(allocator, path));
}
