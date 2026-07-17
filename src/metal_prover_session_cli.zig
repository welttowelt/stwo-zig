const std = @import("std");
const artifact_manifest = @import("tools/metal_session/artifacts/manifest.zig");
const artifact_store = @import("tools/metal_session/artifacts/store.zig");
const artifact_views = @import("tools/metal_session/artifacts/views.zig");
const metal_runtime = @import("backends/metal/runtime.zig");
const cairo_adapted_input = @import("frontends/cairo/adapter/adapted_input.zig");
const cairo_opcodes = @import("frontends/cairo/adapter/opcodes.zig");
const compact_interchange = @import("frontends/cairo/compact_verifier_interchange.zig");
const composition_bundle = @import("frontends/cairo/witness/composition_bundle.zig");
const fixed_table_bundle = @import("frontends/cairo/witness/fixed_table_bundle.zig");
const one_shot = @import("metal_arena_plan_cli.zig");
const protocol = @import("metal_prover_session_protocol.zig");

const persistent_report_schema_version: u32 = 3;
const in_process_runner_linkage = "in_process";
const rust_verifier_adapter_version = "0.1.0";
const rust_verifier_envelope_abi = "STWZCVE/1";
const rust_verifier_mode = "compact_metal_proof_v1";
const rust_verifier_cargo_lock_sha256 = "72ee6a80235ff78a6e2c1724a8c6d1c45798c2a11c1c1539bc675af066b0e31c";
const rust_verifier_stwo_cairo_revision = "dcd5834565b7a26a27a614e353c9c60109ebc1d9";
const rust_verifier_stwo_revision = "9d7e3d6fa0fc64a0d143a8b2fcb8ee952f4de8f2";

const PreparedGeometryKey = [32]u8;

const RustVerifierConfig = struct {
    allocator: std.mem.Allocator,
    executable_path: []const u8,
    measurement: artifact_manifest.Measurement,
    executable_sha256: [64]u8,
    lockfile_path: []const u8,
    lockfile_measurement: artifact_manifest.Measurement,

    fn init(
        allocator: std.mem.Allocator,
        executable_path: []const u8,
        lockfile_path: []const u8,
        store_root: []const u8,
    ) !RustVerifierConfig {
        const source = try std.fs.realpathAlloc(allocator, executable_path);
        defer allocator.free(source);
        const source_measurement = try artifact_manifest.measureFile(allocator, source);
        const source_lockfile = try std.fs.realpathAlloc(allocator, lockfile_path);
        defer allocator.free(source_lockfile);
        const source_lockfile_measurement = try artifact_manifest.measureFile(allocator, source_lockfile);
        const lockfile_sha256 = std.fmt.bytesToHex(source_lockfile_measurement.sha256, .lower);
        if (!std.mem.eql(u8, &lockfile_sha256, rust_verifier_cargo_lock_sha256))
            return error.InvalidRustVerifierLockfile;
        const canonical = try std.fs.path.join(allocator, &.{ store_root, "rust-verifier-adapter" });
        errdefer allocator.free(canonical);
        const measurement = try copyFileExclusive(allocator, source, canonical, 0o500);
        errdefer std.fs.deleteFileAbsolute(canonical) catch {};
        if (measurement.bytes != source_measurement.bytes or
            !std.mem.eql(u8, &measurement.sha256, &source_measurement.sha256))
            return error.RustVerifierCopyMismatch;
        const canonical_lockfile = try std.fs.path.join(
            allocator,
            &.{ store_root, "rust-verifier.Cargo.lock" },
        );
        errdefer allocator.free(canonical_lockfile);
        const lockfile_measurement = try copyFileExclusive(
            allocator,
            source_lockfile,
            canonical_lockfile,
            0o400,
        );
        errdefer std.fs.deleteFileAbsolute(canonical_lockfile) catch {};
        if (lockfile_measurement.bytes != source_lockfile_measurement.bytes or
            !std.mem.eql(u8, &lockfile_measurement.sha256, &source_lockfile_measurement.sha256))
            return error.RustVerifierLockfileCopyMismatch;
        return .{
            .allocator = allocator,
            .executable_path = canonical,
            .measurement = measurement,
            .executable_sha256 = std.fmt.bytesToHex(measurement.sha256, .lower),
            .lockfile_path = canonical_lockfile,
            .lockfile_measurement = lockfile_measurement,
        };
    }

    fn deinit(self: *RustVerifierConfig) void {
        self.allocator.free(self.executable_path);
        self.allocator.free(self.lockfile_path);
        self.* = undefined;
    }

    fn assertUnchanged(self: RustVerifierConfig) !void {
        const current = try artifact_manifest.measureFile(self.allocator, self.executable_path);
        if (!current.identity.eql(self.measurement.identity) or
            !std.mem.eql(u8, &current.sha256, &self.measurement.sha256))
            return error.RustVerifierIdentityChanged;
        const current_lockfile = try artifact_manifest.measureFile(self.allocator, self.lockfile_path);
        if (!current_lockfile.identity.eql(self.lockfile_measurement.identity) or
            !std.mem.eql(u8, &current_lockfile.sha256, &self.lockfile_measurement.sha256))
            return error.RustVerifierLockfileChanged;
    }
};

const RustVerifierEvidence = struct {
    protocol_digest: [64]u8,
    statement_digest: [64]u8,
    proof_digest: [64]u8,
    provenance_digest: [64]u8,
    executable_sha256: [64]u8,
    wall_time_ns: u64,
    service_wall_time_ns: u64,
    result_sha256: [64]u8,

    pub fn jsonStringify(self: RustVerifierEvidence, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("schema_version");
        try writer.write(1);
        try writer.objectField("status");
        try writer.write("passed");
        try writer.objectField("verified");
        try writer.write(true);
        try writer.objectField("envelope_abi");
        try writer.write(rust_verifier_envelope_abi);
        try writer.objectField("adapter_version");
        try writer.write(rust_verifier_adapter_version);
        try writer.objectField("verification_mode");
        try writer.write(rust_verifier_mode);
        try writer.objectField("protocol_digest");
        try writer.write(&self.protocol_digest);
        try writer.objectField("statement_digest");
        try writer.write(&self.statement_digest);
        try writer.objectField("proof_digest");
        try writer.write(&self.proof_digest);
        try writer.objectField("provenance_digest");
        try writer.write(&self.provenance_digest);
        try writer.objectField("executable_sha256");
        try writer.write(&self.executable_sha256);
        try writer.objectField("cargo_lock_sha256");
        try writer.write(rust_verifier_cargo_lock_sha256);
        try writer.objectField("stwo_cairo_revision");
        try writer.write(rust_verifier_stwo_cairo_revision);
        try writer.objectField("stwo_revision");
        try writer.write(rust_verifier_stwo_revision);
        try writer.objectField("wall_time_ns");
        try writer.write(self.wall_time_ns);
        try writer.objectField("service_wall_time_ns");
        try writer.write(self.service_wall_time_ns);
        try writer.objectField("result_sha256");
        try writer.write(&self.result_sha256);
        try writer.endObject();
    }
};

const PreparedGeometryPolicy = struct {
    replay_retained_lookups: bool,
};

const prepared_host_geometry_capacity = 4;

const PreparedHostGeometryEntry = struct {
    key: PreparedGeometryKey,
    geometry: *one_shot.PreparedHostGeometry,
    last_used: u64,
};

const PreparedHostGeometryAcquire = struct {
    geometry: *const one_shot.PreparedHostGeometry,
    cache_hit: bool,
};

const PreparedHostGeometryTransaction = union(enum) {
    none,
    hit: u8,
    pending: struct {
        key: PreparedGeometryKey,
        geometry: *one_shot.PreparedHostGeometry,
    },
};

const PreparedHostGeometryCache = struct {
    allocator: std.mem.Allocator,
    entries: [prepared_host_geometry_capacity]?PreparedHostGeometryEntry =
        [_]?PreparedHostGeometryEntry{null} ** prepared_host_geometry_capacity,
    active: PreparedHostGeometryTransaction = .none,
    clock: u64 = 0,

    fn init(allocator: std.mem.Allocator) PreparedHostGeometryCache {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *PreparedHostGeometryCache) void {
        self.poison();
        for (&self.entries) |*entry| {
            if (entry.*) |value| value.geometry.deinit();
            entry.* = null;
        }
        self.* = undefined;
    }

    fn begin(
        self: *PreparedHostGeometryCache,
        key: PreparedGeometryKey,
        args: []const []const u8,
    ) !PreparedHostGeometryAcquire {
        if (self.active != .none) return error.PreparedHostGeometryAlreadyBorrowed;
        for (&self.entries, 0..) |*entry, index| {
            const value = if (entry.*) |*candidate| candidate else continue;
            if (!std.mem.eql(u8, &value.key, &key)) continue;
            const slot: u8 = @intCast(index);
            self.active = .{ .hit = slot };
            return .{ .geometry = value.geometry, .cache_hit = true };
        }
        const geometry = try one_shot.PreparedHostGeometry.init(self.allocator, args);
        self.active = .{ .pending = .{ .key = key, .geometry = geometry } };
        return .{ .geometry = geometry, .cache_hit = false };
    }

    fn commit(self: *PreparedHostGeometryCache) !void {
        try self.validateCommit();
        self.commitAssumeValid();
    }

    fn commitAssumeValid(self: *PreparedHostGeometryCache) void {
        switch (self.active) {
            .none => unreachable,
            .hit => |raw_index| {
                const index: usize = raw_index;
                self.clock = self.clock +| 1;
                self.entries[index].?.last_used = self.clock;
            },
            .pending => |pending| {
                const index = self.chooseVictim();
                if (self.entries[index]) |value| value.geometry.deinit();
                self.clock = self.clock +| 1;
                self.entries[index] = .{
                    .key = pending.key,
                    .geometry = pending.geometry,
                    .last_used = self.clock,
                };
            },
        }
        self.active = .none;
    }

    fn validateCommit(self: *const PreparedHostGeometryCache) !void {
        switch (self.active) {
            .none => return error.PreparedHostGeometryNotBorrowed,
            .hit => |raw_index| if (self.entries[raw_index] == null)
                return error.PreparedHostGeometryNotBorrowed,
            .pending => {},
        }
    }

    fn poison(self: *PreparedHostGeometryCache) void {
        switch (self.active) {
            .none, .hit => {},
            .pending => |pending| pending.geometry.deinit(),
        }
        self.active = .none;
    }

    fn chooseVictim(self: *const PreparedHostGeometryCache) usize {
        for (self.entries, 0..) |entry, index| if (entry == null) return index;
        var victim: usize = 0;
        for (self.entries[1..], 1..) |entry, index| {
            if (entry.?.last_used < self.entries[victim].?.last_used) victim = index;
        }
        return victim;
    }
};

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const ProofResult = struct {
    adapted_cycles: u64,
    adapted_input_sha256: [64]u8,
    prove_wall_s: f64,
    prove_mhz: f64,
    session_block_wall_s: f64,
    proof_bytes: u64,
    proof_sha256: [64]u8,
    pipeline_cache_delta: metal_runtime.PipelineCacheStats,
    provenance: ProvenanceEvidence,
    executable_identity: ExecutableIdentity,
    artifact_objects: ArtifactObjectsEvidence,
    prepared_state_cache_hit: bool,
    rust_verifier: RustVerifierEvidence,
};

const ArtifactObjectEvidence = struct {
    object_id: [32]u8,
    bytes: u64,
    diagnostic_path: []const u8,

    pub fn jsonStringify(self: ArtifactObjectEvidence, writer: anytype) !void {
        const digest_hex = std.fmt.bytesToHex(self.object_id, .lower);
        try writer.beginObject();
        try writer.objectField("object_id");
        try writer.write(&digest_hex);
        try writer.objectField("bytes");
        try writer.write(self.bytes);
        try writer.objectField("diagnostic_path");
        try writer.write(self.diagnostic_path);
        try writer.endObject();
    }
};

const ArtifactObjectsEvidence = struct {
    adapted_input: ArtifactObjectEvidence,
    schedule: ArtifactObjectEvidence,
    witness_programs: ArtifactObjectEvidence,
    multiplicity_feeds: ArtifactObjectEvidence,
    relation_templates: ArtifactObjectEvidence,
    fixed_tables: ArtifactObjectEvidence,
    composition: ArtifactObjectEvidence,
    composition_program: ArtifactObjectEvidence,
    preprocessed_evaluations: ArtifactObjectEvidence,
    preprocessed_tree0_merkle: ArtifactObjectEvidence,
    preprocessed_coefficients: ArtifactObjectEvidence,
    transcript_reference: ?ArtifactObjectEvidence,
    quotient_reference: ?ArtifactObjectEvidence,

    pub fn jsonStringify(self: ArtifactObjectsEvidence, writer: anytype) !void {
        try writer.beginObject();
        inline for (.{
            "adapted_input",
            "schedule",
            "witness_programs",
            "multiplicity_feeds",
            "relation_templates",
            "fixed_tables",
            "composition",
            "composition_program",
            "preprocessed_evaluations",
            "preprocessed_tree0_merkle",
            "preprocessed_coefficients",
        }) |name| {
            try writer.objectField(name);
            try writer.write(@field(self, name));
        }
        if (self.transcript_reference) |value| {
            try writer.objectField("transcript_reference");
            try writer.write(value);
        }
        if (self.quotient_reference) |value| {
            try writer.objectField("quotient_reference");
            try writer.write(value);
        }
        try writer.endObject();
    }
};

const ExecutableIdentity = struct {
    // Content measurement only. Deployment policy must separately decide which
    // executable digest is authorized to serve production requests.
    daemon_executable_sha256: [64]u8,
    runner_executable_sha256: [64]u8,
    measurement: artifact_manifest.Measurement = undefined,
};

const ProvenanceEvidence = struct {
    self_contained: bool,
    parity_fixture_used: bool,
    proof_derived_artifact_used: bool,
    statement_self_derived: bool,
    artifact_manifest_digest: ?[64]u8,
    provenance_complete: bool,

    fn failClosed() ProvenanceEvidence {
        return .{
            .self_contained = false,
            .parity_fixture_used = true,
            .proof_derived_artifact_used = true,
            .statement_self_derived = false,
            .artifact_manifest_digest = null,
            .provenance_complete = false,
        };
    }
};

const EnvironmentValue = struct {
    name: []const u8,
    value: []const u8,
};

const VerifierScratch = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    proof: []const u8,
    statement: []const u8,
    runner_report: []const u8,
    envelope: []const u8,
    result: []const u8,

    fn init(
        allocator: std.mem.Allocator,
        store_root: []const u8,
        sequence: u64,
    ) !VerifierScratch {
        var nonce: [16]u8 = undefined;
        std.crypto.random.bytes(&nonce);
        const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
        const root = try std.fmt.allocPrint(
            allocator,
            "{s}/verify-{}-{s}",
            .{ store_root, sequence, &nonce_hex },
        );
        errdefer allocator.free(root);
        try std.posix.mkdir(root, 0o700);
        errdefer std.fs.deleteTreeAbsolute(root) catch {};
        var directory = try std.fs.openDirAbsolute(root, .{ .no_follow = true });
        defer directory.close();
        try directory.chmod(0o700);

        const proof = try std.fs.path.join(allocator, &.{ root, "proof.bin" });
        errdefer allocator.free(proof);
        const statement = try std.fs.path.join(allocator, &.{ root, "statement.bin" });
        errdefer allocator.free(statement);
        const runner_report = try std.fs.path.join(allocator, &.{ root, "runner-report.json" });
        errdefer allocator.free(runner_report);
        const envelope = try std.fs.path.join(allocator, &.{ root, "proof.stwzcve" });
        errdefer allocator.free(envelope);
        const result = try std.fs.path.join(allocator, &.{ root, "verifier-result.json" });
        errdefer allocator.free(result);
        return .{
            .allocator = allocator,
            .root = root,
            .proof = proof,
            .statement = statement,
            .runner_report = runner_report,
            .envelope = envelope,
            .result = result,
        };
    }

    fn deinit(self: *VerifierScratch) void {
        std.fs.deleteTreeAbsolute(self.root) catch {};
        self.allocator.free(self.proof);
        self.allocator.free(self.statement);
        self.allocator.free(self.runner_report);
        self.allocator.free(self.envelope);
        self.allocator.free(self.result);
        self.allocator.free(self.root);
        self.* = undefined;
    }
};

const ArtifactSlot = enum {
    adapted_input,
    schedule,
    witness_programs,
    multiplicity_feeds,
    relation_templates,
    fixed_tables,
    composition,
    composition_program,
    preprocessed_evaluations,
    preprocessed_tree0_merkle,
    preprocessed_coefficients,
    transcript_reference,
    quotient_reference,
};

const artifact_slot_count = std.meta.fields(ArtifactSlot).len;

const PreparedArtifacts = struct {
    snapshots: [artifact_slot_count]?artifact_store.Snapshot = .{null} ** artifact_slot_count,
    view: ?*const artifact_views.View = null,
    entries: [artifact_slot_count + 1]artifact_manifest.Entry = undefined,
    entry_count: usize = 0,
    tree0_root_hex: [64]u8 = undefined,

    fn deinit(self: *PreparedArtifacts, allocator: std.mem.Allocator) void {
        for (&self.snapshots) |*optional_snapshot|
            if (optional_snapshot.*) |*stored| stored.deinit(allocator);
        self.* = undefined;
    }

    fn snapshot(self: *const PreparedArtifacts, slot: ArtifactSlot) *const artifact_store.Snapshot {
        return &self.snapshots[@intFromEnum(slot)].?;
    }

    fn addSnapshot(
        self: *PreparedArtifacts,
        store: *artifact_store.Store,
        slot: ArtifactSlot,
        role: artifact_manifest.Role,
        reference: protocol.ArtifactRef,
        provenance: artifact_manifest.Provenance,
        policy: artifact_store.IngestPolicy,
    ) !void {
        const index = @intFromEnum(slot);
        if (self.snapshots[index] != null) return error.DuplicateArtifactSlot;
        self.snapshots[index] = switch (reference) {
            .path => |path| try store.ingestPathWithPolicy(path, policy),
            .object => |object| try store.resolveRef(.{
                .object_id = try parseObjectId(object.object_id),
                .bytes = object.bytes,
            }),
        };
        const snapshot_value = self.snapshots[index].?;
        self.entries[self.entry_count] = .{
            .role = role,
            .format_version = 1,
            .provenance = provenance,
            .measurement = snapshot_value.measurement,
            .source_chain_complete = false,
        };
        self.entry_count += 1;
    }

    fn runnerArtifacts(self: *const PreparedArtifacts) RunnerArtifacts {
        return .{
            .adapted_input = self.snapshot(.adapted_input).path,
            .schedule = self.snapshot(.schedule).path,
            .witness_programs = self.snapshot(.witness_programs).path,
            .multiplicity_feeds = self.snapshot(.multiplicity_feeds).path,
            .relation_templates = self.snapshot(.relation_templates).path,
            .fixed_tables = self.snapshot(.fixed_tables).path,
            .composition = self.view.?.composition,
            .composition_program = self.view.?.composition_program,
            .preprocessed_evaluations = self.view.?.preprocessed_evaluations,
            .preprocessed_tree0_merkle = self.view.?.preprocessed_tree0_merkle,
            .preprocessed_coefficients = self.snapshot(.preprocessed_coefficients).path,
            .transcript_reference = if (self.snapshots[@intFromEnum(ArtifactSlot.transcript_reference)]) |snapshot_value|
                snapshot_value.path
            else
                null,
            .quotient_reference = if (self.snapshots[@intFromEnum(ArtifactSlot.quotient_reference)]) |snapshot_value|
                snapshot_value.path
            else
                null,
        };
    }

    fn objectEvidence(
        self: *const PreparedArtifacts,
        slot: ArtifactSlot,
        reference: protocol.ArtifactRef,
    ) ArtifactObjectEvidence {
        const stored = self.snapshot(slot);
        return .{
            .object_id = stored.object_id,
            .bytes = stored.measurement.bytes,
            .diagnostic_path = reference.diagnosticPath(),
        };
    }

    fn objectEvidenceOptional(
        self: *const PreparedArtifacts,
        slot: ArtifactSlot,
        reference: ?protocol.ArtifactRef,
    ) ?ArtifactObjectEvidence {
        return if (reference) |value| self.objectEvidence(slot, value) else null;
    }

    fn artifactObjects(
        self: *const PreparedArtifacts,
        artifacts: protocol.Artifacts,
    ) ArtifactObjectsEvidence {
        return .{
            .adapted_input = self.objectEvidence(.adapted_input, artifacts.adapted_input),
            .schedule = self.objectEvidence(.schedule, artifacts.schedule),
            .witness_programs = self.objectEvidence(.witness_programs, artifacts.witness_programs),
            .multiplicity_feeds = self.objectEvidence(.multiplicity_feeds, artifacts.multiplicity_feeds),
            .relation_templates = self.objectEvidence(.relation_templates, artifacts.relation_templates),
            .fixed_tables = self.objectEvidence(.fixed_tables, artifacts.fixed_tables),
            .composition = self.objectEvidence(.composition, artifacts.composition),
            .composition_program = self.objectEvidence(.composition_program, artifacts.composition_program),
            .preprocessed_evaluations = self.objectEvidence(.preprocessed_evaluations, artifacts.preprocessed_evaluations),
            .preprocessed_tree0_merkle = self.objectEvidence(.preprocessed_tree0_merkle, artifacts.preprocessed_tree0_merkle),
            .preprocessed_coefficients = self.objectEvidence(.preprocessed_coefficients, artifacts.preprocessed_coefficients),
            .transcript_reference = self.objectEvidenceOptional(.transcript_reference, artifacts.transcript_reference),
            .quotient_reference = self.objectEvidenceOptional(.quotient_reference, artifacts.quotient_reference),
        };
    }
};

const RunnerArtifacts = struct {
    adapted_input: []const u8,
    schedule: []const u8,
    witness_programs: []const u8,
    multiplicity_feeds: []const u8,
    relation_templates: []const u8,
    fixed_tables: []const u8,
    composition: []const u8,
    composition_program: []const u8,
    preprocessed_evaluations: []const u8,
    preprocessed_tree0_merkle: []const u8,
    preprocessed_coefficients: []const u8,
    transcript_reference: ?[]const u8,
    quotient_reference: ?[]const u8,
};

const RunnerRequest = struct {
    sequence: u64,
    request_id: []const u8,
    artifacts: RunnerArtifacts,
    proof_output: []const u8,
    report_output: []const u8,
    budget_gib: []const u8,
    tree0_root_hex: []const u8,
};

const ViewKey = struct {
    preprocessed_evaluations: [32]u8,
    preprocessed_tree0_merkle: [32]u8,
    composition: [32]u8,
    composition_program: [32]u8,
    composition_program_kind: u8,
};

const ViewCache = struct {
    allocator: std.mem.Allocator,
    views: std.AutoHashMap(ViewKey, artifact_views.View),

    fn init(allocator: std.mem.Allocator) ViewCache {
        return .{
            .allocator = allocator,
            .views = std.AutoHashMap(ViewKey, artifact_views.View).init(allocator),
        };
    }

    fn deinit(self: *ViewCache) void {
        var iterator = self.views.valueIterator();
        while (iterator.next()) |view| view.deinit(self.allocator);
        self.views.deinit();
        self.* = undefined;
    }

    fn getOrCreate(
        self: *ViewCache,
        parent_directory: []const u8,
        request_name: []const u8,
        inputs: artifact_views.Inputs,
    ) !*const artifact_views.View {
        const program_object = switch (inputs.composition_program) {
            .metal => |object| object,
            .metallib => |object| object,
        };
        const program_kind: u8 = switch (inputs.composition_program) {
            .metal => 0,
            .metallib => 1,
        };
        const key = ViewKey{
            .preprocessed_evaluations = inputs.preprocessed_evaluations.object_id,
            .preprocessed_tree0_merkle = inputs.preprocessed_tree0_merkle.object_id,
            .composition = inputs.composition.object_id,
            .composition_program = program_object.object_id,
            .composition_program_kind = program_kind,
        };
        if (self.views.getPtr(key)) |view| {
            if (inputs.expected_tree0_root) |expected|
                if (!std.mem.eql(u8, &view.tree0_root, &expected)) return error.Tree0RootMismatch;
            return view;
        }
        var view = try artifact_views.create(
            self.allocator,
            parent_directory,
            request_name,
            inputs,
            true,
        );
        errdefer view.deinit(self.allocator);
        try self.views.putNoClobber(key, view);
        return self.views.getPtr(key).?;
    }
};

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 6 or
        !std.mem.eql(u8, args[1], "--jsonl") or
        !std.mem.eql(u8, args[2], "--rust-verifier") or
        !std.mem.eql(u8, args[4], "--rust-verifier-lockfile"))
        return error.InvalidArguments;
    const executable_identity = try measureExecutableIdentity(allocator);

    var runtime = try metal_runtime.Runtime.init();
    defer runtime.deinit();
    const artifact_root = try std.fmt.allocPrint(
        allocator,
        "/private/tmp/stwo-zig-metal-artifacts-{}-{}",
        .{ std.c.getpid(), std.time.nanoTimestamp() },
    );
    defer allocator.free(artifact_root);
    var store = try artifact_store.Store.initNew(allocator, artifact_root, true);
    defer store.deinit();
    var rust_verifier = try RustVerifierConfig.init(allocator, args[3], args[5], store.root_path);
    defer rust_verifier.deinit();
    var views = ViewCache.init(allocator);
    defer views.deinit();
    var prepared_state = one_shot.PreparedStateCache.init(allocator);
    defer prepared_state.deinit();
    var prepared_host_geometry = PreparedHostGeometryCache.init(allocator);
    defer prepared_host_geometry.deinit();

    const input_buffer = try allocator.alloc(u8, protocol.max_frame_bytes);
    defer allocator.free(input_buffer);
    var input = std.fs.File.stdin().reader(input_buffer);
    var output_buffer: [16 * 1024]u8 = undefined;
    var output = std.fs.File.stdout().writer(&output_buffer);
    const writer = &output.interface;

    const session_id = try std.fmt.allocPrint(
        allocator,
        "metal-{}-{}",
        .{ std.c.getpid(), std.time.nanoTimestamp() },
    );
    defer allocator.free(session_id);
    try writeFrame(writer, .{
        .protocol = protocol.protocol_name,
        .version = protocol.protocol_version,
        .type = "ready",
        .session_id = session_id,
        .daemon_executable_sha256 = &executable_identity.daemon_executable_sha256,
        .runner_executable_sha256 = &executable_identity.runner_executable_sha256,
        .runner_linkage = in_process_runner_linkage,
        .rust_verifier = .{
            .required = true,
            .schema_version = 1,
            .envelope_abi = rust_verifier_envelope_abi,
            .adapter_version = rust_verifier_adapter_version,
            .executable_sha256 = &rust_verifier.executable_sha256,
            .cargo_lock_sha256 = rust_verifier_cargo_lock_sha256,
            .stwo_cairo_revision = rust_verifier_stwo_cairo_revision,
            .stwo_revision = rust_verifier_stwo_revision,
            .verification_mode = rust_verifier_mode,
        },
        .capabilities = .{
            .strict_order = true,
            .atomic_outputs = true,
            .verified_proofs = true,
            .runtime_reuse = true,
            .resident_arena_reuse = true,
            .preprocessed_state_reuse = true,
        },
    });

    var next_sequence: u64 = 0;
    while (try input.interface.takeDelimiter('\n')) |line| {
        if (line.len == 0) return error.EmptyFrame;
        switch (try protocol.frameKind(allocator, line)) {
            .shutdown => {
                try protocol.validateShutdown(allocator, line, next_sequence);
                try writeFrame(writer, .{
                    .protocol = protocol.protocol_name,
                    .version = protocol.protocol_version,
                    .type = "closed",
                    .completed = next_sequence,
                });
                return;
            },
            .prove => {
                var parsed = try protocol.parseRequest(allocator, line, next_sequence, true);
                defer parsed.deinit();
                const request = parsed.request;
                const result = proveRequest(
                    allocator,
                    &runtime,
                    &store,
                    &views,
                    &prepared_state,
                    &prepared_host_geometry,
                    request,
                    executable_identity,
                    rust_verifier,
                ) catch |err| {
                    try writeFrame(writer, .{
                        .protocol = protocol.protocol_name,
                        .version = protocol.protocol_version,
                        .type = "error",
                        .sequence = request.sequence,
                        .request_id = request.request_id,
                        .code = @errorName(err),
                        .message = "proof request failed before verified outputs were committed",
                    });
                    return err;
                };
                try writeVerifiedResultFrame(writer, request, result);
                next_sequence += 1;
            },
        }
    }
    return error.UncleanEndOfStream;
}

fn proveRequest(
    allocator: std.mem.Allocator,
    runtime: *metal_runtime.Runtime,
    store: *artifact_store.Store,
    views: *ViewCache,
    prepared_state: *one_shot.PreparedStateCache,
    prepared_host_geometry: *PreparedHostGeometryCache,
    request: protocol.Request,
    executable_identity: ExecutableIdentity,
    rust_verifier: RustVerifierConfig,
) !ProofResult {
    var block_timer = try std.time.Timer.start();
    const pipeline_cache_before = runtime.pipelineCacheStats();
    const diagnostic_adapted_input = try allocator.dupe(
        u8,
        request.artifacts.adapted_input.diagnosticPath(),
    );
    defer allocator.free(diagnostic_adapted_input);
    var prepared = try prepareArtifacts(allocator, store, views, request, executable_identity.measurement);
    defer prepared.deinit(allocator);
    const artifact_admission_wall_s = nanosecondsToSeconds(block_timer.read());
    const artifact_objects = prepared.artifactObjects(request.artifacts);
    const adapted_geometry_started_ns = block_timer.read();
    const adapted_geometry = try adaptedGeometry(
        prepared.snapshot(.adapted_input).path,
        artifact_objects.adapted_input.bytes,
    );
    const adapted_geometry_fingerprint_wall_s = nanosecondsToSeconds(
        block_timer.read() - adapted_geometry_started_ns,
    );
    const prepared_state_key = try preparedStateKey(
        artifact_objects,
        prepared.tree0_root_hex,
        request.budget_gib,
        try compositionProgramKind(prepared.runnerArtifacts().composition_program),
        executable_identity.measurement.sha256,
        try canonicalProofProtocolDigest(),
    );
    const prepared_geometry_key = preparedGeometryKey(
        prepared_state_key,
        adapted_geometry.fingerprint,
        .{ .replay_retained_lookups = true },
    );
    const adapted_geometry_fingerprint_sha256 = std.fmt.bytesToHex(
        adapted_geometry.fingerprint,
        .lower,
    );
    const prepared_geometry_key_sha256 = std.fmt.bytesToHex(prepared_geometry_key, .lower);
    const adapted_snapshot = prepared.snapshot(.adapted_input);
    const adapted_input_digest = adapted_snapshot.measurement.sha256;
    const adapted_input_sha256 = std.fmt.bytesToHex(adapted_input_digest, .lower);
    const proof_protocol_digest = try canonicalProofProtocolDigest();
    var manifest_entries: [artifact_slot_count + 3]artifact_manifest.Entry = undefined;
    @memcpy(manifest_entries[0..prepared.entry_count], prepared.entries[0..prepared.entry_count]);
    var manifest_entry_count = prepared.entry_count;
    manifest_entries[manifest_entry_count] = .{
        .role = .verifier_executable,
        .format_version = 1,
        .provenance = .unattested,
        .measurement = rust_verifier.measurement,
        .source_chain_complete = false,
    };
    manifest_entry_count += 1;
    manifest_entries[manifest_entry_count] = .{
        .role = .verifier_lockfile,
        .format_version = 1,
        .provenance = .unattested,
        .measurement = rust_verifier.lockfile_measurement,
        .source_chain_complete = false,
    };
    manifest_entry_count += 1;
    const manifest = try artifact_manifest.Manifest.build(
        allocator,
        proof_protocol_digest,
        manifest_entries[0..manifest_entry_count],
    );
    const manifest_digest_hex = std.fmt.bytesToHex(manifest.sha256, .lower);
    const runner_request = RunnerRequest{
        .sequence = request.sequence,
        .request_id = request.request_id,
        .artifacts = prepared.runnerArtifacts(),
        .proof_output = request.proof_output,
        .report_output = request.report_output,
        .budget_gib = request.budget_gib,
        .tree0_root_hex = &prepared.tree0_root_hex,
    };
    var verifier_scratch = try VerifierScratch.init(allocator, store.root_path, request.sequence);
    defer verifier_scratch.deinit();
    const proof_temporary = try temporaryPath(allocator, request.proof_output, request.sequence, "proof");
    defer allocator.free(proof_temporary);
    defer std.fs.deleteFileAbsolute(proof_temporary) catch {};
    const report_temporary = try temporaryPath(allocator, request.report_output, request.sequence, "report");
    defer allocator.free(report_temporary);
    defer std.fs.deleteFileAbsolute(report_temporary) catch {};
    try requireAbsent(proof_temporary);
    try requireAbsent(report_temporary);

    try configureEnvironment(
        allocator,
        runner_request,
        runner_request.artifacts.adapted_input,
        verifier_scratch.proof,
        verifier_scratch.statement,
    );
    const runner_args = [_][]const u8{
        "metal-arena-plan",
        runner_request.artifacts.schedule,
        runner_request.budget_gib,
        runner_request.artifacts.witness_programs,
        runner_request.artifacts.multiplicity_feeds,
        runner_request.artifacts.relation_templates,
        runner_request.artifacts.fixed_tables,
        runner_request.artifacts.composition,
    };
    const cli_report_file = try std.fs.createFileAbsolute(verifier_scratch.runner_report, .{
        .read = true,
        .exclusive = true,
    });
    defer cli_report_file.close();
    var report_buffer: [16 * 1024]u8 = undefined;
    var cli_report_writer = cli_report_file.writer(&report_buffer);
    const prepared_geometry_started_ns = block_timer.read();
    const prepared_geometry_acquire = try prepared_host_geometry.begin(
        prepared_geometry_key,
        &runner_args,
    );
    const prepared_host_geometry_acquire_wall_s = nanosecondsToSeconds(
        block_timer.read() - prepared_geometry_started_ns,
    );
    var prepared_geometry_borrowed = true;
    errdefer if (prepared_geometry_borrowed) prepared_host_geometry.poison();
    var prepared_state_borrowed = true;
    errdefer if (prepared_state_borrowed) prepared_state.poison();
    const runner_started_ns = block_timer.read();
    try one_shot.proveOnePreparedGeometry(
        allocator,
        &runner_args,
        runtime,
        prepared_state,
        prepared_state_key,
        prepared_geometry_acquire.geometry,
        &cli_report_writer.interface,
    );
    try cli_report_writer.interface.flush();
    try cli_report_file.sync();
    const runner_finished_ns = block_timer.read();

    try cli_report_file.seekTo(0);
    const encoded_cli_report = try cli_report_file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(encoded_cli_report);
    const cli_report = try std.json.parseFromSlice(std.json.Value, allocator, encoded_cli_report, .{});
    defer cli_report.deinit();
    if (cli_report.value != .object) return error.InvalidCliReport;
    const cli_object = cli_report.value.object;
    if (!try boolField(cli_object, "proof_verified")) return error.UnverifiedProof;
    if (!try boolField(cli_object, "proof_bundle_valid")) return error.InvalidProofBundle;
    try requireCanonicalCliProtocol(cli_object);
    const timing_scope = try stringField(cli_object, "prove_timing_scope");
    if (!std.mem.eql(u8, timing_scope, protocol.prove_timing_scope)) return error.InvalidProveTiming;
    const prove_wall_s = try positiveNumberField(cli_object, "prove_wall_s");
    const runner_provenance = cliProvenance(cli_object);
    const manifest_classification = artifact_manifest.classify(manifest.entries);
    const provenance = ProvenanceEvidence{
        .self_contained = runner_provenance.self_contained and
            manifest_classification.production_source_chain_complete,
        .parity_fixture_used = runner_provenance.parity_fixture_used or
            manifest_classification.parity_fixture_used,
        .proof_derived_artifact_used = runner_provenance.proof_derived_artifact_used or
            manifest_classification.proof_derived_artifact_used,
        .statement_self_derived = runner_provenance.statement_self_derived,
        .artifact_manifest_digest = manifest_digest_hex,
        .provenance_complete = true,
    };

    const counts = adapted_geometry.counts;
    if (counts.cycles == 0) return error.InvalidAdaptedCycles;
    var retained_adapted = try store.resolveRef(adapted_snapshot.ref());
    retained_adapted.deinit(allocator);
    const prove_mhz = @as(f64, @floatFromInt(counts.cycles)) / prove_wall_s / 1_000_000.0;
    const proof_file = try std.fs.openFileAbsolute(verifier_scratch.proof, .{ .mode = .read_write });
    const proof_stat = try proof_file.stat();
    if (proof_stat.kind != .file or proof_stat.size == 0) {
        proof_file.close();
        return error.InvalidProofOutput;
    }
    const reported_proof_bytes = try positiveIntegerField(cli_object, "proof_output_bytes");
    if (reported_proof_bytes != proof_stat.size) {
        proof_file.close();
        return error.InvalidProofOutput;
    }
    try proof_file.sync();
    proof_file.close();
    const proof_digest = try hashFile(allocator, verifier_scratch.proof);
    const proof_sha256 = std.fmt.bytesToHex(proof_digest, .lower);
    const runtime_protocol = try compactRuntimeProtocolFromArtifacts(
        allocator,
        runner_request.artifacts.composition,
        runner_request.artifacts.fixed_tables,
    );
    const compact_protocol = try (try cliProofLayout(cli_object)).protocolRuntime(
        one_shot.canonical_protocol.channel_salt,
        runtime_protocol.geometry,
        runtime_protocol.trace_columns,
    );
    var envelope_summary: compact_interchange.EnvelopeSummary = undefined;
    {
        const envelope_file = try std.fs.createFileAbsolute(verifier_scratch.envelope, .{
            .read = true,
            .exclusive = true,
            .mode = 0o600,
        });
        defer envelope_file.close();
        var envelope_buffer: [64 * 1024]u8 = undefined;
        var envelope_writer = envelope_file.writer(&envelope_buffer);
        envelope_summary = try compact_interchange.writeEnvelopeFromPathsV1(
            allocator,
            &envelope_writer.interface,
            compact_protocol,
            verifier_scratch.statement,
            verifier_scratch.proof,
            .{
                .adapted_input_sha256 = &adapted_input_sha256,
                .artifact_manifest_sha256 = &manifest_digest_hex,
                .runner_executable_sha256 = &executable_identity.runner_executable_sha256,
                .backend_executable_sha256 = &executable_identity.daemon_executable_sha256,
            },
        );
        try envelope_writer.interface.flush();
        try envelope_file.sync();
    }
    if (!std.mem.eql(u8, &envelope_summary.proof_sha256, &proof_digest))
        return error.EnvelopeProofDigestMismatch;
    const rust_verifier_evidence = try runRustVerifier(
        allocator,
        rust_verifier,
        verifier_scratch.envelope,
        verifier_scratch.result,
        envelope_summary,
    );
    const staged_proof = try copyFileExclusive(
        allocator,
        verifier_scratch.proof,
        proof_temporary,
        0o600,
    );
    if (staged_proof.bytes != proof_stat.size or
        !std.mem.eql(u8, &staged_proof.sha256, &proof_digest))
        return error.StagedProofMismatch;
    try prepared_state.commit();
    const prepared_state_telemetry = prepared_state.requestTelemetry();
    const pipeline_cache_delta = cacheDelta(runtime.pipelineCacheStats(), pipeline_cache_before);
    const finalization_started_ns = block_timer.read();
    const final_report_file = try std.fs.createFileAbsolute(report_temporary, .{
        .read = true,
        .exclusive = true,
        .mode = 0o600,
    });
    defer final_report_file.close();
    var final_report_buffer: [16 * 1024]u8 = undefined;
    var final_report_writer = final_report_file.writer(&final_report_buffer);
    const artifact_manifest_digest: ?[]const u8 = &provenance.artifact_manifest_digest.?;
    try std.json.Stringify.value(.{
        .schema_version = persistent_report_schema_version,
        .benchmark = "persistent_sn_pie_metal_gate",
        .mode = "full-proof",
        .status = "completed",
        .proof_verified = true,
        .proving_speed_verified = true,
        .self_contained = provenance.self_contained,
        .parity_fixture_used = provenance.parity_fixture_used,
        .proof_derived_artifact_used = provenance.proof_derived_artifact_used,
        .statement_self_derived = provenance.statement_self_derived,
        .artifact_manifest_digest = artifact_manifest_digest,
        .artifact_manifest = artifact_manifest.JsonEvidence{ .manifest = &manifest },
        .artifact_objects = artifact_objects,
        .adapted_geometry_fingerprint_sha256 = &adapted_geometry_fingerprint_sha256,
        .prepared_geometry_key_sha256 = &prepared_geometry_key_sha256,
        .prepared_host_geometry_cache_hit = prepared_geometry_acquire.cache_hit,
        .prepared_state_cache_hit = prepared_state_telemetry.cache_hit,
        .prepared_state = prepared_state_telemetry,
        .provenance_complete = provenance.provenance_complete,
        .protocol = one_shot.canonical_protocol,
        .protocol_complete = true,
        .daemon_executable_sha256 = &executable_identity.daemon_executable_sha256,
        .runner_executable_sha256 = &executable_identity.runner_executable_sha256,
        .runner_linkage = in_process_runner_linkage,
        .prove_timing_scope = protocol.prove_timing_scope,
        .prove_wall_s = prove_wall_s,
        .prove_mhz = prove_mhz,
        .input = .{
            .path = diagnostic_adapted_input,
            .sha256 = &adapted_input_sha256,
            .adapted_cycles = counts.cycles,
            .pc_count = counts.pc_count,
        },
        .proof = .{
            .bytes = proof_stat.size,
            .sha256 = &proof_sha256,
        },
        .rust_verifier = rust_verifier_evidence,
        .pipeline_cache_delta = pipeline_cache_delta,
        .service_phase_timing = .{
            .artifact_admission_wall_s = artifact_admission_wall_s,
            .adapted_geometry_fingerprint_wall_s = adapted_geometry_fingerprint_wall_s,
            .prepared_host_geometry_acquire_wall_s = prepared_host_geometry_acquire_wall_s,
            .pre_runner_wall_s = nanosecondsToSeconds(runner_started_ns) - artifact_admission_wall_s,
            .runner_call_wall_s = nanosecondsToSeconds(runner_finished_ns - runner_started_ns),
            .post_runner_before_report_wall_s = nanosecondsToSeconds(finalization_started_ns - runner_finished_ns),
        },
        .reuse = .{
            .runtime = true,
            .resident_arena = prepared_state_telemetry.cache_hit,
            .preprocessed_state = prepared_state_telemetry.cache_hit,
        },
        .cli_report = cli_report.value,
    }, .{ .whitespace = .indent_2 }, &final_report_writer.interface);
    try final_report_writer.interface.writeByte('\n');
    try final_report_writer.interface.flush();
    try final_report_file.sync();

    try prepared_host_geometry.validateCommit();
    try requireAbsent(request.proof_output);
    try requireAbsent(request.report_output);
    try publishOutputsExclusive(
        proof_temporary,
        request.proof_output,
        report_temporary,
        request.report_output,
    );
    prepared_host_geometry.commitAssumeValid();
    prepared_geometry_borrowed = false;
    const session_block_wall_s = @as(f64, @floatFromInt(block_timer.read())) /
        @as(f64, @floatFromInt(std.time.ns_per_s));
    prepared_state_borrowed = false;
    return .{
        .adapted_cycles = counts.cycles,
        .adapted_input_sha256 = adapted_input_sha256,
        .prove_wall_s = prove_wall_s,
        .prove_mhz = prove_mhz,
        .session_block_wall_s = session_block_wall_s,
        .proof_bytes = proof_stat.size,
        .proof_sha256 = proof_sha256,
        .pipeline_cache_delta = pipeline_cache_delta,
        .provenance = provenance,
        .executable_identity = executable_identity,
        .artifact_objects = artifact_objects,
        .prepared_state_cache_hit = prepared_state_telemetry.cache_hit,
        .rust_verifier = rust_verifier_evidence,
    };
}

fn prepareArtifacts(
    allocator: std.mem.Allocator,
    store: *artifact_store.Store,
    views: *ViewCache,
    request: protocol.Request,
    executable_measurement: artifact_manifest.Measurement,
) !PreparedArtifacts {
    var prepared = PreparedArtifacts{};
    errdefer prepared.deinit(allocator);
    prepared.entries[0] = .{
        .role = .backend_executable,
        .format_version = 1,
        .provenance = .unattested,
        .measurement = executable_measurement,
        .source_chain_complete = false,
    };
    prepared.entry_count = 1;

    try prepared.addSnapshot(store, .adapted_input, .adapted_input, request.artifacts.adapted_input, .proof_derived, .prefer_apfs_clone);
    try prepared.addSnapshot(store, .schedule, .schedule, request.artifacts.schedule, .proof_derived, .byte_copy);
    try prepared.addSnapshot(store, .witness_programs, .witness_programs, request.artifacts.witness_programs, .proof_derived, .byte_copy);
    try prepared.addSnapshot(store, .multiplicity_feeds, .multiplicity_feeds, request.artifacts.multiplicity_feeds, .proof_derived, .byte_copy);
    try prepared.addSnapshot(store, .relation_templates, .relation_templates, request.artifacts.relation_templates, .proof_derived, .byte_copy);
    try prepared.addSnapshot(store, .fixed_tables, .fixed_tables, request.artifacts.fixed_tables, .proof_derived, .byte_copy);
    try prepared.addSnapshot(store, .composition, .composition, request.artifacts.composition, .proof_derived, .byte_copy);
    try prepared.addSnapshot(store, .composition_program, .composition_program, request.artifacts.composition_program, .proof_derived, .byte_copy);
    try prepared.addSnapshot(store, .preprocessed_evaluations, .preprocessed_evaluations, request.artifacts.preprocessed_evaluations, .proof_derived, .prefer_apfs_clone);
    try prepared.addSnapshot(store, .preprocessed_tree0_merkle, .preprocessed_tree0_merkle, request.artifacts.preprocessed_tree0_merkle, .proof_derived, .prefer_apfs_clone);
    try prepared.addSnapshot(store, .preprocessed_coefficients, .preprocessed_coefficients, request.artifacts.preprocessed_coefficients, .proof_derived, .prefer_apfs_clone);
    if (request.artifacts.transcript_reference) |reference|
        try prepared.addSnapshot(store, .transcript_reference, .transcript_reference, reference, .diagnostic_fixture, .byte_copy);
    if (request.artifacts.quotient_reference) |reference|
        try prepared.addSnapshot(store, .quotient_reference, .quotient_reference, reference, .diagnostic_fixture, .byte_copy);

    var expected_tree0_root: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected_tree0_root, request.expected_tree0_root_hex) catch
        return error.InvalidTreeRoot;
    const composition_program: artifact_views.CompositionProgram = switch (try compositionProgramKind(
        request.artifacts.composition_program.diagnosticPath(),
    )) {
        .metal => .{ .metal = immutableObject(prepared.snapshot(.composition_program)) },
        .metallib => .{ .metallib = immutableObject(prepared.snapshot(.composition_program)) },
    };
    const view_name = try std.fmt.allocPrint(
        allocator,
        "{}-{s}",
        .{ request.sequence, request.request_id },
    );
    defer allocator.free(view_name);
    prepared.view = try views.getOrCreate(store.root_path, view_name, .{
        .preprocessed_evaluations = immutableObject(prepared.snapshot(.preprocessed_evaluations)),
        .preprocessed_tree0_merkle = immutableObject(prepared.snapshot(.preprocessed_tree0_merkle)),
        .composition = immutableObject(prepared.snapshot(.composition)),
        .composition_program = composition_program,
        .expected_tree0_root = expected_tree0_root,
    });
    prepared.tree0_root_hex = std.fmt.bytesToHex(prepared.view.?.tree0_root, .lower);
    return prepared;
}

fn immutableObject(snapshot: *const artifact_store.Snapshot) artifact_views.ImmutableObject {
    return .{
        .path = snapshot.path,
        .object_id = snapshot.object_id,
        .bytes = snapshot.measurement.bytes,
    };
}

fn compositionProgramKind(path: []const u8) !std.meta.Tag(artifact_views.CompositionProgram) {
    if (std.mem.endsWith(u8, path, ".metal")) return .metal;
    if (std.mem.endsWith(u8, path, ".metallib")) return .metallib;
    return error.InvalidCompositionProgram;
}

fn parseObjectId(encoded: []const u8) ![32]u8 {
    var object_id: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&object_id, encoded) catch return error.InvalidObjectId;
    return object_id;
}

fn canonicalProofProtocolDigest() ![32]u8 {
    return artifact_manifest.protocolDigest(.{
        .channel = one_shot.canonical_protocol.channel,
        .channel_salt = one_shot.canonical_protocol.channel_salt,
        .log_blowup_factor = one_shot.canonical_protocol.log_blowup_factor,
        .n_queries = one_shot.canonical_protocol.n_queries,
        .interaction_pow_bits = one_shot.canonical_protocol.interaction_pow_bits,
        .query_pow_bits = one_shot.canonical_protocol.query_pow_bits,
        .fri_fold_step = one_shot.canonical_protocol.fri_fold_step,
        .fri_lifting = one_shot.canonical_protocol.fri_lifting,
        .fri_log_last_layer_degree_bound = one_shot.canonical_protocol.fri_log_last_layer_degree_bound,
    });
}

fn preparedStateKey(
    objects: ArtifactObjectsEvidence,
    tree0_root_hex: [64]u8,
    budget_gib: []const u8,
    program_kind: std.meta.Tag(artifact_views.CompositionProgram),
    executable_digest: [32]u8,
    protocol_digest: [32]u8,
) !one_shot.PreparedStateKey {
    const budget_value = try std.fmt.parseFloat(f64, budget_gib);
    if (!std.math.isFinite(budget_value) or budget_value <= 0) return error.InvalidBudget;
    const budget_bytes_float = budget_value * 1024.0 * 1024.0 * 1024.0;
    if (budget_value >= 17_179_869_184.0) return error.InvalidBudget;
    const budget_bytes: u64 = @intFromFloat(budget_bytes_float);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("stwo-zig-metal-prepared-state-v1\x00");
    inline for (.{
        objects.schedule,
        objects.witness_programs,
        objects.multiplicity_feeds,
        objects.relation_templates,
        objects.fixed_tables,
        objects.composition,
        objects.composition_program,
        objects.preprocessed_evaluations,
        objects.preprocessed_tree0_merkle,
        objects.preprocessed_coefficients,
    }) |object| {
        hash.update(&object.object_id);
        var encoded_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded_bytes, object.bytes, .little);
        hash.update(&encoded_bytes);
    }
    hash.update(&tree0_root_hex);
    var encoded_budget: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded_budget, budget_bytes, .little);
    hash.update(&encoded_budget);
    const encoded_program_kind: [1]u8 = .{@intFromEnum(program_kind)};
    hash.update(&encoded_program_kind);
    hash.update(&executable_digest);
    hash.update(&protocol_digest);
    return hash.finalResult();
}

fn preparedGeometryKey(
    resident_key: one_shot.PreparedStateKey,
    adapted_geometry_fingerprint: [32]u8,
    policy: PreparedGeometryPolicy,
) PreparedGeometryKey {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("stwo-zig-metal-prepared-geometry-v2\x00");
    hash.update(&resident_key);
    hash.update(&adapted_geometry_fingerprint);
    const encoded_policy: [1]u8 = .{@intFromBool(policy.replay_retained_lookups)};
    hash.update(&encoded_policy);
    return hash.finalResult();
}

fn writeVerifiedResultFrame(
    writer: *std.Io.Writer,
    request: protocol.Request,
    result: ProofResult,
) !void {
    const artifact_manifest_digest: ?[]const u8 = if (result.provenance.artifact_manifest_digest) |*digest|
        digest
    else
        null;
    try writeFrame(writer, .{
        .protocol = protocol.protocol_name,
        .version = protocol.protocol_version,
        .type = "result",
        .status = "verified",
        .sequence = request.sequence,
        .request_id = request.request_id,
        .proof_verified = true,
        .outputs_committed = true,
        .self_contained = result.provenance.self_contained,
        .parity_fixture_used = result.provenance.parity_fixture_used,
        .proof_derived_artifact_used = result.provenance.proof_derived_artifact_used,
        .statement_self_derived = result.provenance.statement_self_derived,
        .artifact_manifest_digest = artifact_manifest_digest,
        .artifact_objects = result.artifact_objects,
        .provenance_complete = result.provenance.provenance_complete,
        .proof_protocol = one_shot.canonical_protocol,
        .protocol_complete = true,
        .daemon_executable_sha256 = &result.executable_identity.daemon_executable_sha256,
        .runner_executable_sha256 = &result.executable_identity.runner_executable_sha256,
        .runner_linkage = in_process_runner_linkage,
        .adapted_cycles = result.adapted_cycles,
        .adapted_input_sha256 = &result.adapted_input_sha256,
        .prove_wall_s = result.prove_wall_s,
        .prove_timing_scope = protocol.prove_timing_scope,
        .prove_mhz = result.prove_mhz,
        .session_block_wall_s = result.session_block_wall_s,
        .proof_bytes = result.proof_bytes,
        .proof_sha256 = &result.proof_sha256,
        .rust_verifier = result.rust_verifier,
        .pipeline_cache_delta = result.pipeline_cache_delta,
        .reuse = .{
            .runtime = true,
            .resident_arena = result.prepared_state_cache_hit,
            .preprocessed_state = result.prepared_state_cache_hit,
        },
    });
}

fn cacheDelta(
    after: metal_runtime.PipelineCacheStats,
    before: metal_runtime.PipelineCacheStats,
) metal_runtime.PipelineCacheStats {
    return .{
        .library_cache_hits = after.library_cache_hits - before.library_cache_hits,
        .library_cache_misses = after.library_cache_misses - before.library_cache_misses,
        .pipeline_cache_hits = after.pipeline_cache_hits - before.pipeline_cache_hits,
        .binary_archive_hits = after.binary_archive_hits - before.binary_archive_hits,
        .binary_archive_misses = after.binary_archive_misses - before.binary_archive_misses,
        .direct_compiles = after.direct_compiles - before.direct_compiles,
        .archive_populations = after.archive_populations - before.archive_populations,
        .archive_serializations = after.archive_serializations - before.archive_serializations,
        .pipeline_preparation_seconds = after.pipeline_preparation_seconds - before.pipeline_preparation_seconds,
    };
}

fn nanosecondsToSeconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) /
        @as(f64, @floatFromInt(std.time.ns_per_s));
}

fn isSessionScrubbedRunnerEnvironment(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "STWO_ZIG_SN2_");
}

fn configureEnvironment(
    allocator: std.mem.Allocator,
    request: RunnerRequest,
    canonical_adapted_input: []const u8,
    proof_temporary: []const u8,
    statement_temporary: []const u8,
) !void {
    var environment = try std.process.getEnvMap(allocator);
    defer environment.deinit();
    const log_stage_timings = environment.get("STWO_ZIG_SN2_LOG_STAGE_TIMINGS") != null;
    const log_composition_digests = environment.get("STWO_ZIG_SN2_LOG_COMPOSITION_DIGESTS") != null;
    const log_composition_part_component = environment.get("STWO_ZIG_SN2_LOG_COMPOSITION_PART_COMPONENT");
    const composition_fusion_cap = environment.get("STWO_ZIG_SN2_COMPOSITION_FUSION_CAP");
    var iterator = environment.iterator();
    while (iterator.next()) |entry| {
        if (!isSessionScrubbedRunnerEnvironment(entry.key_ptr.*)) continue;
        const name = try allocator.dupeZ(u8, entry.key_ptr.*);
        defer allocator.free(name);
        if (unsetenv(name.ptr) != 0) return error.EnvironmentMutationFailed;
    }
    if (!std.mem.endsWith(u8, request.artifacts.composition, ".bin"))
        return error.InvalidCompositionArtifact;
    const program_kind = try compositionProgramKind(request.artifacts.composition_program);

    const values = [_]struct { []const u8, []const u8 }{
        .{ "STWO_ZIG_SN2_POPULATE_INPUT", canonical_adapted_input },
        .{ "STWO_ZIG_SN2_PREPARE_METAL", "1" },
        .{ "STWO_ZIG_SN2_RESTORE_PREPROCESSED_EVALUATIONS", request.artifacts.preprocessed_evaluations },
        .{ "STWO_ZIG_SN2_TREE0_ROOT_HEX", request.tree0_root_hex },
        .{ "STWO_ZIG_SN2_EXECUTE_PREPROCESSED", "1" },
        .{ "STWO_ZIG_SN2_EXECUTE_WITNESS", "1" },
        .{ "STWO_ZIG_SN2_EXECUTE_BASE_INTERPOLATION", "1" },
        .{ "STWO_ZIG_SN2_EXECUTE_COMMITMENTS", "1" },
        .{ "STWO_ZIG_SN2_COMMIT_TREE_COUNT", "4" },
        .{ "STWO_ZIG_SN2_EXECUTE_RELATIONS", "1" },
        .{ "STWO_ZIG_SN2_PREPROCESSED_COEFFS", request.artifacts.preprocessed_coefficients },
        .{ "STWO_ZIG_SN2_EXECUTE_COMPOSITION", "1" },
        .{ "STWO_ZIG_SN2_PROOF_OUTPUT", proof_temporary },
        .{ "STWO_ZIG_SN2_COMPACT_STATEMENT_OUTPUT", statement_temporary },
        .{ "STWO_ZIG_SN2_EXECUTE_OODS", "1" },
        .{ "STWO_ZIG_SN2_EXECUTE_PROOF", "1" },
        .{ "STWO_ZIG_SN2_VERIFY_PROOF", "1" },
        .{ "STWO_ZIG_METAL_REPLAY_RETAINED_LOOKUPS", "1" },
    };
    for (values) |entry| {
        try setEnvironmentValue(allocator, .{ .name = entry[0], .value = entry[1] });
    }
    if (log_stage_timings) {
        try setEnvironmentValue(allocator, .{
            .name = "STWO_ZIG_SN2_LOG_STAGE_TIMINGS",
            .value = "1",
        });
    }
    if (log_composition_digests) {
        try setEnvironmentValue(allocator, .{
            .name = "STWO_ZIG_SN2_LOG_COMPOSITION_DIGESTS",
            .value = "1",
        });
    }
    if (log_composition_part_component) |component| {
        try setEnvironmentValue(allocator, .{
            .name = "STWO_ZIG_SN2_LOG_COMPOSITION_PART_COMPONENT",
            .value = component,
        });
    }
    if (program_kind == .metal) {
        try setEnvironmentValue(allocator, .{
            .name = "STWO_ZIG_SN2_COMPOSITION_SOURCE",
            .value = request.artifacts.composition_program,
        });
        try setEnvironmentValue(allocator, .{
            .name = "STWO_ZIG_SN2_ENABLE_COMPOSITION_PART_FUSION",
            .value = "1",
        });
        if (composition_fusion_cap) |cap| {
            try setEnvironmentValue(allocator, .{
                .name = "STWO_ZIG_SN2_COMPOSITION_FUSION_CAP",
                .value = cap,
            });
        }
    }
    for (referenceEnvironment(request.artifacts)) |optional_entry|
        if (optional_entry) |entry| try setEnvironmentValue(allocator, entry);
}

fn referenceEnvironment(artifacts: RunnerArtifacts) [3]?EnvironmentValue {
    return .{
        if (artifacts.transcript_reference) |value| .{
            .name = "STWO_ZIG_SN2_TRANSCRIPT_REFERENCE",
            .value = value,
        } else null,
        if (artifacts.quotient_reference) |value| .{
            .name = "STWO_ZIG_SN2_QUOTIENT_REFERENCE",
            .value = value,
        } else null,
        if (artifacts.transcript_reference != null) .{
            .name = "STWO_ZIG_SN2_REPLAY_TRANSCRIPT_AFTER_TREE2",
            .value = "1",
        } else null,
    };
}

fn setEnvironmentValue(allocator: std.mem.Allocator, entry: EnvironmentValue) !void {
    const name = try allocator.dupeZ(u8, entry.name);
    defer allocator.free(name);
    const value = try allocator.dupeZ(u8, entry.value);
    defer allocator.free(value);
    if (setenv(name.ptr, value.ptr, 1) != 0) return error.EnvironmentMutationFailed;
}

const AdaptedCounts = struct { cycles: u64, pc_count: u64 };

const AdaptedGeometry = struct {
    fingerprint: [32]u8,
    counts: AdaptedCounts,
};

fn checkedSectionEnd(offset: u64, count: u64, stride: u64, file_size: u64) !u64 {
    const bytes = std.math.mul(u64, count, stride) catch return error.InvalidAdaptedInput;
    const end = std.math.add(u64, offset, bytes) catch return error.InvalidAdaptedInput;
    if (end > file_size) return error.InvalidAdaptedInput;
    return end;
}

fn readU64At(file: std.fs.File, offset: u64) !u64 {
    var encoded: [8]u8 = undefined;
    if (try file.preadAll(&encoded, offset) != encoded.len) return error.InvalidAdaptedInput;
    return std.mem.readInt(u64, &encoded, .little);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

/// Validate the canonical adapted-input layout while reading only section
/// headers. The digest includes exactly the adapted values consumed by
/// CairoProofPlan.fromWitnessSchedule's direct row-extent derivation.
///
/// Compatibility invariant: this fingerprint may key only immutable host
/// geometry, CairoProofPlan, and StagedArenaPlanner outputs when the schedule
/// and bundles are independently identity-bound. It must not key ProverInput,
/// statement bootstrap data, public-memory seeds, or native witness recipes;
/// those consume the per-proof memory payload and the other builtin segments.
fn adaptedGeometry(path: []const u8, expected_bytes: u64) !AdaptedGeometry {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.kind != .file or stat.size != expected_bytes) return error.InvalidAdaptedInput;
    var header: [64]u8 = undefined;
    if (try file.preadAll(&header, 0) != header.len or !std.mem.eql(u8, header[0..8], "STWZCPI\x00"))
        return error.InvalidAdaptedInput;
    if (std.mem.readInt(u32, header[8..12], .little) != cairo_adapted_input.VERSION)
        return error.InvalidAdaptedInput;
    const pc_count = std.mem.readInt(u64, header[40..48], .little);
    const opcode_count = std.mem.readInt(u32, header[56..60], .little);
    if (opcode_count != cairo_opcodes.N_OPCODES) return error.InvalidAdaptedInput;
    var geometry_hash = std.crypto.hash.sha2.Sha256.init(.{});
    geometry_hash.update("stwo-zig-cairo-adapted-row-geometry-v1\x00");
    var offset: u64 = 64;
    var cycles: u64 = 0;
    for (0..opcode_count) |_| {
        const count = try readU64At(file, offset);
        if (count > cairo_adapted_input.MAX_ITEMS) return error.InvalidAdaptedInput;
        cycles = std.math.add(u64, cycles, count) catch return error.InvalidAdaptedInput;
        hashU64(&geometry_hash, count);
        offset = try checkedSectionEnd(offset, 1, 8, stat.size);
        offset = try checkedSectionEnd(offset, count, 12, stat.size);
    }

    var memory_header: [48]u8 = undefined;
    if (try file.preadAll(&memory_header, offset) != memory_header.len)
        return error.InvalidAdaptedInput;
    const address_count = std.mem.readInt(u64, memory_header[24..32], .little);
    const f252_count = std.mem.readInt(u64, memory_header[32..40], .little);
    const small_count = std.mem.readInt(u64, memory_header[40..48], .little);
    inline for (.{ address_count, f252_count, small_count }) |count| {
        if (count > cairo_adapted_input.MAX_ITEMS) return error.InvalidAdaptedInput;
    }
    offset = try checkedSectionEnd(offset, 1, memory_header.len, stat.size);
    offset = try checkedSectionEnd(offset, address_count, 4, stat.size);
    offset = try checkedSectionEnd(offset, f252_count, 8 * @sizeOf(u32), stat.size);
    offset = try checkedSectionEnd(offset, small_count, @sizeOf(u128), stat.size);

    const public_count = try readU64At(file, offset);
    if (public_count > cairo_adapted_input.MAX_ITEMS) return error.InvalidAdaptedInput;
    offset = try checkedSectionEnd(offset, 1, 8, stat.size);
    offset = try checkedSectionEnd(offset, public_count, @sizeOf(u32), stat.size);

    const GeometryBuiltin = struct { segment_index: usize, cells: u64 };
    const geometry_builtins = [_]GeometryBuiltin{
        .{ .segment_index = 1, .cells = 5 },
        .{ .segment_index = 4, .cells = 3 },
        .{ .segment_index = 5, .cells = 6 },
        .{ .segment_index = 7, .cells = 1 },
    };
    var geometry_builtin_index: usize = 0;
    for (0..9) |segment_index| {
        var segment: [24]u8 = undefined;
        if (try file.preadAll(&segment, offset) != segment.len) return error.InvalidAdaptedInput;
        const present = segment[0];
        if (present > 1) return error.InvalidAdaptedInput;
        if (geometry_builtin_index < geometry_builtins.len and
            geometry_builtins[geometry_builtin_index].segment_index == segment_index)
        {
            geometry_hash.update(segment[0..1]);
            var instances: u64 = 0;
            if (present == 1) {
                const begin = std.mem.readInt(u64, segment[8..16], .little);
                const stop = std.mem.readInt(u64, segment[16..24], .little);
                if (begin > std.math.maxInt(usize) or stop > std.math.maxInt(usize) or stop < begin)
                    return error.InvalidAdaptedInput;
                instances = (stop - begin) / geometry_builtins[geometry_builtin_index].cells;
            }
            hashU64(&geometry_hash, instances);
            geometry_builtin_index += 1;
        }
        offset = try checkedSectionEnd(offset, 1, segment.len, stat.size);
    }
    if (geometry_builtin_index != geometry_builtins.len or offset != stat.size)
        return error.InvalidAdaptedInput;
    return .{
        .fingerprint = geometry_hash.finalResult(),
        .counts = .{ .cycles = cycles, .pc_count = pc_count },
    };
}

fn hashFile(allocator: std.mem.Allocator, path: []const u8) ![32]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const buffer = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(buffer);
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const count = try file.read(buffer);
        if (count == 0) break;
        digest.update(buffer[0..count]);
    }
    return digest.finalResult();
}

fn copyFileExclusive(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    destination_path: []const u8,
    mode: std.posix.mode_t,
) !artifact_manifest.Measurement {
    const source = try std.fs.openFileAbsolute(source_path, .{});
    defer source.close();
    const source_before = try source.stat();
    if (source_before.kind != .file) return error.InvalidCopySource;
    const destination = try std.fs.createFileAbsolute(destination_path, .{
        .read = true,
        .exclusive = true,
        .mode = 0o600,
    });
    var destination_open = true;
    defer if (destination_open) destination.close();
    errdefer std.fs.deleteFileAbsolute(destination_path) catch {};
    const buffer = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(buffer);
    var source_digest = std.crypto.hash.sha2.Sha256.init(.{});
    var copied: u64 = 0;
    while (true) {
        const count = try source.read(buffer);
        if (count == 0) break;
        try destination.writeAll(buffer[0..count]);
        source_digest.update(buffer[0..count]);
        copied = std.math.add(u64, copied, count) catch return error.InvalidCopySource;
    }
    if (copied != source_before.size or
        !artifact_manifest.FileIdentity.fromStat(source_before).eql(
            artifact_manifest.FileIdentity.fromStat(try source.stat()),
        ))
        return error.CopySourceChanged;
    try destination.chmod(mode);
    try destination.sync();
    destination.close();
    destination_open = false;
    const measurement = try artifact_manifest.measureFile(allocator, destination_path);
    if (measurement.bytes != copied or
        !std.mem.eql(u8, &measurement.sha256, &source_digest.finalResult()))
        return error.CopyDigestMismatch;
    return measurement;
}

fn cliProofLayout(object: std.json.ObjectMap) !compact_interchange.CompactProofLayoutV1 {
    const value = object.get("proof_layout") orelse return error.InvalidProofLayout;
    if (value != .object or value.object.count() != 3) return error.InvalidProofLayout;
    const layout = value.object;
    inline for (.{
        "interaction_claim_words",
        "sampled_value_words",
        "decommitment_capacity_words",
    }) |name| {
        if (!layout.contains(name)) return error.InvalidProofLayout;
    }
    return .{
        .interaction_claim_words = std.math.cast(
            u32,
            try positiveIntegerField(layout, "interaction_claim_words"),
        ) orelse return error.InvalidProofLayout,
        .sampled_value_words = std.math.cast(
            u32,
            try positiveIntegerField(layout, "sampled_value_words"),
        ) orelse return error.InvalidProofLayout,
        .decommitment_capacity_words = std.math.cast(
            u32,
            try positiveIntegerField(layout, "decommitment_capacity_words"),
        ) orelse return error.InvalidProofLayout,
    };
}

const CompactRuntimeProtocol = struct {
    geometry: compact_interchange.RuntimeProtocolGeometryV1,
    trace_columns: [4]u32,
};

fn compactRuntimeProtocolFromArtifacts(
    allocator: std.mem.Allocator,
    composition_path: []const u8,
    fixed_tables_path: []const u8,
) !CompactRuntimeProtocol {
    var composition = try composition_bundle.Bundle.readFile(allocator, composition_path);
    defer composition.deinit();
    var fixed_tables = try fixed_table_bundle.Bundle.readFile(allocator, fixed_tables_path);
    defer fixed_tables.deinit();
    const max_log_degree_bound = composition.verifierMaxLogDegreeBound() catch
        return error.InvalidCompactProtocolGeometry;
    return compactRuntimeProtocolFromComponents(
        composition.components,
        fixed_tables.preprocessed_identities.len,
        max_log_degree_bound,
    );
}

fn compactRuntimeProtocolFromComponents(
    components: anytype,
    preprocessed_count: usize,
    max_log_degree_bound: u32,
) !CompactRuntimeProtocol {
    const preprocessed_columns = std.math.cast(u32, preprocessed_count) orelse
        return error.InvalidCompactProtocolGeometry;
    var trace_columns = [4]u32{ preprocessed_columns, 0, 0, 8 };
    for (components) |component| {
        if (component.trace_spans.len != 3) return error.InvalidCompactProtocolGeometry;
        for (component.trace_spans, 0..) |span, tree_index| {
            if (span.tree != @as(u32, @intCast(tree_index)))
                return error.InvalidCompactProtocolGeometry;
            switch (tree_index) {
                0 => if (span.start != 0 or span.end != 0)
                    return error.InvalidCompactProtocolGeometry,
                1, 2 => {
                    if (span.start != trace_columns[tree_index] or span.end < span.start)
                        return error.InvalidCompactProtocolGeometry;
                    trace_columns[tree_index] = span.end;
                },
                else => unreachable,
            }
        }
    }
    if (max_log_degree_bound == 0 or trace_columns[0] == 0 or
        trace_columns[1] == 0 or trace_columns[2] == 0)
        return error.InvalidCompactProtocolGeometry;

    var geometry = compact_interchange.RuntimeProtocolGeometryV1.sn2();
    geometry.max_log_degree_bound = max_log_degree_bound;
    const folds = geometry.max_log_degree_bound - geometry.log_last_layer_degree_bound;
    if (geometry.fri_fold_step == 0 or folds < geometry.fri_fold_step)
        return error.InvalidCompactProtocolGeometry;
    geometry.fri_tree_count = 1 + (folds - 1) / geometry.fri_fold_step;
    geometry.decommitment_record_count = std.math.add(
        u32,
        geometry.commitment_count,
        geometry.fri_tree_count,
    ) catch return error.InvalidCompactProtocolGeometry;
    geometry.validate() catch return error.InvalidCompactProtocolGeometry;
    _ = compact_interchange.PreprocessedTraceVariantV1.fromTraceTree0ColumnCount(
        trace_columns[0],
    ) catch return error.InvalidCompactProtocolGeometry;
    return .{ .geometry = geometry, .trace_columns = trace_columns };
}

test "session compact protocol derives checked-in SN2 artifact geometry" {
    const runtime = try compactRuntimeProtocolFromArtifacts(
        std.testing.allocator,
        "vectors/cairo/sn_pie_2_composition.bin",
        "vectors/cairo/cairo_fixed_tables.bin",
    );
    try std.testing.expectEqual(@as(u32, 24), runtime.geometry.max_log_degree_bound);
    try std.testing.expectEqual(@as(u32, 8), runtime.geometry.fri_tree_count);
    try std.testing.expectEqual(@as(u32, 12), runtime.geometry.decommitment_record_count);
    try std.testing.expectEqual([4]u32{ 161, 3449, 2268, 8 }, runtime.trace_columns);
}

test "session compact protocol derives projected Fib geometry from authenticated bound" {
    const Component = struct { trace_spans: []const composition_bundle.TraceSpan };
    const first_spans = [_]composition_bundle.TraceSpan{
        .{ .tree = 0, .start = 0, .end = 0 },
        .{ .tree = 1, .start = 0, .end = 200 },
        .{ .tree = 2, .start = 0, .end = 100 },
    };
    const second_spans = [_]composition_bundle.TraceSpan{
        .{ .tree = 0, .start = 0, .end = 0 },
        .{ .tree = 1, .start = 200, .end = 396 },
        .{ .tree = 2, .start = 100, .end = 324 },
    };
    const components = [_]Component{
        .{ .trace_spans = &first_spans },
        .{ .trace_spans = &second_spans },
    };
    const runtime = try compactRuntimeProtocolFromComponents(&components, 105, 20);
    try std.testing.expectEqual(@as(u32, 20), runtime.geometry.max_log_degree_bound);
    try std.testing.expectEqual(@as(u32, 7), runtime.geometry.fri_tree_count);
    try std.testing.expectEqual(@as(u32, 11), runtime.geometry.decommitment_record_count);
    try std.testing.expectEqual([4]u32{ 105, 396, 324, 8 }, runtime.trace_columns);

    const compact_protocol = try (compact_interchange.CompactProofLayoutV1{
        .interaction_claim_words = 4,
        .sampled_value_words = 4,
        .decommitment_capacity_words = 324,
    }).protocolRuntime(0, runtime.geometry, runtime.trace_columns);
    const encoded = try compact_protocol.encode();
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, encoded[24..28], .little));
    try std.testing.expectEqual(@as(u32, 20), std.mem.readInt(u32, encoded[108..112], .little));
}

test "session compact protocol rejects unauthenticated trace geometry" {
    const Component = struct { trace_spans: []const composition_bundle.TraceSpan };
    const spans = [_]composition_bundle.TraceSpan{
        .{ .tree = 0, .start = 0, .end = 0 },
        .{ .tree = 1, .start = 1, .end = 2 },
        .{ .tree = 2, .start = 0, .end = 1 },
    };
    const components = [_]Component{.{ .trace_spans = &spans }};
    try std.testing.expectError(
        error.InvalidCompactProtocolGeometry,
        compactRuntimeProtocolFromComponents(&components, 105, 20),
    );
    try std.testing.expectError(
        error.InvalidCompactProtocolGeometry,
        compactRuntimeProtocolFromComponents(&components, 160, 20),
    );
}

const VerifierWatchdog = struct {
    pid: std.posix.pid_t,
    complete: std.Thread.ResetEvent = .{},
    timeout_ns: u64,
    grace_ns: u64,
    timed_out: bool = false,
    signal_failed: bool = false,

    fn signalGroup(self: *VerifierWatchdog, signal: u8) void {
        std.posix.kill(-self.pid, signal) catch |group_error| switch (group_error) {
            error.ProcessNotFound => return,
            else => std.posix.kill(self.pid, signal) catch |leader_error| switch (leader_error) {
                error.ProcessNotFound => return,
                else => self.signal_failed = true,
            },
        };
    }

    fn run(self: *VerifierWatchdog) void {
        self.complete.timedWait(self.timeout_ns) catch |wait_error| switch (wait_error) {
            error.Timeout => {
                self.timed_out = true;
                self.signalGroup(std.posix.SIG.TERM);
                self.complete.timedWait(self.grace_ns) catch |grace_error| switch (grace_error) {
                    error.Timeout => {},
                };
                self.signalGroup(std.posix.SIG.KILL);
            },
        };
    }
};

fn runDirectWithTimeout(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    timeout_ns: u64,
    grace_ns: u64,
) !std.process.Child.Term {
    if (argv.len == 0 or !std.fs.path.isAbsolute(argv[0])) return error.InvalidChildExecutable;
    var empty_environment = std.process.EnvMap.init(allocator);
    defer empty_environment.deinit();
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.env_map = &empty_environment;
    child.cwd = cwd;
    child.expand_arg0 = .no_expand;
    child.pgid = 0;
    try child.spawn();
    child.waitForSpawn() catch |err| {
        _ = child.wait() catch {};
        return err;
    };

    var watchdog = VerifierWatchdog{
        .pid = child.id,
        .timeout_ns = timeout_ns,
        .grace_ns = grace_ns,
    };
    const watchdog_thread = std.Thread.spawn(.{}, VerifierWatchdog.run, .{&watchdog}) catch |err| {
        watchdog.signalGroup(std.posix.SIG.KILL);
        _ = child.wait() catch {};
        return err;
    };
    const wait_result = child.wait();
    watchdog.complete.set();
    watchdog_thread.join();
    const term = try wait_result;
    if (watchdog.signal_failed) return error.ProcessGroupTerminationFailed;
    if (watchdog.timed_out) return error.RustVerifierTimedOut;
    return term;
}

fn runRustVerifier(
    allocator: std.mem.Allocator,
    config: RustVerifierConfig,
    envelope_path: []const u8,
    result_path: []const u8,
    expected: compact_interchange.EnvelopeSummary,
) !RustVerifierEvidence {
    try config.assertUnchanged();
    try requireAbsent(result_path);
    var service_timer = try std.time.Timer.start();
    const term = try runDirectWithTimeout(
        allocator,
        &.{
            config.executable_path,
            "verify",
            "--envelope",
            envelope_path,
            "--result",
            result_path,
        },
        std.fs.path.dirname(envelope_path),
        30 * std.time.ns_per_s,
        2 * std.time.ns_per_s,
    );
    const service_wall_time_ns = service_timer.read();
    try config.assertUnchanged();
    switch (term) {
        .Exited => |code| if (code != 0) return error.RustVerifierRejected,
        else => return error.RustVerifierAbnormalTermination,
    }

    const result_file = try std.fs.openFileAbsolute(result_path, .{});
    defer result_file.close();
    const before = try result_file.stat();
    if (before.kind != .file or before.size == 0 or before.size > 1024 * 1024)
        return error.InvalidRustVerifierResult;
    const encoded = try result_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(encoded);
    const after = try result_file.stat();
    if (!artifact_manifest.FileIdentity.fromStat(before).eql(
        artifact_manifest.FileIdentity.fromStat(after),
    )) return error.RustVerifierResultChanged;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRustVerifierResult;
    const object = parsed.value.object;
    const required_keys = [_][]const u8{
        "schema_version",
        "envelope_abi",
        "adapter_version",
        "cargo_lock_sha256",
        "executable_sha256",
        "stwo_cairo_revision",
        "stwo_revision",
        "protocol_digest",
        "statement_digest",
        "proof_digest",
        "provenance_digest",
        "verification_mode",
        "verified",
        "wall_time_ns",
        "error",
    };
    if (object.count() != required_keys.len) return error.InvalidRustVerifierResult;
    for (required_keys) |name| if (!object.contains(name)) return error.InvalidRustVerifierResult;
    if (!jsonIntegerIs(object.get("schema_version"), 1) or
        !jsonStringIs(object.get("envelope_abi"), rust_verifier_envelope_abi) or
        !jsonStringIs(object.get("adapter_version"), rust_verifier_adapter_version) or
        !jsonStringIs(object.get("cargo_lock_sha256"), rust_verifier_cargo_lock_sha256) or
        !jsonStringIs(object.get("executable_sha256"), &config.executable_sha256) or
        !jsonStringIs(object.get("stwo_cairo_revision"), rust_verifier_stwo_cairo_revision) or
        !jsonStringIs(object.get("stwo_revision"), rust_verifier_stwo_revision) or
        !jsonStringIs(object.get("verification_mode"), rust_verifier_mode) or
        !(optionalBoolField(object, "verified") orelse false) or
        object.get("error").? != .null)
        return error.InvalidRustVerifierResult;

    const protocol_digest = std.fmt.bytesToHex(expected.protocol_sha256, .lower);
    const statement_digest = std.fmt.bytesToHex(expected.statement_sha256, .lower);
    const proof_digest = std.fmt.bytesToHex(expected.proof_sha256, .lower);
    const provenance_digest = std.fmt.bytesToHex(expected.provenance_sha256, .lower);
    if (!jsonStringIs(object.get("protocol_digest"), &protocol_digest) or
        !jsonStringIs(object.get("statement_digest"), &statement_digest) or
        !jsonStringIs(object.get("proof_digest"), &proof_digest) or
        !jsonStringIs(object.get("provenance_digest"), &provenance_digest))
        return error.RustVerifierDigestMismatch;
    const wall_time_value = object.get("wall_time_ns").?;
    if (wall_time_value != .integer or wall_time_value.integer <= 0)
        return error.InvalidRustVerifierResult;
    var result_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &result_digest, .{});
    return .{
        .protocol_digest = protocol_digest,
        .statement_digest = statement_digest,
        .proof_digest = proof_digest,
        .provenance_digest = provenance_digest,
        .executable_sha256 = config.executable_sha256,
        .wall_time_ns = @intCast(wall_time_value.integer),
        .service_wall_time_ns = service_wall_time_ns,
        .result_sha256 = std.fmt.bytesToHex(result_digest, .lower),
    };
}

fn jsonStringIs(value: ?std.json.Value, expected: []const u8) bool {
    const actual = value orelse return false;
    return actual == .string and std.mem.eql(u8, actual.string, expected);
}

fn jsonIntegerIs(value: ?std.json.Value, expected: u64) bool {
    const actual = value orelse return false;
    return actual == .integer and actual.integer >= 0 and actual.integer == expected;
}

fn measureExecutableIdentity(allocator: std.mem.Allocator) !ExecutableIdentity {
    const executable_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable_path);
    const measurement = try artifact_manifest.measureFile(allocator, executable_path);
    const digest_hex = std.fmt.bytesToHex(measurement.sha256, .lower);
    return .{
        .daemon_executable_sha256 = digest_hex,
        .runner_executable_sha256 = digest_hex,
        .measurement = measurement,
    };
}

fn temporaryPath(allocator: std.mem.Allocator, output: []const u8, sequence: u64, label: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.session-{}-{}-{s}.tmp", .{
        output,
        std.c.getpid(),
        sequence,
        label,
    });
}

fn requireAbsent(path: []const u8) !void {
    if (std.fs.accessAbsolute(path, .{})) |_| return error.TemporaryOutputExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
}

/// Publish a sibling temporary without replacing an output created after the
/// request's initial stale-output check.
fn publishExclusive(temporary: []const u8, output: []const u8) !void {
    try std.posix.link(temporary, output);
    std.fs.deleteFileAbsolute(temporary) catch {};
}

fn publishOutputsExclusive(
    proof_temporary: []const u8,
    proof_output: []const u8,
    report_temporary: []const u8,
    report_output: []const u8,
) !void {
    try publishExclusive(proof_temporary, proof_output);
    errdefer std.fs.deleteFileAbsolute(proof_output) catch {};
    try publishExclusive(report_temporary, report_output);
}

fn boolField(object: std.json.ObjectMap, name: []const u8) !bool {
    const value = object.get(name) orelse return error.InvalidCliReport;
    if (value != .bool) return error.InvalidCliReport;
    return value.bool;
}

fn requireCanonicalCliProtocol(object: std.json.ObjectMap) !void {
    if (!(optionalBoolField(object, "protocol_complete") orelse false) or
        !one_shot.protocolObjectIsCanonical(object.get("protocol")))
        return error.InvalidCliProtocol;
}

fn cliProvenance(object: std.json.ObjectMap) ProvenanceEvidence {
    const artifact_manifest_digest = optionalSha256HexField(object, "artifact_manifest_digest");
    const self_contained = optionalBoolField(object, "self_contained") orelse
        return .failClosed();
    const parity_fixture_used = optionalBoolField(object, "parity_fixture_used") orelse
        return .failClosed();
    const proof_derived_artifact_used = optionalBoolField(object, "proof_derived_artifact_used") orelse
        return .failClosed();
    const statement_self_derived = optionalBoolField(object, "statement_self_derived") orelse
        return .failClosed();

    // A self-contained classification cannot contradict its constituent
    // execution evidence. Preserve verified proofs, but classify malformed
    // provenance conservatively rather than publishing an impossible state.
    if (self_contained and
        (parity_fixture_used or proof_derived_artifact_used or !statement_self_derived))
    {
        return .failClosed();
    }

    if (artifact_manifest_digest == null) {
        return .{
            .self_contained = false,
            .parity_fixture_used = parity_fixture_used,
            .proof_derived_artifact_used = true,
            .statement_self_derived = statement_self_derived,
            .artifact_manifest_digest = null,
            .provenance_complete = false,
        };
    }
    return .{
        .self_contained = self_contained,
        .parity_fixture_used = parity_fixture_used,
        .proof_derived_artifact_used = proof_derived_artifact_used,
        .statement_self_derived = statement_self_derived,
        .artifact_manifest_digest = artifact_manifest_digest,
        .provenance_complete = true,
    };
}

fn optionalBoolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

fn optionalSha256HexField(object: std.json.ObjectMap, name: []const u8) ?[64]u8 {
    const value = object.get(name) orelse return null;
    if (value != .string or value.string.len != 64) return null;
    for (value.string) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return null,
    };
    var digest: [64]u8 = undefined;
    @memcpy(&digest, value.string);
    return digest;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.InvalidCliReport;
    if (value != .string) return error.InvalidCliReport;
    return value.string;
}

fn positiveNumberField(object: std.json.ObjectMap, name: []const u8) !f64 {
    const value = object.get(name) orelse return error.InvalidCliReport;
    const number: f64 = switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => return error.InvalidCliReport,
    };
    if (!std.math.isFinite(number) or number <= 0) return error.InvalidCliReport;
    return number;
}

fn positiveIntegerField(object: std.json.ObjectMap, name: []const u8) !u64 {
    const value = object.get(name) orelse return error.InvalidCliReport;
    if (value != .integer or value.integer <= 0) return error.InvalidCliReport;
    return @intCast(value.integer);
}

fn writeFrame(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

const TestBuiltinSpan = struct { begin: u64, stop: u64 };

const TestPerProofShape = struct {
    address_count: usize = 0,
    f252_count: usize = 0,
    small_count: usize = 0,
    public_count: usize = 0,
    ec_op_span: ?TestBuiltinSpan = null,
};

fn testAdaptedInputBytes(
    allocator: std.mem.Allocator,
    opcode_counts: [cairo_opcodes.N_OPCODES]u64,
    builtin_spans: [4]?TestBuiltinSpan,
    pc_count: u64,
    irrelevant_seed: u8,
    per_proof: TestPerProofShape,
) ![]u8 {
    var state_count: u64 = 0;
    for (opcode_counts) |count| state_count += count;
    const memory_payload_bytes = per_proof.address_count * @sizeOf(u32) +
        per_proof.f252_count * 8 * @sizeOf(u32) +
        per_proof.small_count * @sizeOf(u128);
    const public_payload_bytes = per_proof.public_count * @sizeOf(u32);
    const file_bytes = 64 + cairo_opcodes.N_OPCODES * 8 + state_count * 12 +
        48 + memory_payload_bytes + 8 + public_payload_bytes + 9 * 24;
    const bytes = try allocator.alloc(u8, @intCast(file_bytes));
    @memset(bytes, 0);
    @memcpy(bytes[0..8], "STWZCPI\x00");
    std.mem.writeInt(u32, bytes[8..12], cairo_adapted_input.VERSION, .little);
    bytes[16] = irrelevant_seed;
    std.mem.writeInt(u64, bytes[40..48], pc_count, .little);
    std.mem.writeInt(u32, bytes[56..60], cairo_opcodes.N_OPCODES, .little);
    var offset: usize = 64;
    for (opcode_counts) |count| {
        std.mem.writeInt(u64, bytes[offset..][0..8], count, .little);
        offset += 8 + @as(usize, @intCast(count)) * 12;
    }
    bytes[offset] = irrelevant_seed;
    std.mem.writeInt(u64, bytes[offset + 24 ..][0..8], per_proof.address_count, .little);
    std.mem.writeInt(u64, bytes[offset + 32 ..][0..8], per_proof.f252_count, .little);
    std.mem.writeInt(u64, bytes[offset + 40 ..][0..8], per_proof.small_count, .little);
    offset += 48;
    offset += memory_payload_bytes;
    std.mem.writeInt(u64, bytes[offset..][0..8], per_proof.public_count, .little);
    offset += 8;
    offset += public_payload_bytes;
    const geometry_segment_indices = [_]usize{ 1, 4, 5, 7 };
    var geometry_index: usize = 0;
    for (0..9) |segment_index| {
        if (geometry_index < geometry_segment_indices.len and
            geometry_segment_indices[geometry_index] == segment_index)
        {
            if (builtin_spans[geometry_index]) |span| {
                bytes[offset] = 1;
                std.mem.writeInt(u64, bytes[offset + 8 ..][0..8], span.begin, .little);
                std.mem.writeInt(u64, bytes[offset + 16 ..][0..8], span.stop, .little);
            }
            geometry_index += 1;
        } else if (segment_index == 8) {
            if (per_proof.ec_op_span) |span| {
                bytes[offset] = 1;
                std.mem.writeInt(u64, bytes[offset + 8 ..][0..8], span.begin, .little);
                std.mem.writeInt(u64, bytes[offset + 16 ..][0..8], span.stop, .little);
            }
        }
        offset += 24;
    }
    std.debug.assert(offset == bytes.len);
    return bytes;
}

test "adapted geometry validates layout and fingerprints only compatible row extents" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var opcode_counts = [_]u64{0} ** cairo_opcodes.N_OPCODES;
    opcode_counts[2] = 3;
    opcode_counts[18] = 4;
    const spans_a = [4]?TestBuiltinSpan{
        .{ .begin = 100, .stop = 150 },
        .{ .begin = 200, .stop = 230 },
        .{ .begin = 300, .stop = 360 },
        .{ .begin = 400, .stop = 410 },
    };
    const spans_b = [4]?TestBuiltinSpan{
        .{ .begin = 1_000, .stop = 1_050 },
        .{ .begin = 2_000, .stop = 2_030 },
        .{ .begin = 3_000, .stop = 3_060 },
        .{ .begin = 4_000, .stop = 4_010 },
    };
    const bytes_a = try testAdaptedInputBytes(std.testing.allocator, opcode_counts, spans_a, 17, 0x11, .{});
    defer std.testing.allocator.free(bytes_a);
    const bytes_b = try testAdaptedInputBytes(std.testing.allocator, opcode_counts, spans_b, 19, 0x22, .{});
    defer std.testing.allocator.free(bytes_b);
    try directory.dir.writeFile(.{ .sub_path = "a.stwzcpi", .data = bytes_a });
    try directory.dir.writeFile(.{ .sub_path = "b.stwzcpi", .data = bytes_b });
    const path_a = try directory.dir.realpathAlloc(std.testing.allocator, "a.stwzcpi");
    defer std.testing.allocator.free(path_a);
    const path_b = try directory.dir.realpathAlloc(std.testing.allocator, "b.stwzcpi");
    defer std.testing.allocator.free(path_b);

    const geometry_a = try adaptedGeometry(path_a, bytes_a.len);
    const geometry_b = try adaptedGeometry(path_b, bytes_b.len);
    try std.testing.expectEqual(geometry_a.fingerprint, geometry_b.fingerprint);
    try std.testing.expectEqual(@as(u64, 7), geometry_a.counts.cycles);
    try std.testing.expectEqual(@as(u64, 17), geometry_a.counts.pc_count);
    try std.testing.expectEqual(@as(u64, 19), geometry_b.counts.pc_count);

    var changed_counts = opcode_counts;
    changed_counts[2] += 1;
    const incompatible = try testAdaptedInputBytes(std.testing.allocator, changed_counts, spans_a, 17, 0x11, .{});
    defer std.testing.allocator.free(incompatible);
    try directory.dir.writeFile(.{ .sub_path = "incompatible.stwzcpi", .data = incompatible });
    const incompatible_path = try directory.dir.realpathAlloc(std.testing.allocator, "incompatible.stwzcpi");
    defer std.testing.allocator.free(incompatible_path);
    const incompatible_geometry = try adaptedGeometry(incompatible_path, incompatible.len);
    try std.testing.expect(!std.mem.eql(
        u8,
        &geometry_a.fingerprint,
        &incompatible_geometry.fingerprint,
    ));

    var changed_spans = spans_a;
    changed_spans[0].?.stop += 5;
    const incompatible_builtin = try testAdaptedInputBytes(
        std.testing.allocator,
        opcode_counts,
        changed_spans,
        17,
        0x11,
        .{},
    );
    defer std.testing.allocator.free(incompatible_builtin);
    try directory.dir.writeFile(.{ .sub_path = "incompatible-builtin.stwzcpi", .data = incompatible_builtin });
    const incompatible_builtin_path = try directory.dir.realpathAlloc(
        std.testing.allocator,
        "incompatible-builtin.stwzcpi",
    );
    defer std.testing.allocator.free(incompatible_builtin_path);
    const incompatible_builtin_geometry = try adaptedGeometry(
        incompatible_builtin_path,
        incompatible_builtin.len,
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &geometry_a.fingerprint,
        &incompatible_builtin_geometry.fingerprint,
    ));

    const trailing = try std.testing.allocator.alloc(u8, bytes_a.len + 1);
    defer std.testing.allocator.free(trailing);
    @memcpy(trailing[0..bytes_a.len], bytes_a);
    trailing[bytes_a.len] = 0xff;
    try directory.dir.writeFile(.{ .sub_path = "trailing.stwzcpi", .data = trailing });
    const trailing_path = try directory.dir.realpathAlloc(std.testing.allocator, "trailing.stwzcpi");
    defer std.testing.allocator.free(trailing_path);
    try std.testing.expectError(
        error.InvalidAdaptedInput,
        adaptedGeometry(trailing_path, trailing.len),
    );

    try std.testing.expectError(
        error.InvalidAdaptedInput,
        adaptedGeometry(path_a, bytes_a.len + 1),
    );
}

test "adapted geometry excludes per-proof runtime payload from plan compatibility" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var opcode_counts = [_]u64{0} ** cairo_opcodes.N_OPCODES;
    opcode_counts[7] = 5;
    const spans = [4]?TestBuiltinSpan{
        .{ .begin = 100, .stop = 150 },
        .{ .begin = 200, .stop = 230 },
        .{ .begin = 300, .stop = 360 },
        .{ .begin = 400, .stop = 410 },
    };
    const baseline = try testAdaptedInputBytes(
        std.testing.allocator,
        opcode_counts,
        spans,
        9,
        0x11,
        .{},
    );
    defer std.testing.allocator.free(baseline);
    const runtime_changed = try testAdaptedInputBytes(
        std.testing.allocator,
        opcode_counts,
        spans,
        23,
        0x22,
        .{
            .address_count = 7,
            .f252_count = 2,
            .small_count = 3,
            .public_count = 4,
            .ec_op_span = .{ .begin = 5_000, .stop = 5_700 },
        },
    );
    defer std.testing.allocator.free(runtime_changed);
    try directory.dir.writeFile(.{ .sub_path = "baseline.stwzcpi", .data = baseline });
    try directory.dir.writeFile(.{ .sub_path = "runtime-changed.stwzcpi", .data = runtime_changed });
    const baseline_path = try directory.dir.realpathAlloc(std.testing.allocator, "baseline.stwzcpi");
    defer std.testing.allocator.free(baseline_path);
    const runtime_path = try directory.dir.realpathAlloc(std.testing.allocator, "runtime-changed.stwzcpi");
    defer std.testing.allocator.free(runtime_path);

    const baseline_geometry = try adaptedGeometry(baseline_path, baseline.len);
    const runtime_geometry = try adaptedGeometry(runtime_path, runtime_changed.len);
    try std.testing.expectEqual(baseline_geometry.fingerprint, runtime_geometry.fingerprint);
    try std.testing.expectEqual(@as(u64, 9), baseline_geometry.counts.pc_count);
    try std.testing.expectEqual(@as(u64, 23), runtime_geometry.counts.pc_count);
}

test "persistent report uses schema version 3" {
    try std.testing.expectEqual(@as(u32, 3), persistent_report_schema_version);
}

test "persistent view cache reuses exact objects without changing store identity" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "evaluations.bin", .data = "evaluations" });
    try temporary.dir.writeFile(.{ .sub_path = "composition.bin", .data = "composition" });
    try temporary.dir.writeFile(.{ .sub_path = "composition.metallib", .data = "metallib" });
    var tree_bytes: [60]u8 = [_]u8{0} ** 60;
    @memcpy(tree_bytes[0..8], "STWZMRK\x00");
    std.mem.writeInt(u32, tree_bytes[8..12], 1, .little);
    std.mem.writeInt(u32, tree_bytes[12..16], 0, .little);
    std.mem.writeInt(u32, tree_bytes[16..20], 1, .little);
    std.mem.writeInt(u64, tree_bytes[20..28], 32, .little);
    for (tree_bytes[28..], 0..) |*byte, index| byte.* = @intCast(index);
    try temporary.dir.writeFile(.{ .sub_path = "tree.bin", .data = &tree_bytes });

    const parent = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(parent);
    const store_root = try std.fs.path.join(std.testing.allocator, &.{ parent, "store" });
    defer std.testing.allocator.free(store_root);
    var store = try artifact_store.Store.initNew(std.testing.allocator, store_root, true);
    defer store.deinit();
    const names = [_][]const u8{ "evaluations.bin", "tree.bin", "composition.bin", "composition.metallib" };
    var snapshots: [names.len]artifact_store.Snapshot = undefined;
    var initialized: usize = 0;
    defer for (snapshots[0..initialized]) |*snapshot| snapshot.deinit(std.testing.allocator);
    while (initialized < names.len) : (initialized += 1) {
        const source = try temporary.dir.realpathAlloc(std.testing.allocator, names[initialized]);
        defer std.testing.allocator.free(source);
        snapshots[initialized] = try store.ingestPathWithPolicy(source, .byte_copy);
    }

    var expected_root: [32]u8 = undefined;
    for (&expected_root, 0..) |*byte, index| byte.* = @intCast(index);
    const inputs = artifact_views.Inputs{
        .preprocessed_evaluations = immutableObject(&snapshots[0]),
        .preprocessed_tree0_merkle = immutableObject(&snapshots[1]),
        .composition = immutableObject(&snapshots[2]),
        .composition_program = .{ .metallib = immutableObject(&snapshots[3]) },
        .expected_tree0_root = expected_root,
    };
    var views = ViewCache.init(std.testing.allocator);
    const first = try views.getOrCreate(store.root_path, "first", inputs);
    const first_directory = try std.testing.allocator.dupe(u8, first.directory);
    defer std.testing.allocator.free(first_directory);
    const second = try views.getOrCreate(store.root_path, "second", inputs);
    try std.testing.expectEqual(@as(usize, 1), views.views.count());
    try std.testing.expectEqualStrings(first_directory, second.directory);
    views.deinit();

    for (&snapshots) |*snapshot| {
        var resolved = try store.resolveRef(snapshot.ref());
        resolved.deinit(std.testing.allocator);
    }
}

test "reference environment preserves diagnostics and omits absent references" {
    const base = RunnerArtifacts{
        .adapted_input = "/a",
        .schedule = "/b",
        .witness_programs = "/c",
        .multiplicity_feeds = "/d",
        .relation_templates = "/e",
        .fixed_tables = "/f",
        .composition = "/g",
        .composition_program = "/g.metallib",
        .preprocessed_evaluations = "/h",
        .preprocessed_tree0_merkle = "/h.tree0-merkle",
        .preprocessed_coefficients = "/i",
        .transcript_reference = null,
        .quotient_reference = null,
    };
    const absent = referenceEnvironment(base);
    try std.testing.expectEqual(null, absent[0]);
    try std.testing.expectEqual(null, absent[1]);
    try std.testing.expectEqual(null, absent[2]);

    var diagnostic = base;
    diagnostic.transcript_reference = "/transcript.json";
    diagnostic.quotient_reference = "/quotient.bin";
    const present = referenceEnvironment(diagnostic);
    try std.testing.expectEqualStrings("STWO_ZIG_SN2_TRANSCRIPT_REFERENCE", present[0].?.name);
    try std.testing.expectEqualStrings("/transcript.json", present[0].?.value);
    try std.testing.expectEqualStrings("STWO_ZIG_SN2_QUOTIENT_REFERENCE", present[1].?.name);
    try std.testing.expectEqualStrings("/quotient.bin", present[1].?.value);
    try std.testing.expectEqualStrings("STWO_ZIG_SN2_REPLAY_TRANSCRIPT_AFTER_TREE2", present[2].?.name);
    try std.testing.expectEqualStrings("1", present[2].?.value);
}

test "reference-free session scrubs every hidden transcript control" {
    const forbidden = [_][]const u8{
        "STWO_ZIG_SN2_TRANSCRIPT_REFERENCE",
        "STWO_ZIG_SN2_QUOTIENT_REFERENCE",
        "STWO_ZIG_SN2_REPLAY_TRANSCRIPT_AFTER_TREE2",
        "STWO_ZIG_SN2_TRANSCRIPT_BOOTSTRAP",
        "STWO_ZIG_SN2_RESTORE_REFERENCE_RELATION_CHALLENGES",
    };
    for (forbidden) |name|
        try std.testing.expect(isSessionScrubbedRunnerEnvironment(name));

    try std.testing.expect(!isSessionScrubbedRunnerEnvironment(
        "STWO_ZIG_METAL_REPLAY_RETAINED_LOOKUPS",
    ));
    try std.testing.expect(!isSessionScrubbedRunnerEnvironment("PATH"));
}

test "CLI provenance promotes complete authoritative runner evidence" {
    const encoded =
        \\{"self_contained":false,"parity_fixture_used":false,"proof_derived_artifact_used":true,"statement_self_derived":true,"artifact_manifest_digest":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();

    const evidence = cliProvenance(parsed.value.object);
    try std.testing.expect(!evidence.self_contained);
    try std.testing.expect(!evidence.parity_fixture_used);
    try std.testing.expect(evidence.proof_derived_artifact_used);
    try std.testing.expect(evidence.statement_self_derived);
    try std.testing.expect(evidence.provenance_complete);
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        &evidence.artifact_manifest_digest.?,
    );
}

test "CLI provenance preserves execution evidence while withholding completeness" {
    const encoded =
        \\{"self_contained":false,"parity_fixture_used":false,"proof_derived_artifact_used":true,"statement_self_derived":true}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();

    const evidence = cliProvenance(parsed.value.object);
    try std.testing.expect(!evidence.self_contained);
    try std.testing.expect(!evidence.parity_fixture_used);
    try std.testing.expect(evidence.proof_derived_artifact_used);
    try std.testing.expect(evidence.statement_self_derived);
    try std.testing.expectEqual(null, evidence.artifact_manifest_digest);
    try std.testing.expect(!evidence.provenance_complete);
}

test "CLI provenance fails closed on absent malformed or contradictory booleans" {
    const cases = [_][]const u8{
        "{\"self_contained\":false,\"parity_fixture_used\":false,\"proof_derived_artifact_used\":true}",
        "{\"self_contained\":false,\"parity_fixture_used\":\"false\",\"proof_derived_artifact_used\":true,\"statement_self_derived\":true}",
        "{\"self_contained\":true,\"parity_fixture_used\":true,\"proof_derived_artifact_used\":false,\"statement_self_derived\":true}",
        "{\"self_contained\":true,\"parity_fixture_used\":false,\"proof_derived_artifact_used\":true,\"statement_self_derived\":true}",
        "{\"self_contained\":true,\"parity_fixture_used\":false,\"proof_derived_artifact_used\":false,\"statement_self_derived\":false}",
    };
    for (cases) |encoded| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
        defer parsed.deinit();
        const evidence = cliProvenance(parsed.value.object);
        try std.testing.expect(!evidence.self_contained);
        try std.testing.expect(evidence.parity_fixture_used);
        try std.testing.expect(evidence.proof_derived_artifact_used);
        try std.testing.expect(!evidence.statement_self_derived);
        try std.testing.expectEqual(null, evidence.artifact_manifest_digest);
        try std.testing.expect(!evidence.provenance_complete);
    }
}

test "CLI provenance rejects a malformed digest while preserving statement evidence" {
    const encoded =
        \\{"self_contained":false,"parity_fixture_used":false,"proof_derived_artifact_used":true,"statement_self_derived":true,"artifact_manifest_digest":"0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();

    const evidence = cliProvenance(parsed.value.object);
    try std.testing.expect(!evidence.self_contained);
    try std.testing.expect(!evidence.parity_fixture_used);
    try std.testing.expect(evidence.proof_derived_artifact_used);
    try std.testing.expect(evidence.statement_self_derived);
    try std.testing.expectEqual(null, evidence.artifact_manifest_digest);
    try std.testing.expect(!evidence.provenance_complete);
}

test "CLI protocol evidence is exact and fail closed" {
    const valid =
        \\{"protocol_complete":true,"protocol":{"channel":"blake2s","channel_salt":0,"log_blowup_factor":1,"n_queries":70,"interaction_pow_bits":24,"query_pow_bits":26,"fri_fold_step":3,"fri_lifting":null,"fri_log_last_layer_degree_bound":0}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, valid, .{});
    defer parsed.deinit();
    try requireCanonicalCliProtocol(parsed.value.object);

    const invalid = [_][]const u8{
        "{\"protocol_complete\":false,\"protocol\":{\"channel\":\"blake2s\",\"channel_salt\":0,\"log_blowup_factor\":1,\"n_queries\":70,\"interaction_pow_bits\":24,\"query_pow_bits\":26,\"fri_fold_step\":3,\"fri_lifting\":null,\"fri_log_last_layer_degree_bound\":0}}",
        "{\"protocol_complete\":true,\"protocol\":{\"channel\":\"blake2s\",\"channel_salt\":0,\"log_blowup_factor\":1,\"n_queries\":70,\"interaction_pow_bits\":24,\"query_pow_bits\":25,\"fri_fold_step\":3,\"fri_lifting\":null,\"fri_log_last_layer_degree_bound\":0}}",
        "{\"protocol_complete\":true}",
    };
    for (invalid) |document| {
        var candidate = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
        defer candidate.deinit();
        try std.testing.expectError(
            error.InvalidCliProtocol,
            requireCanonicalCliProtocol(candidate.value.object),
        );
    }
}

test "verified result frame promotes normalized provenance" {
    const request = protocol.Request{
        .sequence = 7,
        .request_id = "sn-7",
        .artifacts = .{
            .adapted_input = .{ .path = "/a" },
            .schedule = .{ .path = "/b" },
            .witness_programs = .{ .path = "/c" },
            .multiplicity_feeds = .{ .path = "/d" },
            .relation_templates = .{ .path = "/e" },
            .fixed_tables = .{ .path = "/f" },
            .composition = .{ .path = "/g" },
            .composition_program = .{ .path = "/g.metallib" },
            .preprocessed_evaluations = .{ .path = "/h" },
            .preprocessed_tree0_merkle = .{ .path = "/h.tree0-merkle" },
            .preprocessed_coefficients = .{ .path = "/i" },
            .transcript_reference = null,
            .quotient_reference = null,
        },
        .proof_output = "/tmp/proof",
        .report_output = "/tmp/report",
        .budget_gib = "24",
        .expected_tree0_root_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    };
    var result = ProofResult{
        .adapted_cycles = 8_000_000,
        .adapted_input_sha256 = [_]u8{'a'} ** 64,
        .prove_wall_s = 2,
        .prove_mhz = 4,
        .session_block_wall_s = 3,
        .proof_bytes = 1024,
        .proof_sha256 = [_]u8{'b'} ** 64,
        .pipeline_cache_delta = .zero(),
        .provenance = .{
            .self_contained = false,
            .parity_fixture_used = false,
            .proof_derived_artifact_used = true,
            .statement_self_derived = true,
            .artifact_manifest_digest = [_]u8{'c'} ** 64,
            .provenance_complete = true,
        },
        .executable_identity = .{
            .daemon_executable_sha256 = [_]u8{'d'} ** 64,
            .runner_executable_sha256 = [_]u8{'d'} ** 64,
        },
        .rust_verifier = .{
            .protocol_digest = [_]u8{'e'} ** 64,
            .statement_digest = [_]u8{'f'} ** 64,
            .proof_digest = [_]u8{'b'} ** 64,
            .provenance_digest = [_]u8{'1'} ** 64,
            .executable_sha256 = [_]u8{'2'} ** 64,
            .wall_time_ns = 70_000_000,
            .service_wall_time_ns = 75_000_000,
            .result_sha256 = [_]u8{'3'} ** 64,
        },
        .artifact_objects = testArtifactObjects(),
        .prepared_state_cache_hit = false,
    };
    var encoded: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&encoded);
    try writeVerifiedResultFrame(&writer, request, result);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        writer.buffered(),
        .{},
    );
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("result", object.get("type").?.string);
    try std.testing.expect(!object.get("self_contained").?.bool);
    try std.testing.expect(!object.get("parity_fixture_used").?.bool);
    try std.testing.expect(object.get("proof_derived_artifact_used").?.bool);
    try std.testing.expect(object.get("statement_self_derived").?.bool);
    try std.testing.expectEqualStrings(
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        object.get("artifact_manifest_digest").?.string,
    );
    try std.testing.expect(object.get("provenance_complete").?.bool);
    try std.testing.expect(object.get("protocol_complete").?.bool);
    try std.testing.expect(one_shot.protocolObjectIsCanonical(object.get("proof_protocol")));
    try std.testing.expectEqualStrings(
        "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        object.get("daemon_executable_sha256").?.string,
    );
    try std.testing.expectEqualStrings(
        object.get("daemon_executable_sha256").?.string,
        object.get("runner_executable_sha256").?.string,
    );
    try std.testing.expectEqualStrings(
        in_process_runner_linkage,
        object.get("runner_linkage").?.string,
    );
    try std.testing.expect(!object.get("reuse").?.object.get("resident_arena").?.bool);
    try std.testing.expect(!object.get("reuse").?.object.get("preprocessed_state").?.bool);
    try std.testing.expectEqualStrings(
        "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        object.get("artifact_objects").?.object.get("adapted_input").?.object.get("object_id").?.string,
    );

    result.prepared_state_cache_hit = true;
    var reused_encoded: [4096]u8 = undefined;
    var reused_writer = std.Io.Writer.fixed(&reused_encoded);
    try writeVerifiedResultFrame(&reused_writer, request, result);
    var reused = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        reused_writer.buffered(),
        .{},
    );
    defer reused.deinit();
    try std.testing.expect(reused.value.object.get("reuse").?.object.get("resident_arena").?.bool);
    try std.testing.expect(reused.value.object.get("reuse").?.object.get("preprocessed_state").?.bool);
}

fn testArtifactObjects() ArtifactObjectsEvidence {
    const value = ArtifactObjectEvidence{
        .object_id = [_]u8{0xee} ** 32,
        .bytes = 1,
        .diagnostic_path = "/artifact",
    };
    return .{
        .adapted_input = value,
        .schedule = value,
        .witness_programs = value,
        .multiplicity_feeds = value,
        .relation_templates = value,
        .fixed_tables = value,
        .composition = value,
        .composition_program = value,
        .preprocessed_evaluations = value,
        .preprocessed_tree0_merkle = value,
        .preprocessed_coefficients = value,
        .transcript_reference = null,
        .quotient_reference = null,
    };
}

test "prepared state key excludes block input and diagnostics and binds immutable geometry" {
    const root = [_]u8{'a'} ** 64;
    const executable = [_]u8{0x11} ** 32;
    const protocol_digest = [_]u8{0x22} ** 32;
    const base = testArtifactObjects();
    const expected = try preparedStateKey(base, root, "24", .metallib, executable, protocol_digest);

    var per_block = base;
    per_block.adapted_input.object_id[0] ^= 0xff;
    per_block.adapted_input.bytes += 1;
    per_block.adapted_input.diagnostic_path = "/different/block";
    per_block.transcript_reference = .{
        .object_id = [_]u8{0x44} ** 32,
        .bytes = 999,
        .diagnostic_path = "/reference",
    };
    try std.testing.expectEqual(expected, try preparedStateKey(
        per_block,
        root,
        "24",
        .metallib,
        executable,
        protocol_digest,
    ));
    var diagnostic = base;
    diagnostic.schedule.diagnostic_path = "/same/object/different/path";
    try std.testing.expectEqual(expected, try preparedStateKey(
        diagnostic,
        root,
        "24",
        .metallib,
        executable,
        protocol_digest,
    ));

    inline for (.{
        "schedule",
        "witness_programs",
        "multiplicity_feeds",
        "relation_templates",
        "fixed_tables",
        "composition",
        "composition_program",
        "preprocessed_evaluations",
        "preprocessed_tree0_merkle",
        "preprocessed_coefficients",
    }) |name| {
        var changed = base;
        @field(changed, name).object_id[0] ^= 0x01;
        const actual = try preparedStateKey(
            changed,
            root,
            "24",
            .metallib,
            executable,
            protocol_digest,
        );
        try std.testing.expect(!std.mem.eql(u8, &expected, &actual));
    }
    var changed_root = root;
    changed_root[0] = 'b';
    const root_key = try preparedStateKey(base, changed_root, "24", .metallib, executable, protocol_digest);
    const budget_key = try preparedStateKey(base, root, "23", .metallib, executable, protocol_digest);
    const kind_key = try preparedStateKey(base, root, "24", .metal, executable, protocol_digest);
    try std.testing.expect(!std.mem.eql(u8, &expected, &root_key));
    try std.testing.expect(!std.mem.eql(u8, &expected, &budget_key));
    try std.testing.expect(!std.mem.eql(u8, &expected, &kind_key));
    var changed_executable = executable;
    changed_executable[0] ^= 1;
    const executable_key = try preparedStateKey(base, root, "24", .metallib, changed_executable, protocol_digest);
    try std.testing.expect(!std.mem.eql(u8, &expected, &executable_key));
    var changed_protocol = protocol_digest;
    changed_protocol[0] ^= 1;
    const protocol_key = try preparedStateKey(base, root, "24", .metallib, executable, changed_protocol);
    try std.testing.expect(!std.mem.eql(u8, &expected, &protocol_key));
}

test "prepared geometry key reuses different adapted objects with compatible row geometry" {
    const root = [_]u8{'a'} ** 64;
    const executable = [_]u8{0x11} ** 32;
    const protocol_digest = [_]u8{0x22} ** 32;
    const policy = PreparedGeometryPolicy{ .replay_retained_lookups = false };
    const base = testArtifactObjects();
    const row_geometry = [_]u8{0x33} ** 32;
    const resident_key = try preparedStateKey(base, root, "24", .metallib, executable, protocol_digest);
    const geometry_key = preparedGeometryKey(resident_key, row_geometry, policy);

    var changed_identity = base;
    changed_identity.adapted_input.object_id[0] ^= 0xff;
    const identity_resident_key = try preparedStateKey(
        changed_identity,
        root,
        "24",
        .metallib,
        executable,
        protocol_digest,
    );
    try std.testing.expectEqual(resident_key, identity_resident_key);
    const identity_geometry_key = preparedGeometryKey(identity_resident_key, row_geometry, policy);
    try std.testing.expectEqual(geometry_key, identity_geometry_key);

    var changed_bytes = base;
    changed_bytes.adapted_input.bytes += 1;
    const bytes_resident_key = try preparedStateKey(
        changed_bytes,
        root,
        "24",
        .metallib,
        executable,
        protocol_digest,
    );
    try std.testing.expectEqual(resident_key, bytes_resident_key);
    const bytes_geometry_key = preparedGeometryKey(bytes_resident_key, row_geometry, policy);
    try std.testing.expectEqual(geometry_key, bytes_geometry_key);

    var incompatible_geometry = row_geometry;
    incompatible_geometry[0] ^= 0xff;
    const incompatible_key = preparedGeometryKey(resident_key, incompatible_geometry, policy);
    try std.testing.expect(!std.mem.eql(u8, &geometry_key, &incompatible_key));
    try std.testing.expect(!std.mem.eql(u8, &resident_key, &geometry_key));
}

test "prepared geometry key binds retained lookup policy" {
    const root = [_]u8{'a'} ** 64;
    const executable = [_]u8{0x11} ** 32;
    const protocol_digest = [_]u8{0x22} ** 32;
    const row_geometry = [_]u8{0x33} ** 32;
    const objects = testArtifactObjects();
    const resident_key = try preparedStateKey(objects, root, "24", .metallib, executable, protocol_digest);
    const retained = preparedGeometryKey(
        resident_key,
        row_geometry,
        .{ .replay_retained_lookups = false },
    );
    const replayed = preparedGeometryKey(
        resident_key,
        row_geometry,
        .{ .replay_retained_lookups = true },
    );
    try std.testing.expect(!std.mem.eql(u8, &retained, &replayed));
}

test "prepared host geometry cache owns exact-key parsed schedule transactionally" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(.{
        .sub_path = "a.json",
        .data = "{\"arena\":{\"logical_buffer_schedule\":[]}}",
    });
    try directory.dir.writeFile(.{
        .sub_path = "b.json",
        .data = "{\"arena\":{\"logical_buffer_schedule\":[{\"id\":1}]}}",
    });
    const root = try directory.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path_a = try std.fs.path.join(std.testing.allocator, &.{ root, "a.json" });
    defer std.testing.allocator.free(path_a);
    const path_b = try std.fs.path.join(std.testing.allocator, &.{ root, "b.json" });
    defer std.testing.allocator.free(path_b);
    const args_a = [_][]const u8{ "metal-arena-plan", path_a, "1" };
    const args_b = [_][]const u8{ "metal-arena-plan", path_b, "1" };
    const key_a = [_]u8{0x11} ** 32;
    const key_b = [_]u8{0x22} ** 32;
    var cache = PreparedHostGeometryCache.init(std.testing.allocator);
    defer cache.deinit();

    const first = try cache.begin(key_a, &args_a);
    try std.testing.expect(!first.cache_hit);
    try cache.commit();
    try directory.dir.deleteFile("a.json");

    const reused = try cache.begin(key_a, &args_a);
    try std.testing.expect(reused.cache_hit);
    try std.testing.expect(reused.geometry == first.geometry);
    try cache.commit();

    const pending = try cache.begin(key_b, &args_b);
    try std.testing.expect(!pending.cache_hit);
    cache.poison();
    var committed: usize = 0;
    for (cache.entries) |entry| if (entry != null) {
        committed += 1;
        try std.testing.expectEqual(key_a, entry.?.key);
    };
    try std.testing.expectEqual(@as(usize, 1), committed);

    const fill_keys = [_]PreparedGeometryKey{
        key_b,
        [_]u8{0x33} ** 32,
        [_]u8{0x44} ** 32,
    };
    for (fill_keys) |key| {
        _ = try cache.begin(key, &args_b);
        try cache.commit();
    }
    _ = try cache.begin(key_a, &args_a);
    try cache.commit();
    const key_e = [_]u8{0x55} ** 32;
    _ = try cache.begin(key_e, &args_b);
    try cache.commit();
    var retained_a = false;
    var retained_b = false;
    for (cache.entries) |entry| if (entry) |value| {
        retained_a = retained_a or std.mem.eql(u8, &value.key, &key_a);
        retained_b = retained_b or std.mem.eql(u8, &value.key, &key_b);
    };
    try std.testing.expect(retained_a);
    try std.testing.expect(!retained_b);
}

test "executable identity measures this in-process runner" {
    const identity = try measureExecutableIdentity(std.testing.allocator);
    try std.testing.expectEqualSlices(
        u8,
        &identity.daemon_executable_sha256,
        &identity.runner_executable_sha256,
    );
    for (identity.daemon_executable_sha256) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return error.InvalidExecutableDigest,
    };
}

test "publishExclusive never replaces a stale output" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    const temporary = try directory.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(temporary);
    const temporary_path = try std.fs.path.join(std.testing.allocator, &.{ temporary, "proof.tmp" });
    defer std.testing.allocator.free(temporary_path);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ temporary, "proof.bin" });
    defer std.testing.allocator.free(output_path);

    {
        const file = try std.fs.createFileAbsolute(temporary_path, .{ .exclusive = true });
        defer file.close();
        try file.writeAll("verified-proof");
        try file.sync();
    }
    try publishExclusive(temporary_path, output_path);
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(temporary_path, .{}));

    const published = try std.fs.openFileAbsolute(output_path, .{});
    defer published.close();
    var published_bytes: [14]u8 = undefined;
    try std.testing.expectEqual(published_bytes.len, try published.readAll(&published_bytes));
    try std.testing.expectEqualStrings("verified-proof", &published_bytes);

    {
        const file = try std.fs.createFileAbsolute(temporary_path, .{ .exclusive = true });
        defer file.close();
        try file.writeAll("replacement");
    }
    try std.testing.expectError(error.PathAlreadyExists, publishExclusive(temporary_path, output_path));
    try std.fs.accessAbsolute(temporary_path, .{});
}

test "output publication removes proof when report publication fails" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const root = try directory.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const proof_temporary = try std.fs.path.join(std.testing.allocator, &.{ root, "proof.tmp" });
    defer std.testing.allocator.free(proof_temporary);
    const proof_output = try std.fs.path.join(std.testing.allocator, &.{ root, "proof.bin" });
    defer std.testing.allocator.free(proof_output);
    const report_temporary = try std.fs.path.join(std.testing.allocator, &.{ root, "report.tmp" });
    defer std.testing.allocator.free(report_temporary);
    const report_output = try std.fs.path.join(std.testing.allocator, &.{ root, "report.json" });
    defer std.testing.allocator.free(report_output);

    for ([_][]const u8{ proof_temporary, report_temporary, report_output }) |path| {
        const file = try std.fs.createFileAbsolute(path, .{ .exclusive = true });
        defer file.close();
        try file.writeAll(path);
    }
    try std.testing.expectError(
        error.PathAlreadyExists,
        publishOutputsExclusive(proof_temporary, proof_output, report_temporary, report_output),
    );
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(proof_output, .{}));
    try std.fs.accessAbsolute(report_output, .{});
}
