//! Ownership wrapper for the declaration-ordered Tree-2 columns.

const std = @import("std");
const M31 = @import("stwo_core").fields.m31.M31;
const prover_pcs = @import("stwo_prover_engine").pcs;

pub const Columns = struct {
    values: []prover_pcs.ColumnEvaluation,
    filled: usize,
    moved: bool,

    pub fn init(allocator: std.mem.Allocator, n_interaction: usize) !Columns {
        return .{
            .values = try allocator.alloc(prover_pcs.ColumnEvaluation, n_interaction),
            .filled = 0,
            .moved = false,
        };
    }

    pub fn append(self: *Columns, log_size: u32, values: []M31) void {
        self.values[self.filled] = .{ .log_size = log_size, .values = values };
        self.filled += 1;
    }

    /// Releases the filled prefix only while this array still owns it: after
    /// `moved` the commitment scheme does.
    pub fn deinit(self: *Columns, allocator: std.mem.Allocator) void {
        if (self.moved) return;
        for (self.values[0..self.filled]) |column| allocator.free(@constCast(column.values));
        allocator.free(self.values);
    }
};
