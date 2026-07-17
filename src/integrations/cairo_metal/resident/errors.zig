//! Stable error contract for Cairo resident Metal integration.

pub const Error = error{
    InvalidSchedule,
    DuplicateBinding,
    MissingBinding,
    InvalidCardinality,
    InvalidCompositionCount,
    InvalidQuotientCount,
    InvalidFriChallengeCount,
    InvalidFriRetainedCount,
    InvalidFriLayerCount,
    InvalidExtParamCount,
    InvalidClaimedSumCount,
    InvalidPreprocessedCount,
    InvalidBindingSize,
    InvalidBindingAlias,
    TranscriptBootstrapStatementMismatch,
    TranscriptBootstrapCommitmentMismatch,
};
