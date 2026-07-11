const std = @import("std");

pub const magic = "STWZREL\x00".*;
pub const expected_graph_hash: u64 = 0x73963831c53df4a2;

pub const TracePart = enum(u32) { component = 0, each_memory_big = 1, memory_small = 2 };
pub const SourceLayout = enum(u32) { lookup_words = 0, memory_address = 1, memory_big = 2, memory_small = 3, bitwise_xor_12 = 4 };

pub const Trace = struct {
    part: TracePart,
    layout: SourceLayout,
    layout_arg: u32,
    output_columns: u32,
    descriptors: []u32,
};

pub const Component = struct {
    name: []u8,
    lookup_words: ?u32,
    traces: []Trace,
};

pub const Bundle = struct {
    allocator: std.mem.Allocator,
    graph_hash: u64,
    components: []Component,

    pub fn readFile(allocator: std.mem.Allocator, path: []const u8) !Bundle {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var buffer: [64 * 1024]u8 = undefined;
        var reader = file.reader(&buffer);
        const input = &reader.interface;
        if (!std.mem.eql(u8, try input.takeArray(8), &magic)) return error.InvalidMagic;
        if (try input.takeInt(u32, .little) != 1) return error.UnsupportedVersion;
        const graph_hash = try input.takeInt(u64, .little);
        if (graph_hash != expected_graph_hash) return error.GraphHashMismatch;
        const count = try input.takeInt(u32, .little);
        if (count == 0 or count > 256) return error.InvalidCount;
        const components = try allocator.alloc(Component, count);
        var initialized: usize = 0;
        errdefer {
            for (components[0..initialized]) |component| deinitComponent(allocator, component);
            allocator.free(components);
        }
        while (initialized < components.len) : (initialized += 1) {
            const name_len = try input.takeInt(u16, .little);
            const trace_count = try input.takeInt(u16, .little);
            const lookup_words_raw = try input.takeInt(u32, .little);
            if (name_len == 0 or trace_count == 0 or trace_count > 3) return error.InvalidEntry;
            const name = try allocator.alloc(u8, name_len);
            errdefer allocator.free(name);
            try input.readSliceAll(name);
            const traces = try allocator.alloc(Trace, trace_count);
            var traces_initialized: usize = 0;
            errdefer {
                for (traces[0..traces_initialized]) |trace| allocator.free(trace.descriptors);
                allocator.free(traces);
            }
            while (traces_initialized < traces.len) : (traces_initialized += 1) {
                const part = std.meta.intToEnum(TracePart, try input.takeInt(u32, .little)) catch return error.InvalidEntry;
                const layout = std.meta.intToEnum(SourceLayout, try input.takeInt(u32, .little)) catch return error.InvalidEntry;
                const layout_arg = try input.takeInt(u32, .little);
                const output_columns = try input.takeInt(u32, .little);
                if (layout_arg == 0 or output_columns == 0 or output_columns > 1024) return error.InvalidEntry;
                const descriptors = try allocator.alloc(u32, @as(usize, output_columns) * 16);
                for (descriptors) |*word| word.* = input.takeInt(u32, .little) catch |err| {
                    allocator.free(descriptors);
                    return err;
                };
                validateDescriptors(descriptors, layout, layout_arg) catch {
                    allocator.free(descriptors);
                    return error.InvalidEntry;
                };
                traces[traces_initialized] = .{
                    .part = part,
                    .layout = layout,
                    .layout_arg = layout_arg,
                    .output_columns = output_columns,
                    .descriptors = descriptors,
                };
            }
            components[initialized] = .{
                .name = name,
                .lookup_words = if (lookup_words_raw == std.math.maxInt(u32)) null else lookup_words_raw,
                .traces = traces,
            };
        }
        var trailing: [1]u8 = undefined;
        if (try input.readSliceShort(&trailing) != 0) return error.TrailingData;
        return .{ .allocator = allocator, .graph_hash = graph_hash, .components = components };
    }

    pub fn deinit(self: *Bundle) void {
        deinitComponents(self.allocator, self.components);
        self.* = undefined;
    }

    pub fn find(self: Bundle, name: []const u8) ?*const Component {
        for (self.components) |*component| if (std.mem.eql(u8, component.name, name)) return component;
        return null;
    }
};

fn validateDescriptors(descriptors: []const u32, layout: SourceLayout, layout_arg: u32) !void {
    var index: usize = 0;
    while (index < descriptors.len) : (index += 16) {
        const descriptor = descriptors[index .. index + 16];
        if (descriptor[0] < 1 or descriptor[0] > 2) return error.InvalidDescriptor;
        for (0..descriptor[0]) |use_index| {
            const use = descriptor[1 + use_index * 7 ..][0..7];
            if (use[0] > 6 or use[2] == 0 or use[3] == 0 or use[3] >= 0x7fff_ffff or use[4] > 6 or use[6] > 1)
                return error.InvalidDescriptor;
            if ((layout == .lookup_words and use[0] != 0) or
                (layout == .memory_address and use[0] != 1) or
                (layout == .memory_big and use[0] != 2 and use[0] != 3) or
                (layout == .memory_small and use[0] != 4 and use[0] != 5) or
                (layout == .bitwise_xor_12 and use[0] != 6))
                return error.InvalidDescriptor;
            if ((layout == .memory_big and use[4] == 4 and use[5] != layout_arg) or
                (layout == .memory_small and use[4] == 5 and use[5] != layout_arg) or
                (layout == .bitwise_xor_12 and use[4] == 6 and use[5] >= layout_arg))
                return error.InvalidDescriptor;
        }
    }
}

fn deinitComponents(allocator: std.mem.Allocator, components: []Component) void {
    for (components) |component| deinitComponent(allocator, component);
    allocator.free(components);
}

fn deinitComponent(allocator: std.mem.Allocator, component: Component) void {
    allocator.free(component.name);
    for (component.traces) |trace| allocator.free(trace.descriptors);
    allocator.free(component.traces);
}

test "Cairo relation bundle: generated templates load with canonical identity" {
    var bundle = try Bundle.readFile(std.testing.allocator, "vectors/cairo/cairo_relation_templates.bin");
    defer bundle.deinit();
    try std.testing.expectEqual(expected_graph_hash, bundle.graph_hash);
    try std.testing.expectEqual(@as(usize, 67), bundle.components.len);
    const add_ap = bundle.find("add_ap_opcode") orelse return error.MissingTemplate;
    try std.testing.expectEqual(@as(u32, 55), add_ap.lookup_words.?);
    try std.testing.expectEqual(@as(u32, 4), add_ap.traces[0].output_columns);
}
