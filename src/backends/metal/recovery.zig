//! Compatibility export for the backend-neutral recovery contract.

const recovery = @import("../../backend/recovery.zig");

pub const RecoveryError = recovery.RecoveryError;
pub const BufferAccess = recovery.BufferAccess;
pub const FileSpillStore = recovery.FileSpillStore;
pub const Recipe = recovery.Recipe;
pub const RecipeRegistry = recovery.RecipeRegistry;
pub const GroupRecipe = recovery.GroupRecipe;
pub const RecoveryEngine = recovery.RecoveryEngine;
