//! Canonical CP-11 serialization of production-bound relation evidence.

const std = @import("std");
const M31 = @import("../../../core/fields/m31.zig").M31;
const QM31 = @import("../../../core/fields/qm31.zig").QM31;
const entry = @import("lookups/entry.zig");
const relation_export = @import("relation_export.zig");
const relations_mod = @import("relation_challenges.zig");
const witness_layout = @import("../witness_layout.zig");

pub const Error = entry.Error || error{
    ComponentOutOfOrder,
    ComponentClaimMismatch,
    ComponentDomainSumMismatch,
    AggregateClaimMismatch,
    AggregateDomainSumMismatch,
    InvalidStreamCounts,
    InvalidDomainCounts,
    InvalidPublicDomains,
    InvalidPublicTotal,
    InvalidWitnessLayout,
};

pub const Bundle = struct {
    witness_layout_digest: [32]u8,
    components: [relation_export.COMPONENT_COUNT]relation_export.ComponentEvidence,
    aggregate: relation_export.AggregateEvidence,
    claims: relation_export.ClaimEvidence,
    public: relation_export.PublicEvidence,

    pub fn validate(self: *const Bundle) Error!void {
        if (!std.mem.eql(u8, &self.witness_layout_digest, &witness_layout.digest()))
            return error.InvalidWitnessLayout;
        var component_domains = [_]QM31{QM31.zero()} ** relation_export.DOMAIN_COUNT;
        var component_total = QM31.zero();
        var aggregate_entries: u64 = 0;
        var aggregate_zero: u64 = 0;
        var aggregate_nonzero: u64 = 0;
        var domain_entries = [_]u64{0} ** relation_export.DOMAIN_COUNT;
        var domain_zero = [_]u64{0} ** relation_export.DOMAIN_COUNT;
        var domain_nonzero = [_]u64{0} ** relation_export.DOMAIN_COUNT;

        for (self.components, 0..) |component, index| {
            if (@intFromEnum(component.component) != index)
                return error.ComponentOutOfOrder;
            try validateStreams(
                component.all,
                component.zero,
                component.nonzero,
                component.domains,
                component.domain_zero,
                component.domain_nonzero,
            );
            var domain_total = QM31.zero();
            for (component.domain_sums, 0..) |sum, domain| {
                domain_total = domain_total.add(sum);
                component_domains[domain] = component_domains[domain].add(sum);
                domain_entries[domain] += component.domains[domain].entries;
                domain_zero[domain] += component.domain_zero[domain].entries;
                domain_nonzero[domain] += component.domain_nonzero[domain].entries;
            }
            if (!domain_total.eql(component.computed_claim))
                return error.ComponentDomainSumMismatch;
            if (!component.computed_claim.eql(component.native_claim) or
                !component.native_claim.eql(self.claims.claims[index]))
                return error.ComponentClaimMismatch;
            component_total = component_total.add(component.native_claim);
            aggregate_entries += component.all.entries;
            aggregate_zero += component.zero.entries;
            aggregate_nonzero += component.nonzero.entries;
        }

        try validateStreams(
            self.aggregate.all,
            self.aggregate.zero,
            self.aggregate.nonzero,
            self.aggregate.domains,
            self.aggregate.domain_zero,
            self.aggregate.domain_nonzero,
        );
        if (self.aggregate.all.entries != aggregate_entries or
            self.aggregate.zero.entries != aggregate_zero or
            self.aggregate.nonzero.entries != aggregate_nonzero)
            return error.InvalidStreamCounts;
        for (0..relation_export.DOMAIN_COUNT) |domain| {
            if (self.aggregate.domains[domain].entries != domain_entries[domain] or
                self.aggregate.domain_zero[domain].entries != domain_zero[domain] or
                self.aggregate.domain_nonzero[domain].entries != domain_nonzero[domain])
                return error.InvalidDomainCounts;
            if (!self.aggregate.domain_sums[domain].eql(component_domains[domain]))
                return error.AggregateDomainSumMismatch;
        }
        if (!component_total.eql(self.claims.total)) return error.AggregateClaimMismatch;
        var aggregate_domain_total = QM31.zero();
        for (self.aggregate.domain_sums) |sum| {
            aggregate_domain_total = aggregate_domain_total.add(sum);
        }
        if (!aggregate_domain_total.eql(self.claims.total))
            return error.AggregateDomainSumMismatch;

        var public_total = QM31.zero();
        for (self.public.domains, 0..) |sum, domain| {
            public_total = public_total.add(sum);
            const relation: relation_export.Domain = @enumFromInt(domain);
            switch (relation) {
                .registers_state, .memory_access, .merkle => {},
                else => if (!sum.isZero()) return error.InvalidPublicDomains,
            }
        }
        if (!public_total.eql(self.public.total)) return error.InvalidPublicTotal;
    }
};

pub fn writeTuples(writer: anytype, bundle: *const Bundle) !void {
    try bundle.validate();
    try writer.writeAll("schema=riscv-relation-tuples-v2\n");
    for (bundle.components) |component| {
        try writeStream(writer, "component", @tagName(component.component), component);
        for (0..relation_export.DOMAIN_COUNT) |domain_index| {
            const domain: relation_export.Domain = @enumFromInt(domain_index);
            var identity: [96]u8 = undefined;
            const name = try std.fmt.bufPrint(
                &identity,
                "{s}/{s}",
                .{ @tagName(component.component), @tagName(domain) },
            );
            try writeRawStream(
                writer,
                "component_relation",
                name,
                component.domains[domain_index],
                component.domain_zero[domain_index],
                component.domain_nonzero[domain_index],
            );
        }
    }
    try writeStream(writer, "aggregate", "all_components", bundle.aggregate);
    for (0..relation_export.DOMAIN_COUNT) |domain_index| {
        const domain: relation_export.Domain = @enumFromInt(domain_index);
        try writeRawStream(
            writer,
            "aggregate_relation",
            @tagName(domain),
            bundle.aggregate.domains[domain_index],
            bundle.aggregate.domain_zero[domain_index],
            bundle.aggregate.domain_nonzero[domain_index],
        );
    }
}

pub fn writeSums(
    writer: anytype,
    bundle: *const Bundle,
    relations: *const relations_mod.Relations,
) !void {
    try bundle.validate();
    try writer.writeAll("schema=riscv-relation-sums-v1\n");
    for (0..relation_export.DOMAIN_COUNT) |domain_index| {
        const domain: relation_export.Domain = @enumFromInt(domain_index);
        try writer.print("challenge={s} signature=", .{@tagName(domain)});
        try writeQm31(writer, try relationSignature(domain, relations));
        try writer.writeByte('\n');
    }
    for (bundle.components, 0..) |component, index| {
        try writer.print("component={s} claim=", .{@tagName(component.component)});
        try writeQm31(writer, bundle.claims.claims[index]);
        try writer.writeAll(" prefix=");
        try writeQm31(writer, bundle.claims.prefixes[index]);
        try writer.writeByte('\n');
    }
    for (bundle.aggregate.domain_sums, 0..) |sum, domain_index| {
        const domain: relation_export.Domain = @enumFromInt(domain_index);
        try writer.print("relation={s} sum=", .{@tagName(domain)});
        try writeQm31(writer, sum);
        try writer.writeByte('\n');
    }
    inline for (.{
        relation_export.Domain.registers_state,
        relation_export.Domain.merkle,
        relation_export.Domain.memory_access,
    }) |domain| {
        try writer.print("public={s} sum=", .{@tagName(domain)});
        try writeQm31(writer, bundle.public.domains[@intFromEnum(domain)]);
        try writer.writeByte('\n');
    }
    try writer.writeAll("aggregate=native sum=");
    try writeQm31(writer, bundle.claims.total);
    try writer.writeAll(" public_sum=");
    try writeQm31(writer, bundle.public.total);
    try writer.writeAll(" balanced_sum=");
    try writeQm31(writer, bundle.claims.total.add(bundle.public.total));
    try writer.writeByte('\n');
}

fn validateStreams(
    all: relation_export.StreamDigest,
    zero: relation_export.StreamDigest,
    nonzero: relation_export.StreamDigest,
    domains: [relation_export.DOMAIN_COUNT]relation_export.StreamDigest,
    domain_zero: [relation_export.DOMAIN_COUNT]relation_export.StreamDigest,
    domain_nonzero: [relation_export.DOMAIN_COUNT]relation_export.StreamDigest,
) Error!void {
    if (all.entries != zero.entries + nonzero.entries)
        return error.InvalidStreamCounts;
    var all_count: u64 = 0;
    var zero_count: u64 = 0;
    var nonzero_count: u64 = 0;
    for (domains, domain_zero, domain_nonzero) |domain, zeros, nonzeros| {
        if (domain.entries != zeros.entries + nonzeros.entries)
            return error.InvalidDomainCounts;
        all_count += domain.entries;
        zero_count += zeros.entries;
        nonzero_count += nonzeros.entries;
    }
    if (all.entries != all_count or zero.entries != zero_count or
        nonzero.entries != nonzero_count)
        return error.InvalidDomainCounts;
}

fn writeStream(writer: anytype, key: []const u8, name: []const u8, evidence: anytype) !void {
    try writeRawStream(
        writer,
        key,
        name,
        evidence.all,
        evidence.zero,
        evidence.nonzero,
    );
}

fn writeRawStream(
    writer: anytype,
    key: []const u8,
    name: []const u8,
    all: relation_export.StreamDigest,
    zero: relation_export.StreamDigest,
    nonzero: relation_export.StreamDigest,
) !void {
    try writer.print("{s}={s} entries={d} digest=", .{ key, name, all.entries });
    try writeDigest(writer, all.digest);
    try writer.print(" zero_entries={d} zero_digest=", .{zero.entries});
    try writeDigest(writer, zero.digest);
    try writer.print(" nonzero_entries={d} nonzero_digest=", .{nonzero.entries});
    try writeDigest(writer, nonzero.digest);
    try writer.writeByte('\n');
}

fn writeDigest(writer: anytype, digest: relation_export.Digest) !void {
    const encoded = std.fmt.bytesToHex(digest, .lower);
    try writer.writeAll(&encoded);
}

fn writeQm31(writer: anytype, value: QM31) !void {
    const limbs = value.toM31Array();
    try writer.print("{d},{d},{d},{d}", .{
        limbs[0].toU32(), limbs[1].toU32(), limbs[2].toU32(), limbs[3].toU32(),
    });
}

fn relationSignature(
    domain: relation_export.Domain,
    relations: *const relations_mod.Relations,
) entry.Error!QM31 {
    const arity = entry.expectedArity(domain);
    var relation_entry = entry.Entry{
        .domain = domain,
        .numerator = QM31.zero(),
        .arity = arity,
    };
    for (relation_entry.values[0..arity], 0..) |*value, index| {
        value.* = QM31.fromBase(M31.fromU64(index + 1));
    }
    return relation_entry.denominator(relations);
}

fn emptyBundle() !Bundle {
    const transcript_claims = @import("transcript/claims.zig");
    const native = transcript_claims.InteractionClaim.init(
        .{QM31.zero()} ** relation_export.COMPONENT_COUNT,
        &.{},
    );
    var ledger = try relation_export.ClaimLedger.init(.{1} ** 32, .{2} ** 32, &native);
    var sequence = relation_export.Sequence.init();
    var components: [relation_export.COMPONENT_COUNT]relation_export.ComponentEvidence = undefined;
    for (&components, 0..) |*component, index| {
        component.* = try relation_export.exportAbsentComponent(
            @enumFromInt(index),
            &ledger,
            &sequence,
        );
    }
    return .{
        .witness_layout_digest = witness_layout.digest(),
        .components = components,
        .aggregate = try sequence.finish(),
        .claims = try ledger.finish(),
        .public = .{
            .domains = .{QM31.zero()} ** relation_export.DOMAIN_COUNT,
            .total = QM31.zero(),
        },
    };
}

test "relation evidence serializes one complete canonical registry" {
    const allocator = std.testing.allocator;
    var bundle = try emptyBundle();
    try bundle.validate();
    bundle.witness_layout_digest[0] ^= 1;
    try std.testing.expectError(error.InvalidWitnessLayout, bundle.validate());
    bundle.witness_layout_digest[0] ^= 1;

    var tuples: std.ArrayList(u8) = .{};
    defer tuples.deinit(allocator);
    try writeTuples(tuples.writer(allocator), &bundle);
    try std.testing.expect(std.mem.startsWith(
        u8,
        tuples.items,
        "schema=riscv-relation-tuples-v2\ncomponent=auipc ",
    ));
    try std.testing.expectEqual(@as(usize, 365), std.mem.count(u8, tuples.items, "\n"));

    var sums: std.ArrayList(u8) = .{};
    defer sums.deinit(allocator);
    try writeSums(sums.writer(allocator), &bundle, &relations_mod.Relations.dummy());
    try std.testing.expect(std.mem.startsWith(
        u8,
        sums.items,
        "schema=riscv-relation-sums-v1\nchallenge=registers_state ",
    ));
    try std.testing.expectEqual(@as(usize, 56), std.mem.count(u8, sums.items, "\n"));

    bundle.claims.claims[0] = QM31.one();
    try std.testing.expectError(error.ComponentClaimMismatch, bundle.validate());
}
