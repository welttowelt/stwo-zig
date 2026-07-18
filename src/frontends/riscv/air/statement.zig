//! Public RISC-V proof shape and transcript claims.

const qm31 = @import("../../../core/fields/qm31.zig");
const component = @import("component.zig");
const public_data = @import("public_data.zig");

const QM31 = qm31.QM31;
pub const FamilyComponentDesc = component.FamilyComponentDesc;
pub const PublicData = public_data.PublicData;

pub const MAX_COMPONENTS: usize = 256;
pub const MAX_INFRA_COMPONENTS: usize = 512;

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
    return if (kind == .program) component.nInteractionCols(.program) else 0;
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

    pub fn mixShape(self: RiscVStatement, channel: anytype) void {
        channel.mixU32s(&.{
            self.n_components,
            self.initial_pc,
            self.final_pc,
            self.total_steps,
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

pub const RiscVInteractionClaim = struct {
    state_claims: [MAX_COMPONENTS]QM31,
    prog_claims: [MAX_COMPONENTS]QM31,
    rom_claim: QM31,
    n_components: u32,

    pub fn initZero() RiscVInteractionClaim {
        return .{
            .state_claims = .{QM31.zero()} ** MAX_COMPONENTS,
            .prog_claims = .{QM31.zero()} ** MAX_COMPONENTS,
            .rom_claim = QM31.zero(),
            .n_components = 0,
        };
    }

    pub fn mixInto(self: RiscVInteractionClaim, channel: anytype) void {
        channel.mixU32s(&.{ 0x5354_4154, self.n_components }); // "STAT"
        for (0..self.n_components) |i| channel.mixFelts(&.{self.state_claims[i]});
        channel.mixU32s(&.{ 0x5052_4F47, self.n_components }); // "PROG"
        for (0..self.n_components) |i| channel.mixFelts(&.{self.prog_claims[i]});
        channel.mixFelts(&.{self.rom_claim});
    }
};
