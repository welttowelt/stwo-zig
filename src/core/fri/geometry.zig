//! Protocol geometry for the fixed-step FRI folding schedule.

const std = @import("std");

pub const Error = error{BindingSizeMismatch};

pub const FriGeometry = struct {
    pub const round_count: usize = 8;
    pub const fold_step: u32 = 3;
    pub const final_log: u32 = 1;
    pub const packed_log: u32 = 2;

    start_log: u32,

    pub fn init(start_log: u32) Error!FriGeometry {
        if (start_log <= final_log or start_log < packed_log) return Error.BindingSizeMismatch;
        const folds = start_log - final_log;
        if ((folds + fold_step - 1) / fold_step != round_count) return Error.BindingSizeMismatch;
        return .{ .start_log = start_log };
    }

    pub fn evaluationLog(self: FriGeometry, round: usize) Error!u32 {
        if (round >= round_count) return Error.BindingSizeMismatch;
        return self.start_log - @as(u32, @intCast(round)) * fold_step;
    }

    pub fn cumulativeFold(_: FriGeometry, round: usize) Error!u32 {
        if (round >= round_count) return Error.BindingSizeMismatch;
        return @as(u32, @intCast(round)) * fold_step;
    }

    pub fn roundFold(self: FriGeometry, round: usize) Error!u32 {
        const evaluation_log = try self.evaluationLog(round);
        return @min(fold_step, evaluation_log - final_log);
    }

    pub fn leafLog(self: FriGeometry, round: usize) Error!u32 {
        return (try self.evaluationLog(round)) - packed_log;
    }

    pub fn layerCount(self: FriGeometry, round: usize) Error!usize {
        return @as(usize, try self.leafLog(round)) + 1;
    }

    pub fn totalLayerCount(self: FriGeometry) usize {
        var total: usize = 0;
        for (0..round_count) |round| total += self.layerCount(round) catch unreachable;
        return total;
    }

    pub fn inverseTwiddleWords(self: FriGeometry) u64 {
        return @as(u64, 1) << @intCast(self.start_log - 1);
    }
};

test "FRI geometry derives log-24 and log-25 rounds" {
    const log24 = try FriGeometry.init(24);
    try std.testing.expectEqual(@as(usize, 100), log24.totalLayerCount());
    try std.testing.expectEqual(@as(u64, 1) << 23, log24.inverseTwiddleWords());
    try std.testing.expectEqual(@as(u32, 24), try log24.evaluationLog(0));
    try std.testing.expectEqual(@as(u32, 3), try log24.evaluationLog(7));
    try std.testing.expectEqual(@as(u32, 2), try log24.roundFold(7));
    try std.testing.expectEqual(@as(u32, 22), try log24.leafLog(0));

    const log25 = try FriGeometry.init(25);
    try std.testing.expectEqual(@as(usize, 108), log25.totalLayerCount());
    try std.testing.expectEqual(@as(u64, 1) << 24, log25.inverseTwiddleWords());
    try std.testing.expectEqual(@as(u32, 25), try log25.evaluationLog(0));
    try std.testing.expectEqual(@as(u32, 4), try log25.evaluationLog(7));
    try std.testing.expectEqual(@as(u32, 3), try log25.roundFold(7));
    try std.testing.expectEqual(@as(u32, 23), try log25.leafLog(0));
    try std.testing.expectError(Error.BindingSizeMismatch, log25.leafLog(FriGeometry.round_count));
}
