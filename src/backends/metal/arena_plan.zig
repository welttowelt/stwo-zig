//! Compatibility surface joining the neutral arena plan with Metal storage.

const plan = @import("stwo_backend_contracts").arena_plan;
const resident = @import("resident_arena.zig");

pub const max_ticks = plan.max_ticks;
pub const Materialization = plan.Materialization;
pub const LiveRange = plan.LiveRange;
pub const LogicalBuffer = plan.LogicalBuffer;
pub const Binding = plan.Binding;
pub const Slot = plan.Slot;
pub const ActionKind = plan.ActionKind;
pub const Action = plan.Action;
pub const Error = plan.Error;
pub const Plan = plan.Plan;
pub const build = plan.build;
pub const bytesThroughTick = plan.bytesThroughTick;
pub const projectThroughTick = plan.projectThroughTick;
pub const peakLogicalBytes = plan.peakLogicalBytes;
pub const RecoveryHooks = plan.RecoveryHooks;
pub const EpochRunner = plan.EpochRunner;

pub const narrow_word_address_space_bytes = resident.narrow_word_address_space_bytes;
pub const validateNarrowWordBinding = resident.validateNarrowWordBinding;
pub const narrowWordOffset = resident.narrowWordOffset;
pub const ResidentArena = resident.ResidentArena;
