//! FRI protocol configuration and degree-bound transitions.

/// FRI proof configuration.
pub const FriConfig = struct {
    log_blowup_factor: u32,
    log_last_layer_degree_bound: u32,
    n_queries: usize,
    fold_step: u32 = 1, // number of folds per FRI round (stark-v uses 4)

    pub const Error = error{
        InvalidLastLayerDegreeBound,
        InvalidBlowupFactor,
    };

    pub const LOG_MIN_LAST_LAYER_DEGREE_BOUND: u32 = 0;
    pub const LOG_MAX_LAST_LAYER_DEGREE_BOUND: u32 = 10;
    pub const LOG_MIN_BLOWUP_FACTOR: u32 = 1;
    pub const LOG_MAX_BLOWUP_FACTOR: u32 = 16;

    pub fn init(
        log_last_layer_degree_bound: u32,
        log_blowup_factor: u32,
        n_queries: usize,
    ) Error!FriConfig {
        if (log_last_layer_degree_bound < LOG_MIN_LAST_LAYER_DEGREE_BOUND or
            log_last_layer_degree_bound > LOG_MAX_LAST_LAYER_DEGREE_BOUND)
        {
            return Error.InvalidLastLayerDegreeBound;
        }
        if (log_blowup_factor < LOG_MIN_BLOWUP_FACTOR or
            log_blowup_factor > LOG_MAX_BLOWUP_FACTOR)
        {
            return Error.InvalidBlowupFactor;
        }
        return .{
            .log_blowup_factor = log_blowup_factor,
            .log_last_layer_degree_bound = log_last_layer_degree_bound,
            .n_queries = n_queries,
        };
    }

    pub inline fn lastLayerDomainSize(self: FriConfig) usize {
        return @as(usize, 1) << @intCast(self.log_last_layer_degree_bound + self.log_blowup_factor);
    }

    pub inline fn securityBits(self: FriConfig) u32 {
        return self.log_blowup_factor * @as(u32, @intCast(self.n_queries));
    }

    pub fn default() FriConfig {
        return FriConfig.init(0, 1, 3) catch unreachable;
    }
};

/// Upstream Stwo folds one level per FRI layer. Alternative schedules must be
/// selected explicitly through `FriConfig.fold_step` and remain protocol-bound.
pub const FOLD_STEP: u32 = 1;

/// Number of folds when reducing circle to line polynomial.
pub const CIRCLE_TO_LINE_FOLD_STEP: u32 = 1;

/// STWO packs four consecutive QM31 evaluations into each FRI Merkle leaf
/// whenever a layer folds more than one level.
pub const LOG_PACKED_LEAF_SIZE: u32 = 2;

pub const FriVerificationError = error{
    InvalidNumFriLayers,
    FirstLayerEvaluationsInvalid,
    FirstLayerCommitmentInvalid,
    InnerLayerCommitmentInvalid,
    InnerLayerEvaluationsInvalid,
    LastLayerDegreeInvalid,
    LastLayerEvaluationsInvalid,
};

pub const CirclePolyDegreeBound = struct {
    log_degree_bound: u32,

    pub inline fn init(log_degree_bound: u32) CirclePolyDegreeBound {
        return .{ .log_degree_bound = log_degree_bound };
    }

    pub inline fn logDegreeBound(self: CirclePolyDegreeBound) u32 {
        return self.log_degree_bound;
    }

    pub inline fn foldToLine(self: CirclePolyDegreeBound) LinePolyDegreeBound {
        return self.foldToLineWithStep(CIRCLE_TO_LINE_FOLD_STEP);
    }

    pub inline fn foldToLineWithStep(self: CirclePolyDegreeBound, fold_step: u32) LinePolyDegreeBound {
        return .{ .log_degree_bound = self.log_degree_bound - fold_step };
    }
};

pub const LinePolyDegreeBound = struct {
    log_degree_bound: u32,

    pub inline fn logDegreeBound(self: LinePolyDegreeBound) u32 {
        return self.log_degree_bound;
    }

    pub fn fold(self: LinePolyDegreeBound, n_folds: u32) ?LinePolyDegreeBound {
        if (self.log_degree_bound < n_folds) return null;
        return .{ .log_degree_bound = self.log_degree_bound - n_folds };
    }
};
