const std = @import("std");
const program_mod = @import("program.zig");

pub const magic = "STWZWIT\x00".*;
pub const version: u32 = 1;

pub const Entry = struct {
    label: []u8,
    semantic_hash: u64,
    program: program_mod.Program,
};

pub const Bundle = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,

    pub fn readFile(allocator: std.mem.Allocator, path: []const u8) !Bundle {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var buffer: [64 * 1024]u8 = undefined;
        var reader = file.reader(&buffer);
        const interface = &reader.interface;
        const found_magic = try interface.takeArray(8);
        if (!std.mem.eql(u8, found_magic, &magic)) return error.InvalidMagic;
        if (try interface.takeInt(u32, .little) != version) return error.UnsupportedVersion;
        const count = try interface.takeInt(u32, .little);
        if (count == 0 or count > 256) return error.InvalidCount;
        const entries = try allocator.alloc(Entry, count);
        errdefer allocator.free(entries);
        var initialized: usize = 0;
        errdefer {
            for (entries[0..initialized]) |entry| {
                allocator.free(entry.label);
                allocator.free(entry.program.insts);
            }
        }
        while (initialized < entries.len) : (initialized += 1) {
            const label_len = try interface.takeInt(u16, .little);
            if (try interface.takeInt(u16, .little) != 0 or label_len == 0 or label_len > 256) return error.InvalidEntry;
            const n_regs = try interface.takeInt(u32, .little);
            const n_inputs = try interface.takeInt(u32, .little);
            const n_cols = try interface.takeInt(u32, .little);
            const n_mult_tables = try interface.takeInt(u32, .little);
            const n_lookup_words = try interface.takeInt(u32, .little);
            const n_sub_words = try interface.takeInt(u32, .little);
            const inst_count = try interface.takeInt(u32, .little);
            const semantic_hash = try interface.takeInt(u64, .little);
            if (n_regs == 0 or n_cols == 0 or inst_count == 0 or inst_count > 1_000_000) return error.InvalidEntry;
            const label = try allocator.alloc(u8, label_len);
            errdefer allocator.free(label);
            try interface.readSliceAll(label);
            const insts = try allocator.alloc(program_mod.Inst, inst_count);
            errdefer allocator.free(insts);
            for (insts) |*inst| {
                inst.* = .{
                    .op = try interface.takeByte(),
                    .pad = try interface.takeByte(),
                    .dst = try interface.takeInt(u16, .little),
                    .a = try interface.takeInt(u32, .little),
                    .b = try interface.takeInt(u32, .little),
                    .imm = try interface.takeInt(u32, .little),
                };
            }
            const program = program_mod.Program{
                .insts = insts,
                .n_regs = n_regs,
                .n_inputs = n_inputs,
                .n_cols = n_cols,
                .n_mult_tables = n_mult_tables,
                .n_lookup_words = n_lookup_words,
                .n_sub_words = n_sub_words,
            };
            try program.validate();
            if (program.semanticHash() != semantic_hash) return error.SemanticHashMismatch;
            entries[initialized] = .{ .label = label, .semantic_hash = semantic_hash, .program = program };
        }
        var trailing: [1]u8 = undefined;
        if (try interface.readSliceShort(&trailing) != 0) return error.TrailingData;
        return .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(self: *Bundle) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.label);
            self.allocator.free(entry.program.insts);
        }
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn find(self: Bundle, label: []const u8) ?*const Entry {
        for (self.entries) |*entry| if (std.mem.eql(u8, entry.label, label)) return entry;
        return null;
    }
};

test "Cairo witness bundle: canonical SN2 programs load and validate" {
    var bundle = try Bundle.readFile(std.testing.allocator, "vectors/cairo/sn_pie_2_witness_programs.bin");
    defer bundle.deinit();
    try std.testing.expectEqual(@as(usize, 33), bundle.entries.len);
    const add = bundle.find("add_opcode") orelse return error.MissingProgram;
    try std.testing.expectEqual(@as(u64, 1528204113344186588), add.semantic_hash);
    try std.testing.expectEqual(@as(u32, 103), add.program.n_cols);
    const ec = bundle.find("partial_ec_mul_generic") orelse return error.MissingProgram;
    try std.testing.expectEqual(@as(u32, 14_382), ec.program.n_regs);
    try std.testing.expectEqual(@as(usize, 17_000), ec.program.insts.len);
}
