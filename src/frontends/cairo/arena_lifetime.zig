const std = @import("std");

pub const PhaseList = struct {
    items: [12]u16 = [_]u16{0} ** 12,
    len: usize,

    pub fn slice(self: *const PhaseList) []const u16 {
        return self.items[0..self.len];
    }
};

pub fn inferredUsePhases(purpose: []const u8, first: u16, last: u16) PhaseList {
    // The transcript is mutated throughout the protocol. The captured coarse
    // lifetime only names ingest and assembly, so retain every protocol phase.
    if (std.mem.eql(u8, purpose, "TranscriptState") or
        std.mem.eql(u8, purpose, "TranscriptInput") or
        std.mem.eql(u8, purpose, "TranscriptOutput"))
        return .{ .items = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }, .len = 12 };
    // These relation outputs are produced before tree 2 and consumed by the
    // composition input kernel after it. Keep them out of commitment scratch.
    if (std.mem.eql(u8, purpose, "RelationAlphaPowers") or
        std.mem.eql(u8, purpose, "RelationZ") or
        std.mem.eql(u8, purpose, "RelationClaimedSum"))
        return .{ .items = .{ 3, 4, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 3 };
    // Composition descriptors and extension parameters are populated just
    // before the composition dispatch, not during their captured ingest use.
    if (std.mem.eql(u8, purpose, "CompositionDescriptors") or
        std.mem.eql(u8, purpose, "CompositionExtParams"))
        return .{ .items = .{ 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 1 };
    // Composition coefficients feed tree 3, OODS, quotient, FRI, and the
    // decommitment path. The recompute recipe does not run between those
    // direct protocol calls, so every intervening phase is a real use.
    if (std.mem.eql(u8, purpose, "CompositionCoefficients"))
        return .{ .items = .{ 5, 6, 7, 8, 9, 10, 0, 0, 0, 0, 0, 0 }, .len = 6 };
    // This table is populated immediately before composition, then restored at
    // the FRI boundary. Its captured ingest/decommit endpoints omit both uses.
    if (std.mem.eql(u8, purpose, "InverseTwiddles"))
        return .{ .items = .{ 5, 9, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 3 };
    // This table is populated immediately before quotient interpolation. The
    // captured Ingest-to-Decommit lifetime does not describe its actual use.
    if (std.mem.eql(u8, purpose, "QuotientInverseTwiddles"))
        return .{ .items = .{ 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 1 };
    // The quotient evaluation is the source of FRI round zero and is opened
    // again during decommitment. Keep it resident across that direct handoff.
    if (std.mem.eql(u8, purpose, "QuotientTile"))
        return .{ .items = .{ 8, 9, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 3 };
    if (std.mem.eql(u8, purpose, "WitnessInput") or std.mem.startsWith(u8, purpose, "WitnessInputCompact"))
        return .{ .items = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 1 };
    // Recorded components use DAG-derived staged roles. Native memory and
    // fixed-table relation sources have no proof-plan component, so rebuild
    // their base evaluation columns at their interaction tick.
    if (std.mem.eql(u8, purpose, "BaseTrace"))
        return .{ .items = .{ 1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 2 };
    if (std.mem.eql(u8, purpose, "LookupInputs"))
        return .{ .items = .{ 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 1 };
    if (std.mem.eql(u8, purpose, "BaseCoefficients")) return .{ .items = .{ 1, 2, 5, 7, 8, 10, 0, 0, 0, 0, 0, 0 }, .len = 6 };
    if (std.mem.eql(u8, purpose, "InteractionTrace")) return .{ .items = .{ 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 1 };
    if (std.mem.eql(u8, purpose, "InteractionCoefficients")) return .{ .items = .{ 3, 4, 5, 7, 8, 10, 0, 0, 0, 0, 0, 0 }, .len = 6 };
    if (std.mem.eql(u8, purpose, "PreprocessedCoefficients")) return .{ .items = .{ 0, 5, 7, 8, 10, 0, 0, 0, 0, 0, 0, 0 }, .len = 5 };
    if (std.mem.eql(u8, purpose, "CommitRetainedEvaluation")) return .{ .items = .{ 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 1 };

    var result = PhaseList{ .len = 1 };
    result.items[0] = first;
    if (last != first) {
        result.items[1] = last;
        result.len = 2;
    }
    return result;
}
