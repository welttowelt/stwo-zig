//! Complete prover transaction contract shared by native and device backends.

const std = @import("std");
const pcs_core = @import("../core/pcs/mod.zig");
const proof = @import("../core/proof.zig");
const component = @import("air/component_prover.zig");
const pcs = @import("pcs/mod.zig");
const prove_mod = @import("prove.zig");
const stage_profile = @import("stage_profile.zig");

pub const ProveOptions = struct {
    include_all_preprocessed_columns: bool = false,
    recorder: ?*stage_profile.Recorder = null,
};

/// Checks the transaction-level surface expected by backend-neutral frontends.
pub fn assertProverEngine(comptime Engine: type) void {
    comptime {
        if (!@hasDecl(Engine, "Scheme")) @compileError("prover engine requires Scheme");
        if (!@hasDecl(Engine, "init")) @compileError("prover engine requires init");
        if (!@hasDecl(Engine, "commit")) @compileError("prover engine requires commit");
        if (!@hasDecl(Engine, "prove")) @compileError("prover engine requires prove");
    }
}

/// Builds a complete proving engine from a PCS backend and protocol types.
///
/// `commit` consumes its column slice and `prove` consumes the scheme. This
/// keeps ownership identical for host and resident-device implementations.
pub fn ProverEngine(
    comptime B: type,
    comptime H: type,
    comptime MC: type,
    comptime C: type,
) type {
    return struct {
        pub const Backend = B;
        pub const Hasher = H;
        pub const MerkleChannel = MC;
        pub const Channel = C;
        pub const Scheme = pcs.CommitmentSchemeProver(B, H, MC);
        pub const ExtendedProof = proof.ExtendedStarkProof(H);
        pub const TelemetrySnapshot = if (@hasDecl(B, "TelemetrySnapshot")) B.TelemetrySnapshot else void;
        pub const TelemetryError = if (@hasDecl(B, "TelemetryError")) B.TelemetryError else error{};

        pub fn init(allocator: std.mem.Allocator, config: pcs_core.PcsConfig) !Scheme {
            return Scheme.init(allocator, config);
        }

        pub fn warmup() !void {
            if (comptime @hasDecl(B, "warmup")) try B.warmup();
        }

        pub fn telemetrySnapshot() TelemetryError!TelemetrySnapshot {
            if (comptime @hasDecl(B, "telemetrySnapshot")) return B.telemetrySnapshot();
        }

        pub fn commit(
            scheme: *Scheme,
            allocator: std.mem.Allocator,
            columns: []pcs.ColumnEvaluation,
            recorder: ?*stage_profile.Recorder,
            channel: *C,
        ) !void {
            return scheme.commitOwnedWithRecorder(allocator, columns, recorder, channel);
        }

        pub fn prove(
            allocator: std.mem.Allocator,
            components: []const component.ComponentProver,
            channel: *C,
            scheme: Scheme,
            options: ProveOptions,
        ) !ExtendedProof {
            return prove_mod.proveExWithRecorder(
                B,
                H,
                MC,
                allocator,
                components,
                channel,
                scheme,
                options.include_all_preprocessed_columns,
                options.recorder,
            );
        }
    };
}
