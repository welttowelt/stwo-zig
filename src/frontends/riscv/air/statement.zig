//! Public RISC-V proof shape and transcript claims.

const qm31 = @import("../../../core/fields/qm31.zig");
const component = @import("component.zig");
const public_data = @import("public_data.zig");
const trace_mod = @import("../runner/trace.zig");
const transcript_claims = @import("transcript/claims.zig");

const QM31 = qm31.QM31;
pub const FamilyComponentDesc = component.FamilyComponentDesc;
pub const PublicData = public_data.PublicData;

pub const MAX_COMPONENTS: usize = 256;
pub const MAX_INFRA_COMPONENTS: usize = 512;
pub const MAX_INTERACTION_COLUMNS: usize =
    (MAX_COMPONENTS + MAX_INFRA_COMPONENTS) * 16;

pub const InfraKind = enum(u32) {
    program,
    memory,
    clock_update,
    poseidon2,
    merkle,
    bitwise,
    range_check_20,
    range_check_8_11,
    range_check_8_8_4,
    range_check_8_8,
    range_check_m31,
};

pub const InfraComponentDesc = struct {
    kind: InfraKind,
    log_size: u32,
    n_rows: u32,
    n_columns: u32,
};

pub fn nInteractionColsForInfra(kind: InfraKind) u32 {
    return switch (kind) {
        .program => component.nInteractionCols(.program),
        .memory => component.nInteractionCols(.memory),
        else => 0,
    };
}

pub const RiscVStatement = struct {
    n_components: u32,
    component_descs: [MAX_COMPONENTS]FamilyComponentDesc,
    initial_pc: u32,
    final_pc: u32,
    total_steps: u32,
    public_data: PublicData,
    n_infra: u32 = 0,
    infra_descs: [MAX_INFRA_COMPONENTS]InfraComponentDesc = undefined,

    pub fn nPreprocessedColumns(self: *const RiscVStatement) u32 {
        return 2 * (self.n_components + self.n_infra);
    }

    pub fn nOpcodeMainColumns(self: *const RiscVStatement) u32 {
        var total: u32 = 0;
        for (0..self.n_components) |i| total += self.component_descs[i].n_columns;
        return total;
    }

    pub fn nInfraColumns(self: *const RiscVStatement) u32 {
        var total: u32 = 0;
        for (0..self.n_infra) |i| total += self.infra_descs[i].n_columns;
        return total;
    }

    pub fn nMainColumns(self: *const RiscVStatement) u32 {
        return self.nOpcodeMainColumns() + self.nInfraColumns();
    }

    pub fn nInteractionColumns(self: *const RiscVStatement) u32 {
        var total: u32 = self.n_components * component.nInteractionCols(.opcode);
        for (0..self.n_infra) |i| total += nInteractionColsForInfra(self.infra_descs[i].kind);
        return total;
    }

    pub fn nPreprocessedCells(self: *const RiscVStatement) u64 {
        var total: u64 = 0;
        for (0..self.n_components) |i| {
            total += @as(u64, 2) << @intCast(self.component_descs[i].log_size);
        }
        for (0..self.n_infra) |i| {
            total += @as(u64, 2) << @intCast(self.infra_descs[i].log_size);
        }
        return total;
    }

    pub fn nMainCells(self: *const RiscVStatement) u64 {
        var total: u64 = 0;
        for (0..self.n_components) |i| {
            total += @as(u64, self.component_descs[i].n_columns) <<
                @intCast(self.component_descs[i].log_size);
        }
        for (0..self.n_infra) |i| {
            total += @as(u64, self.infra_descs[i].n_columns) <<
                @intCast(self.infra_descs[i].log_size);
        }
        return total;
    }

    pub fn nInteractionCells(self: *const RiscVStatement) u64 {
        var total: u64 = 0;
        for (0..self.n_components) |i| {
            total += @as(u64, component.nInteractionCols(.opcode)) <<
                @intCast(self.component_descs[i].log_size);
        }
        for (0..self.n_infra) |i| {
            total += @as(u64, nInteractionColsForInfra(self.infra_descs[i].kind)) <<
                @intCast(self.infra_descs[i].log_size);
        }
        return total;
    }

    pub fn canonicalMainClaim(self: *const RiscVStatement) transcript_claims.MainClaim {
        var log_sizes = [_]u32{0} ** transcript_claims.COMPONENT_COUNT;
        for (0..self.n_components) |i| {
            const desc = self.component_descs[i];
            const index = @intFromEnum(componentForFamily(desc.family));
            log_sizes[index] = @max(log_sizes[index], desc.log_size);
        }
        for (0..self.n_infra) |i| {
            const desc = self.infra_descs[i];
            const index = @intFromEnum(componentForInfra(desc.kind));
            log_sizes[index] = @max(log_sizes[index], desc.log_size);
        }
        return transcript_claims.MainClaim.init(log_sizes);
    }

    /// Domain-separated extension to Stark-V's canonical 27-component claim.
    /// Upstream has one table per family; Zig shards large tables and must bind
    /// the complete shard geometry before drawing relation challenges.
    pub fn mixShardManifest(self: RiscVStatement, channel: anytype) void {
        channel.mixU32s(&.{
            0x5348_5244, // "SHRD"
            self.n_components,
            self.n_infra,
        });
        for (0..self.n_components) |i| {
            const desc = self.component_descs[i];
            channel.mixU32s(&.{
                @intFromEnum(desc.family),
                desc.log_size,
                desc.n_rows,
                desc.n_columns,
            });
        }
        for (0..self.n_infra) |i| {
            const desc = self.infra_descs[i];
            channel.mixU32s(&.{
                @intFromEnum(desc.kind),
                desc.log_size,
                desc.n_rows,
                desc.n_columns,
            });
        }
    }
};

pub const CanonicalInteractionClaim = struct {
    claimed_sums: [transcript_claims.COMPONENT_COUNT]QM31,
    log_sizes: [MAX_INTERACTION_COLUMNS]u32,
    n_log_sizes: usize,

    pub fn view(self: *const CanonicalInteractionClaim) transcript_claims.InteractionClaim {
        return transcript_claims.InteractionClaim.init(
            self.claimed_sums,
            self.log_sizes[0..self.n_log_sizes],
        );
    }
};

pub const RiscVInteractionClaim = struct {
    state_claims: [MAX_COMPONENTS]QM31,
    prog_claims: [MAX_COMPONENTS]QM31,
    rom_claim: QM31,
    memory_claims: [MAX_INFRA_COMPONENTS][4]QM31,
    n_components: u32,
    interaction_pow: u64,

    pub fn initZero() RiscVInteractionClaim {
        return .{
            .state_claims = .{QM31.zero()} ** MAX_COMPONENTS,
            .prog_claims = .{QM31.zero()} ** MAX_COMPONENTS,
            .rom_claim = QM31.zero(),
            .memory_claims = .{.{QM31.zero()} ** 4} ** MAX_INFRA_COMPONENTS,
            .n_components = 0,
            .interaction_pow = 0,
        };
    }

    pub fn canonical(
        self: *const RiscVInteractionClaim,
        statement: *const RiscVStatement,
    ) !CanonicalInteractionClaim {
        if (self.n_components != statement.n_components) return error.InvalidInteractionClaim;
        var result = CanonicalInteractionClaim{
            .claimed_sums = .{QM31.zero()} ** transcript_claims.COMPONENT_COUNT,
            .log_sizes = undefined,
            .n_log_sizes = 0,
        };
        for (0..statement.n_components) |i| {
            const desc = statement.component_descs[i];
            const claim_index = @intFromEnum(componentForFamily(desc.family));
            result.claimed_sums[claim_index] = result.claimed_sums[claim_index]
                .add(self.state_claims[i]).add(self.prog_claims[i]);
            for (0..component.nInteractionCols(.opcode)) |_| {
                if (result.n_log_sizes == result.log_sizes.len) return error.TooManyInteractionColumns;
                result.log_sizes[result.n_log_sizes] = desc.log_size;
                result.n_log_sizes += 1;
            }
        }
        for (0..statement.n_infra) |i| {
            const desc = statement.infra_descs[i];
            if (desc.kind == .program) {
                const claim_index = @intFromEnum(transcript_claims.Component.program);
                result.claimed_sums[claim_index] = result.claimed_sums[claim_index].add(self.rom_claim);
            }
            if (desc.kind == .memory) {
                const claim_index = @intFromEnum(transcript_claims.Component.memory);
                for (self.memory_claims[i]) |sum| {
                    result.claimed_sums[claim_index] = result.claimed_sums[claim_index].add(sum);
                }
            }
            for (0..nInteractionColsForInfra(desc.kind)) |_| {
                if (result.n_log_sizes == result.log_sizes.len) return error.TooManyInteractionColumns;
                result.log_sizes[result.n_log_sizes] = desc.log_size;
                result.n_log_sizes += 1;
            }
        }
        return result;
    }
};

fn componentForFamily(family: trace_mod.OpcodeFamily) transcript_claims.Component {
    return switch (family) {
        .auipc => .auipc,
        .base_alu_imm => .base_alu_imm,
        .base_alu_reg => .base_alu_reg,
        .branch_eq => .branch_eq,
        .branch_lt => .branch_lt,
        .div => .div,
        .jal => .jal,
        .jalr => .jalr,
        .load_store => .load_store,
        .lt_imm => .lt_imm,
        .lt_reg => .lt_reg,
        .lui => .lui,
        .mul => .mul,
        .mulh => .mulh,
        .shifts_imm => .shifts_imm,
        .shifts_reg => .shifts_reg,
    };
}

fn componentForInfra(kind: InfraKind) transcript_claims.Component {
    return switch (kind) {
        .program => .program,
        .memory => .memory,
        .merkle => .merkle,
        .poseidon2 => .poseidon2,
        .clock_update => .clock_update,
        .bitwise => .bitwise,
        .range_check_20 => .range_check_20,
        .range_check_8_11 => .range_check_8_11,
        .range_check_8_8_4 => .range_check_8_8_4,
        .range_check_8_8 => .range_check_8_8,
        .range_check_m31 => .range_check_m31,
    };
}
