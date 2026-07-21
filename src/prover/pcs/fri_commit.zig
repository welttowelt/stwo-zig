//! Backend-aware FRI commit dispatch kept outside the main scheme state machine.

const std = @import("std");
const circle_domain = @import("stwo_core").poly.circle.domain;
const prover_fri = @import("../fri.zig");
const quotient_ops = @import("quotient_ops.zig");

/// CPU backends that expose retained-twiddle folding receive the exact tree
/// already owned by the scheme. Other backends retain the original API/path.
pub fn commitLazy(
    comptime B: type,
    comptime H: type,
    comptime MC: type,
    allocator: std.mem.Allocator,
    channel: anytype,
    scheme: anytype,
    domain: circle_domain.CircleDomain,
    provider: *quotient_ops.LazyQuotientProvider,
) !prover_fri.FriProver(B, H, MC) {
    if (comptime @hasDecl(B, "foldLineNWithInvTwiddles")) {
        const tree = try scheme.twiddle_source.get(allocator, domain.logSize());
        return prover_fri.FriProver(B, H, MC).commitLazyWithTwiddles(
            allocator,
            channel,
            scheme.config.fri_config,
            domain,
            provider,
            tree,
        );
    }
    return prover_fri.FriProver(B, H, MC).commitLazy(
        allocator,
        channel,
        scheme.config.fri_config,
        domain,
        provider,
    );
}
