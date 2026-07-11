#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

@interface StwoZigMetalRuntime : NSObject
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) id<MTLComputePipelineState> leaves;
@property(nonatomic, strong) id<MTLComputePipelineState> parents;
@property(nonatomic, strong) id<MTLComputePipelineState> quotients;
@property(nonatomic, strong) id<MTLComputePipelineState> rawQuotients;
@property(nonatomic, strong) id<MTLComputePipelineState> polynomialEval;
@property(nonatomic, strong) id<MTLComputePipelineState> polynomialBasis;
@property(nonatomic, strong) id<MTLComputePipelineState> circleIfftFirst;
@property(nonatomic, strong) id<MTLComputePipelineState> circleIfftLayer;
@property(nonatomic, strong) id<MTLComputePipelineState> circleRfftLayer;
@property(nonatomic, strong) id<MTLComputePipelineState> circleRfftLast;
@property(nonatomic, strong) id<MTLComputePipelineState> circleRescale;
@property(nonatomic, strong) id<MTLComputePipelineState> circleExpand;
@property(nonatomic, strong) id<MTLComputePipelineState> circleIfftFused;
@property(nonatomic, strong) id<MTLComputePipelineState> circleRfftFused;
@property(nonatomic, strong) id<MTLComputePipelineState> quotientNumerator;
@property(nonatomic, strong) id<MTLComputePipelineState> quotientFinalize;
@property(nonatomic, strong) id<MTLComputePipelineState> quotientDomainPointsResident;
@property(nonatomic, strong) id<MTLComputePipelineState> quotientDenominatorsResident;
@property(nonatomic, strong) id<MTLComputePipelineState> quotientCombineResident;
@property(nonatomic, strong) id<MTLComputePipelineState> friFoldCircle;
@property(nonatomic, strong) id<MTLComputePipelineState> friFoldLine;
@property(nonatomic, strong) id<MTLComputePipelineState> friFold3Resident;
@property(nonatomic, strong) id<MTLComputePipelineState> friFold2Resident;
@property(nonatomic, strong) id<MTLComputePipelineState> friPackedLeavesResident;
@property(nonatomic, strong) id<MTLComputePipelineState> friFinalLineResident;
@property(nonatomic, strong) id<MTLComputePipelineState> transcriptInitResident;
@property(nonatomic, strong) id<MTLComputePipelineState> transcriptMixResident;
@property(nonatomic, strong) id<MTLComputePipelineState> transcriptDrawSecureResident;
@property(nonatomic, strong) id<MTLComputePipelineState> transcriptDrawQueriesResident;
@property(nonatomic, strong) id<MTLComputePipelineState> decommitNormalizeQueriesResident;
@property(nonatomic, strong) id<MTLComputePipelineState> decommitPrepareFriQueriesResident;
@property(nonatomic, strong) id<MTLComputePipelineState> decommitGatherFriValuesResident;
@property(nonatomic, strong) id<MTLComputePipelineState> decommitPrepareTraceQueriesResident;
@property(nonatomic, strong) id<MTLComputePipelineState> decommitGatherTraceValuesResident;
@property(nonatomic, strong) id<MTLComputePipelineState> decommitAssembleFriResident;
@property(nonatomic, strong) id<MTLComputePipelineState> decommitSparseParentResident;
@property(nonatomic, strong) id<MTLComputePipelineState> decommitSparseLeavesResident;
@property(nonatomic, strong) id<MTLComputePipelineState> decommitAssembleTraceResident;
@property(nonatomic, strong) id<MTLComputePipelineState> qm31ToCoordinates;
@property(nonatomic, strong) id<MTLComputePipelineState> witnessFeedCounts;
@property(nonatomic, strong) id<MTLComputePipelineState> witnessInputGatherResident;
@property(nonatomic, strong) id<MTLComputePipelineState> executionTableSplitResident;
@property(nonatomic, strong) id<MTLComputePipelineState> clearArenaRanges;
@property(nonatomic, strong) id<MTLComputePipelineState> clearArenaSpans;
@property(nonatomic, strong) id<MTLComputePipelineState> circleExpandSparse;
@property(nonatomic, strong) id<MTLComputePipelineState> circleCopySparse;
@property(nonatomic, strong) id<MTLComputePipelineState> circleIfftFirstSparse;
@property(nonatomic, strong) id<MTLComputePipelineState> circleIfftLayerSparse;
@property(nonatomic, strong) id<MTLComputePipelineState> circleRescaleSparse;
@property(nonatomic, strong) id<MTLComputePipelineState> circleRfftLayerSparse;
@property(nonatomic, strong) id<MTLComputePipelineState> circleRfftLastSparse;
@property(nonatomic, strong) id<MTLComputePipelineState> relationFused;
@property(nonatomic, strong) id<MTLComputePipelineState> relationBlockScan;
@property(nonatomic, strong) id<MTLComputePipelineState> relationScanBlocks;
@property(nonatomic, strong) id<MTLComputePipelineState> relationScanFinalize;
@property(nonatomic, strong) id<MTLComputePipelineState> fixedTableLookup;
@property(nonatomic, strong) id<MTLComputePipelineState> parentsSparse;
@property(nonatomic, strong) id<MTLComputePipelineState> felt252Oracle;
@property(nonatomic, strong) id<MTLComputePipelineState> ecOpWitness;
@property(nonatomic, strong) id<MTLComputePipelineState> compactGather;
@property(nonatomic, strong) id<MTLComputePipelineState> compactRadixHistogram;
@property(nonatomic, strong) id<MTLComputePipelineState> compactRadixPrefix;
@property(nonatomic, strong) id<MTLComputePipelineState> compactRadixScatter;
@property(nonatomic, strong) id<MTLComputePipelineState> compactHeads;
@property(nonatomic, strong) id<MTLComputePipelineState> compactScanLocal;
@property(nonatomic, strong) id<MTLComputePipelineState> compactScanBlocks;
@property(nonatomic, strong) id<MTLComputePipelineState> compactScanAdd;
@property(nonatomic, strong) id<MTLComputePipelineState> compactClearOutputs;
@property(nonatomic, strong) id<MTLComputePipelineState> compactScatter;
@property(nonatomic, strong) id<MTLComputePipelineState> compactFinalize;
@property(nonatomic, strong) id<MTLComputePipelineState> compositionLift;
@property(nonatomic, strong) id<MTLComputePipelineState> compositionSplit;
@property(nonatomic, strong) id<MTLComputePipelineState> compositionExpand;
@property(nonatomic, strong) id<MTLComputePipelineState> compositionRandomPowers;
@property(nonatomic, strong) id<MTLComputePipelineState> compositionExtParams;
@end

@interface StwoZigWitnessFeedPlan : NSObject
@property(nonatomic, strong) id<MTLBuffer> descriptors;
@property(nonatomic, strong) id<MTLBuffer> luts;
@property(nonatomic, strong) id<MTLBuffer> destinationOffsets;
@property(nonatomic, strong) id<MTLBuffer> sourceOffsets;
@property(nonatomic, strong) id<MTLBuffer> clearRanges;
@property(nonatomic) uint32_t descriptorCount;
@property(nonatomic) uint32_t clearRangeCount;
@property(nonatomic) uint32_t clearTotalWords;
@end

@implementation StwoZigWitnessFeedPlan
@end

@interface StwoZigWitnessFeedBatch : NSObject
@property(nonatomic, strong) NSArray<StwoZigWitnessFeedPlan *> *plans;
@property(nonatomic, strong) NSData *columnLengths;
@property(nonatomic, strong) id<MTLBuffer> clearSpans;
@property(nonatomic) uint32_t clearRangeCount;
@property(nonatomic) uint32_t clearTotalWords;
@end

@implementation StwoZigWitnessFeedBatch
@end

@interface StwoZigCircleLdePlan : NSObject
@property(nonatomic, strong) id<MTLBuffer> sourceOffsets;
@property(nonatomic, strong) id<MTLBuffer> destinationOffsets;
@property(nonatomic) uint32_t columnCount;
@property(nonatomic) uint32_t baseLogSize;
@property(nonatomic) uint32_t extendedLogSize;
@property(nonatomic) NSUInteger twiddleByteOffset;
@end

@implementation StwoZigCircleLdePlan
@end

@interface StwoZigCircleIfftPlan : NSObject
@property(nonatomic, strong) id<MTLBuffer> sourceOffsets;
@property(nonatomic, strong) id<MTLBuffer> destinationOffsets;
@property(nonatomic) uint32_t columnCount;
@property(nonatomic) uint32_t logSize;
@property(nonatomic) uint32_t scaleFactor;
@property(nonatomic) NSUInteger twiddleByteOffset;
@end

@implementation StwoZigCircleIfftPlan
@end

@interface StwoZigRelationPlan : NSObject
@property(nonatomic, strong) id<MTLBuffer> geometry;
@property(nonatomic, strong) id<MTLBuffer> sourceOffsets;
@property(nonatomic, strong) id<MTLBuffer> descriptors;
@property(nonatomic, strong) id<MTLBuffer> outputOffsets;
@property(nonatomic) uint32_t instanceCount;
@property(nonatomic) uint32_t totalBlocks;
@property(nonatomic) NSUInteger alphaByteOffset;
@property(nonatomic) NSUInteger zByteOffset;
@property(nonatomic) NSUInteger scratchByteOffset;
@end

@implementation StwoZigRelationPlan
@end

@interface StwoZigFixedTablePlan : NSObject
@property(nonatomic, strong) id<MTLBuffer> descriptors;
@property(nonatomic, strong) id<MTLBuffer> sourceOffsets;
@property(nonatomic, strong) id<MTLBuffer> multiplicityOffsets;
@property(nonatomic) uint32_t destinationOffset;
@property(nonatomic) uint32_t rowCount;
@property(nonatomic) uint32_t outputCount;
@end
@implementation StwoZigFixedTablePlan
@end

@interface StwoZigFixedTableBatch : NSObject
@property(nonatomic, strong) NSArray<StwoZigFixedTablePlan *> *plans;
@end
@implementation StwoZigFixedTableBatch
@end

@interface StwoZigMerkleParentChain : NSObject
@property(nonatomic, strong) NSData *childOffsets;
@property(nonatomic, strong) NSData *destinationOffsets;
@property(nonatomic, strong) NSData *parentCounts;
@property(nonatomic, strong) id<MTLBuffer> nodeSeed;
@property(nonatomic) uint32_t levelCount;
@end
@implementation StwoZigMerkleParentChain
@end

@interface StwoZigEcOpPlan : NSObject
@property(nonatomic, strong) id<MTLBuffer> executionOffsets;
@property(nonatomic, strong) id<MTLBuffer> traceOffsets;
@property(nonatomic, strong) id<MTLBuffer> partialOffsets;
@property(nonatomic, strong) id<MTLBuffer> multiplicityOffsets;
@property(nonatomic, strong) id<MTLBuffer> params;
@property(nonatomic) uint32_t rowCount;
@end
@implementation StwoZigEcOpPlan
@end

@interface StwoZigCompactPlan : NSObject
@property(nonatomic, strong) id<MTLBuffer> sourceOffsets;
@property(nonatomic, strong) id<MTLBuffer> descriptors;
@property(nonatomic, strong) id<MTLBuffer> outputOffsets;
@property(nonatomic, strong) id<MTLBuffer> params;
@property(nonatomic) uint32_t sortRows;
@property(nonatomic) uint32_t totalRows;
@property(nonatomic) uint32_t consumerRows;
@property(nonatomic) uint32_t keyWords;
@property(nonatomic) uint32_t indicesA;
@property(nonatomic) uint32_t indicesB;
@end
@implementation StwoZigCompactPlan
@end

@interface StwoZigEvalPlan : NSObject
@property(nonatomic, strong) id<MTLComputePipelineState> pipeline;
@property(nonatomic, strong) id<MTLBuffer> arguments;
@property(nonatomic) uint32_t rowCount;
@end
@implementation StwoZigEvalPlan
@end

@interface StwoZigWitnessPlan : NSObject
@property(nonatomic, strong) id<MTLComputePipelineState> pipeline;
@property(nonatomic, strong) id<MTLBuffer> arguments;
@property(nonatomic) uint32_t rowCount;
@end
@implementation StwoZigWitnessPlan
@end

@interface StwoZigEvalBatch : NSObject
@property(nonatomic, strong) NSArray<StwoZigEvalPlan *> *plans;
@end
@implementation StwoZigEvalBatch
@end

@interface StwoZigEvalLibrary : NSObject
@property(nonatomic, strong) id<MTLLibrary> library;
@property(nonatomic, strong) id<MTLBinaryArchive> archive;
@property(nonatomic, strong) NSURL *archiveURL;
@end
@implementation StwoZigEvalLibrary
@end

@interface StwoZigCompositionFinalizePlan : NSObject
@property(nonatomic, strong) NSData *accumulatorOffsets;
@property(nonatomic, strong) NSData *accumulatorLogs;
@property(nonatomic, strong) id<MTLBuffer> coordinateOffsets;
@property(nonatomic, strong) id<MTLBuffer> outputOffsets;
@property(nonatomic) uint32_t accumulatorCount;
@property(nonatomic) NSUInteger inverseTwiddleByteOffset;
@end
@implementation StwoZigCompositionFinalizePlan
@end

@interface StwoZigCompositionLdePlan : NSObject
@property(nonatomic, strong) id<MTLBuffer> sourceOffsets;
@property(nonatomic, strong) id<MTLBuffer> sourceLogs;
@property(nonatomic, strong) id<MTLBuffer> destinationOffsets;
@property(nonatomic) uint32_t columnCount;
@property(nonatomic) uint32_t extendedLog;
@property(nonatomic) NSUInteger twiddleByteOffset;
@end
@implementation StwoZigCompositionLdePlan
@end

@interface StwoZigCompositionInputPlan : NSObject
@property(nonatomic, strong) id<MTLBuffer> descriptors;
@property(nonatomic) uint32_t descriptorCount;
@property(nonatomic) uint32_t randomOffset;
@property(nonatomic) uint32_t powersOffset;
@property(nonatomic) uint32_t powerCount;
@end
@implementation StwoZigCompositionInputPlan
@end

@interface StwoZigCompositionFrontPlan : NSObject
@property(nonatomic, strong) StwoZigCompositionInputPlan *inputs;
@property(nonatomic, strong) NSArray<StwoZigCompositionLdePlan *> *ldePlans;
@property(nonatomic, strong) NSArray<StwoZigEvalBatch *> *evalBatches;
@property(nonatomic) uint32_t accumulatorOffset;
@property(nonatomic) uint32_t accumulatorWords;
@end
@implementation StwoZigCompositionFrontPlan
@end

@interface StwoZigFriFoldPlan : NSObject
@property(nonatomic) NSUInteger sourceByteOffset;
@property(nonatomic) NSUInteger inverseByteOffset;
@property(nonatomic) NSUInteger alphaByteOffset;
@property(nonatomic) NSUInteger destinationByteOffset;
@property(nonatomic) uint32_t sourceCount;
@property(nonatomic) bool circle;
@end
@implementation StwoZigFriFoldPlan
@end

@interface StwoZigArenaCopyPlan : NSObject
@property(nonatomic, strong) NSData *ranges;
@property(nonatomic) uint32_t rangeCount;
@end
@implementation StwoZigArenaCopyPlan
@end

@interface StwoZigQuotientCombinePlan : NSObject
@property(nonatomic, strong) id<MTLBuffer> partialOffsets;
@property(nonatomic, strong) id<MTLBuffer> partialLogs;
@property(nonatomic) uint32_t sampleOffset;
@property(nonatomic) uint32_t linearOffset;
@property(nonatomic) uint32_t scratchOffset;
@property(nonatomic) uint32_t outputOffset;
@property(nonatomic) uint32_t rowCount;
@property(nonatomic) uint32_t logSize;
@property(nonatomic) uint32_t sampleCount;
@property(nonatomic) uint32_t initialIndex;
@property(nonatomic) uint32_t stepSize;
@end
@implementation StwoZigQuotientCombinePlan
@end

@interface StwoZigFriRoundPlan : NSObject
@property(nonatomic) uint32_t twiddleBase, twiddleOffset0, twiddleOffset1, twiddleOffset2;
@property(nonatomic) uint32_t inputBase, inputStride, alphaBase, outputBase, outputStride;
@property(nonatomic) uint32_t n, foldCount, firstCircle;
@end
@implementation StwoZigFriRoundPlan
@end

@interface StwoZigFriTreePlan : NSObject
@property(nonatomic, strong) NSData *layerOffsets;
@property(nonatomic, strong) id<MTLBuffer> leafSeed;
@property(nonatomic, strong) id<MTLBuffer> nodeSeed;
@property(nonatomic) uint32_t evaluationBase, coordinateStride, evaluationSize, logRowsPerLeaf, layerCount;
@end
@implementation StwoZigFriTreePlan
@end

@interface StwoZigFriFinalPlan : NSObject
@property(nonatomic) uint32_t evaluationBase, coordinateStride, inverseX, coefficientBase, degreeError;
@end
@implementation StwoZigFriFinalPlan
@end

@interface StwoZigMerkleLeafPlan : NSObject
@property(nonatomic, strong) id<MTLBuffer> columnOffsets;
@property(nonatomic, strong) id<MTLBuffer> columnLogSizes;
@property(nonatomic, strong) id<MTLBuffer> leafSeed;
@property(nonatomic) uint32_t columnCount;
@property(nonatomic) uint32_t liftingLogSize;
@property(nonatomic) uint32_t destinationOffset;
@end
@implementation StwoZigMerkleLeafPlan
@end

@interface StwoZigResidentMerklePlan : NSObject
@property(nonatomic, strong) id<MTLBuffer> columnOffsets;
@property(nonatomic, strong) id<MTLBuffer> columnLogSizes;
@property(nonatomic, strong) NSData *layerOffsets;
@property(nonatomic, strong) id<MTLBuffer> leafSeed;
@property(nonatomic, strong) id<MTLBuffer> nodeSeed;
@property(nonatomic) uint32_t columnCount;
@property(nonatomic) uint32_t liftingLogSize;
@property(nonatomic) uint32_t layerCount;
@end
@implementation StwoZigResidentMerklePlan
@end
@implementation StwoZigMetalRuntime
@end

@interface StwoZigMetalTree : NSObject
@property(nonatomic, strong) NSArray<id<MTLBuffer>> *layers;
@property(nonatomic, strong) id<MTLBuffer> rootReadback;
@property(nonatomic, assign) uint32_t logSize;
@property(nonatomic, assign) double gpuMilliseconds;
@end
@implementation StwoZigMetalTree
@end

typedef struct {
    uint32_t offset, length, batch, shift, direct;
    uint32_t coeff_a, coeff_b, coeff_c, coeff_d;
} StwoZigRawQuotientView;
typedef struct {
    uint32_t coefficient_offset, coefficient_length, basis_offset, log_size, output_index;
} StwoZigPolynomialEvalTask;

static void write_error(char *destination, size_t length, NSString *message) {
    if (destination == NULL || length == 0) return;
    const char *utf8 = message.UTF8String ?: "Metal error";
    snprintf(destination, length, "%s", utf8);
}

static id<MTLComputePipelineState> make_pipeline(
    id<MTLDevice> device,
    id<MTLLibrary> library,
    NSString *name,
    char *error_message,
    size_t error_message_len
) {
    id<MTLFunction> function = [library newFunctionWithName:name];
    if (function == nil) {
        write_error(error_message, error_message_len,
                    [NSString stringWithFormat:@"Missing Metal function %@", name]);
        return nil;
    }
    NSError *error = nil;
    id<MTLComputePipelineState> pipeline =
        [device newComputePipelineStateWithFunction:function error:&error];
    if (pipeline == nil) {
        write_error(error_message, error_message_len,
                    error.localizedDescription ?: @"Failed to create Metal pipeline");
    }
    return pipeline;
}

static id<MTLBuffer> alias_shared_buffer(id<MTLDevice> device, void *bytes, size_t length);

void *stwo_zig_metal_runtime_create(
    const char *source_utf8,
    char *error_message,
    size_t error_message_len
) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            write_error(error_message, error_message_len, @"No Metal device available");
            return NULL;
        }
        NSString *source = [NSString stringWithUTF8String:source_utf8];
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.mathMode = MTLMathModeSafe;
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
        if (library == nil) {
            write_error(error_message, error_message_len,
                        error.localizedDescription ?: @"Failed to compile Metal library");
            return NULL;
        }
        StwoZigMetalRuntime *runtime = [StwoZigMetalRuntime new];
        runtime.device = device;
        runtime.queue = [device newCommandQueue];
        runtime.leaves = make_pipeline(device, library, @"stwo_zig_blake2s_leaves",
                                       error_message, error_message_len);
        runtime.parents = make_pipeline(device, library, @"stwo_zig_blake2s_parents",
                                        error_message, error_message_len);
        runtime.quotients = make_pipeline(device, library, @"stwo_zig_quotient_rows",
                                          error_message, error_message_len);
        runtime.rawQuotients = make_pipeline(device, library, @"stwo_zig_quotient_rows_raw",
                                             error_message, error_message_len);
        runtime.polynomialEval = make_pipeline(device, library, @"stwo_zig_eval_polynomials",
                                               error_message, error_message_len);
        runtime.polynomialBasis = make_pipeline(device, library, @"stwo_zig_eval_basis",
                                                error_message, error_message_len);
        runtime.circleIfftFirst = make_pipeline(device, library, @"stwo_zig_circle_ifft_first", error_message, error_message_len);
        runtime.circleIfftLayer = make_pipeline(device, library, @"stwo_zig_circle_ifft_layer", error_message, error_message_len);
        runtime.circleRfftLayer = make_pipeline(device, library, @"stwo_zig_circle_rfft_layer", error_message, error_message_len);
        runtime.circleRfftLast = make_pipeline(device, library, @"stwo_zig_circle_rfft_last", error_message, error_message_len);
        runtime.circleRescale = make_pipeline(device, library, @"stwo_zig_circle_rescale", error_message, error_message_len);
        runtime.circleExpand = make_pipeline(device, library, @"stwo_zig_circle_expand_coefficients", error_message, error_message_len);
        runtime.circleIfftFused = make_pipeline(device, library, @"stwo_zig_circle_ifft_fused_tail", error_message, error_message_len);
        runtime.circleRfftFused = make_pipeline(device, library, @"stwo_zig_circle_rfft_fused_tail", error_message, error_message_len);
        runtime.quotientNumerator = make_pipeline(device, library, @"stwo_zig_quotient_numerator_raw", error_message, error_message_len);
        runtime.quotientFinalize = make_pipeline(device, library, @"stwo_zig_quotient_finalize", error_message, error_message_len);
        runtime.quotientDomainPointsResident = make_pipeline(device, library, @"stwo_zig_quotient_domain_points_resident", error_message, error_message_len);
        runtime.quotientDenominatorsResident = make_pipeline(device, library, @"stwo_zig_quotient_denominators_resident", error_message, error_message_len);
        runtime.quotientCombineResident = make_pipeline(device, library, @"stwo_zig_quotient_combine_resident", error_message, error_message_len);
        runtime.friFoldCircle = make_pipeline(device, library, @"stwo_zig_fri_fold_circle", error_message, error_message_len);
        runtime.friFoldLine = make_pipeline(device, library, @"stwo_zig_fri_fold_line", error_message, error_message_len);
        runtime.friFold3Resident = make_pipeline(device, library, @"stwo_zig_fri_fold3_resident", error_message, error_message_len);
        runtime.friFold2Resident = make_pipeline(device, library, @"stwo_zig_fri_fold2_resident", error_message, error_message_len);
        runtime.friPackedLeavesResident = make_pipeline(device, library, @"stwo_zig_fri_packed_leaves_resident", error_message, error_message_len);
        runtime.friFinalLineResident = make_pipeline(device, library, @"stwo_zig_fri_final_line_resident", error_message, error_message_len);
        runtime.transcriptInitResident = make_pipeline(device, library, @"stwo_zig_transcript_init_resident", error_message, error_message_len);
        runtime.transcriptMixResident = make_pipeline(device, library, @"stwo_zig_transcript_mix_resident", error_message, error_message_len);
        runtime.transcriptDrawSecureResident = make_pipeline(device, library, @"stwo_zig_transcript_draw_secure_resident", error_message, error_message_len);
        runtime.transcriptDrawQueriesResident = make_pipeline(device, library, @"stwo_zig_transcript_draw_queries_resident", error_message, error_message_len);
        runtime.decommitNormalizeQueriesResident = make_pipeline(device, library, @"stwo_zig_decommit_normalize_queries_resident", error_message, error_message_len);
        runtime.decommitPrepareFriQueriesResident = make_pipeline(device, library, @"stwo_zig_decommit_prepare_fri_queries_resident", error_message, error_message_len);
        runtime.decommitGatherFriValuesResident = make_pipeline(device, library, @"stwo_zig_decommit_gather_fri_values_resident", error_message, error_message_len);
        runtime.decommitPrepareTraceQueriesResident = make_pipeline(device, library, @"stwo_zig_decommit_prepare_trace_queries_resident", error_message, error_message_len);
        runtime.decommitGatherTraceValuesResident = make_pipeline(device, library, @"stwo_zig_decommit_gather_trace_values_resident", error_message, error_message_len);
        runtime.decommitAssembleFriResident = make_pipeline(device, library, @"stwo_zig_decommit_assemble_fri_resident", error_message, error_message_len);
        runtime.decommitSparseParentResident = make_pipeline(device, library, @"stwo_zig_decommit_sparse_parent_resident", error_message, error_message_len);
        runtime.decommitSparseLeavesResident = make_pipeline(device, library, @"stwo_zig_decommit_sparse_leaves_resident", error_message, error_message_len);
        runtime.decommitAssembleTraceResident = make_pipeline(device, library, @"stwo_zig_decommit_assemble_trace_resident", error_message, error_message_len);
        runtime.qm31ToCoordinates = make_pipeline(device, library, @"stwo_zig_qm31_to_coordinates", error_message, error_message_len);
        runtime.witnessFeedCounts = make_pipeline(device, library, @"stwo_zig_witness_feed_counts", error_message, error_message_len);
        runtime.witnessInputGatherResident = make_pipeline(device, library, @"stwo_zig_witness_input_gather_resident", error_message, error_message_len);
        runtime.executionTableSplitResident = make_pipeline(device, library, @"stwo_zig_execution_table_split_resident", error_message, error_message_len);
        runtime.clearArenaRanges = make_pipeline(device, library, @"stwo_zig_clear_arena_ranges", error_message, error_message_len);
        runtime.clearArenaSpans = make_pipeline(device, library, @"stwo_zig_clear_arena_spans", error_message, error_message_len);
        runtime.circleExpandSparse = make_pipeline(device, library, @"stwo_zig_circle_expand_sparse", error_message, error_message_len);
        runtime.circleCopySparse = make_pipeline(device, library, @"stwo_zig_circle_copy_sparse", error_message, error_message_len);
        runtime.circleIfftFirstSparse = make_pipeline(device, library, @"stwo_zig_circle_ifft_first_sparse", error_message, error_message_len);
        runtime.circleIfftLayerSparse = make_pipeline(device, library, @"stwo_zig_circle_ifft_layer_sparse", error_message, error_message_len);
        runtime.circleRescaleSparse = make_pipeline(device, library, @"stwo_zig_circle_rescale_sparse", error_message, error_message_len);
        runtime.circleRfftLayerSparse = make_pipeline(device, library, @"stwo_zig_circle_rfft_layer_sparse", error_message, error_message_len);
        runtime.circleRfftLastSparse = make_pipeline(device, library, @"stwo_zig_circle_rfft_last_sparse", error_message, error_message_len);
        runtime.relationFused = make_pipeline(device, library, @"stwo_zig_relation_fused", error_message, error_message_len);
        runtime.relationBlockScan = make_pipeline(device, library, @"stwo_zig_relation_block_scan", error_message, error_message_len);
        runtime.relationScanBlocks = make_pipeline(device, library, @"stwo_zig_relation_scan_blocks", error_message, error_message_len);
        runtime.relationScanFinalize = make_pipeline(device, library, @"stwo_zig_relation_scan_finalize", error_message, error_message_len);
        runtime.fixedTableLookup = make_pipeline(device, library, @"stwo_zig_fixed_table_lookup_sparse", error_message, error_message_len);
        runtime.parentsSparse = make_pipeline(device, library, @"stwo_zig_blake2s_parents_sparse", error_message, error_message_len);
        runtime.felt252Oracle = make_pipeline(device, library, @"stwo_zig_felt252_oracle", error_message, error_message_len);
        runtime.ecOpWitness = make_pipeline(device, library, @"stwo_zig_ec_op_witness", error_message, error_message_len);
        runtime.compactGather = make_pipeline(device, library, @"stwo_zig_compact_gather", error_message, error_message_len);
        runtime.compactRadixHistogram = make_pipeline(device, library, @"stwo_zig_compact_radix_histogram", error_message, error_message_len);
        runtime.compactRadixPrefix = make_pipeline(device, library, @"stwo_zig_compact_radix_prefix", error_message, error_message_len);
        runtime.compactRadixScatter = make_pipeline(device, library, @"stwo_zig_compact_radix_scatter", error_message, error_message_len);
        runtime.compactHeads = make_pipeline(device, library, @"stwo_zig_compact_heads", error_message, error_message_len);
        runtime.compactScanLocal = make_pipeline(device, library, @"stwo_zig_compact_scan_local", error_message, error_message_len);
        runtime.compactScanBlocks = make_pipeline(device, library, @"stwo_zig_compact_scan_blocks", error_message, error_message_len);
        runtime.compactScanAdd = make_pipeline(device, library, @"stwo_zig_compact_scan_add", error_message, error_message_len);
        runtime.compactClearOutputs = make_pipeline(device, library, @"stwo_zig_compact_clear_outputs", error_message, error_message_len);
        runtime.compactScatter = make_pipeline(device, library, @"stwo_zig_compact_scatter", error_message, error_message_len);
        runtime.compactFinalize = make_pipeline(device, library, @"stwo_zig_compact_finalize", error_message, error_message_len);
        runtime.compositionLift = make_pipeline(device, library, @"stwo_zig_composition_lift_accumulate", error_message, error_message_len);
        runtime.compositionSplit = make_pipeline(device, library, @"stwo_zig_composition_split_coordinates", error_message, error_message_len);
        runtime.compositionExpand = make_pipeline(device, library, @"stwo_zig_composition_expand_sparse", error_message, error_message_len);
        runtime.compositionRandomPowers = make_pipeline(device, library, @"stwo_zig_composition_random_powers", error_message, error_message_len);
        runtime.compositionExtParams = make_pipeline(device, library, @"stwo_zig_composition_ext_params", error_message, error_message_len);
        if (runtime.queue == nil || runtime.leaves == nil || runtime.parents == nil ||
            runtime.quotients == nil || runtime.rawQuotients == nil || runtime.polynomialEval == nil ||
            runtime.polynomialBasis == nil || runtime.circleIfftFirst == nil || runtime.circleIfftLayer == nil ||
            runtime.circleRfftLayer == nil || runtime.circleRfftLast == nil || runtime.circleRescale == nil ||
            runtime.circleExpand == nil || runtime.circleIfftFused == nil || runtime.circleRfftFused == nil ||
            runtime.quotientNumerator == nil || runtime.quotientFinalize == nil ||
            runtime.quotientDomainPointsResident == nil || runtime.quotientDenominatorsResident == nil ||
            runtime.quotientCombineResident == nil ||
            runtime.friFoldCircle == nil || runtime.friFoldLine == nil || runtime.friFold3Resident == nil ||
            runtime.friFold2Resident == nil || runtime.friPackedLeavesResident == nil || runtime.friFinalLineResident == nil ||
            runtime.transcriptInitResident == nil || runtime.transcriptMixResident == nil ||
            runtime.transcriptDrawSecureResident == nil || runtime.transcriptDrawQueriesResident == nil ||
            runtime.decommitNormalizeQueriesResident == nil || runtime.decommitPrepareFriQueriesResident == nil ||
            runtime.decommitGatherFriValuesResident == nil || runtime.decommitPrepareTraceQueriesResident == nil ||
            runtime.decommitGatherTraceValuesResident == nil || runtime.qm31ToCoordinates == nil ||
            runtime.decommitAssembleFriResident == nil ||
            runtime.decommitSparseParentResident == nil || runtime.decommitAssembleTraceResident == nil ||
            runtime.decommitSparseLeavesResident == nil ||
            runtime.witnessFeedCounts == nil || runtime.clearArenaRanges == nil || runtime.clearArenaSpans == nil ||
            runtime.witnessInputGatherResident == nil ||
            runtime.executionTableSplitResident == nil ||
            runtime.circleExpandSparse == nil || runtime.circleCopySparse == nil || runtime.circleIfftFirstSparse == nil ||
            runtime.circleIfftLayerSparse == nil || runtime.circleRescaleSparse == nil ||
            runtime.circleRfftLayerSparse == nil || runtime.circleRfftLastSparse == nil) return NULL;
        if (runtime.relationFused == nil || runtime.relationBlockScan == nil ||
            runtime.relationScanBlocks == nil || runtime.relationScanFinalize == nil || runtime.fixedTableLookup == nil ||
            runtime.parentsSparse == nil || runtime.felt252Oracle == nil || runtime.ecOpWitness == nil ||
            runtime.compactGather == nil || runtime.compactRadixHistogram == nil || runtime.compactRadixPrefix == nil ||
            runtime.compactRadixScatter == nil || runtime.compactHeads == nil || runtime.compactScanLocal == nil ||
            runtime.compactScanBlocks == nil || runtime.compactScanAdd == nil || runtime.compactClearOutputs == nil ||
            runtime.compactScatter == nil || runtime.compactFinalize == nil || runtime.compositionLift == nil ||
            runtime.compositionSplit == nil || runtime.compositionExpand == nil || runtime.compositionRandomPowers == nil ||
            runtime.compositionExtParams == nil) return NULL;
        return (__bridge_retained void *)runtime;
    }
}

bool stwo_zig_metal_qm31_to_coordinates(
    void *runtime_ptr, const uint32_t *source, uint32_t value_count,
    uint32_t *destination, double *gpu_milliseconds,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || source == NULL || destination == NULL || value_count == 0u) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        size_t bytes = (size_t)value_count * 4u * sizeof(uint32_t);
        id<MTLBuffer> source_buffer = alias_shared_buffer(runtime.device, (void *)source, bytes);
        if (source_buffer == nil) source_buffer = [runtime.device newBufferWithBytes:source length:bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> destination_buffer = alias_shared_buffer(runtime.device, destination, bytes);
        bool direct_destination = destination_buffer != nil;
        if (destination_buffer == nil) destination_buffer = [runtime.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        if (source_buffer == nil || destination_buffer == nil) {
            write_error(error_message, error_message_len, @"QM31 coordinate buffer allocation failed"); return false;
        }
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.qm31ToCoordinates];
        [encoder setBuffer:source_buffer offset:0 atIndex:0]; [encoder setBuffer:destination_buffer offset:0 atIndex:1];
        [encoder setBytes:&value_count length:sizeof(value_count) atIndex:2];
        NSUInteger width = MIN(runtime.qm31ToCoordinates.maxTotalThreadsPerThreadgroup, runtime.qm31ToCoordinates.threadExecutionWidth * 8u);
        [encoder dispatchThreads:MTLSizeMake(value_count, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (!direct_destination) memcpy(destination, destination_buffer.contents, bytes);
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

bool stwo_zig_metal_felt252_oracle(
    void *runtime_ptr, const uint32_t *inputs, uint32_t count, uint32_t *outputs,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || inputs == NULL || outputs == NULL || count == 0u) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        NSUInteger bytes = (NSUInteger)count * 16u * sizeof(uint32_t);
        id<MTLBuffer> input = [runtime.device newBufferWithBytes:inputs length:bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> output = [runtime.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        if (input == nil || output == nil) { write_error(error_message, error_message_len, @"Metal Felt252 oracle allocation failed"); return false; }
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.felt252Oracle]; [encoder setBuffer:input offset:0 atIndex:0];
        [encoder setBuffer:output offset:0 atIndex:1]; [encoder setBytes:&count length:sizeof(count) atIndex:2];
        NSUInteger width = MIN((NSUInteger)256u, runtime.felt252Oracle.maxTotalThreadsPerThreadgroup);
        [encoder dispatchThreads:MTLSizeMake(count, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        memcpy(outputs, output.contents, bytes);
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

static id<MTLBuffer> alias_shared_buffer(id<MTLDevice> device, void *bytes, size_t length) {
    size_t page_size = (size_t)getpagesize();
    if (((uintptr_t)bytes % page_size) == 0u && (length % page_size) == 0u) {
        return [device newBufferWithBytesNoCopy:bytes length:length
                                        options:MTLResourceStorageModeShared deallocator:nil];
    }
    return nil;
}

bool stwo_zig_metal_fri_fold_circle(
    void *runtime_ptr, const uint32_t *source, uint32_t source_count,
    const uint32_t *inverse_y, const uint32_t *alpha, uint32_t *destination,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || source == NULL || inverse_y == NULL || alpha == NULL || destination == NULL || source_count < 2u) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        uint32_t destination_count = source_count >> 1u;
        size_t source_bytes = (size_t)source_count * 4u * sizeof(uint32_t);
        size_t destination_bytes = (size_t)destination_count * 4u * sizeof(uint32_t);
        id<MTLBuffer> source_buffer = alias_shared_buffer(runtime.device, (void *)source, source_bytes);
        if (source_buffer == nil) source_buffer = [runtime.device newBufferWithBytes:source length:source_bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> destination_buffer = alias_shared_buffer(runtime.device, destination, destination_bytes);
        bool direct_destination = destination_buffer != nil;
        if (destination_buffer == nil) destination_buffer = [runtime.device newBufferWithLength:destination_bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> inverse_buffer = [runtime.device newBufferWithBytes:inverse_y length:(size_t)destination_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        if (source_buffer == nil || destination_buffer == nil || inverse_buffer == nil) {
            write_error(error_message, error_message_len, @"FRI circle fold buffer allocation failed");
            return false;
        }
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.friFoldCircle];
        [encoder setBuffer:source_buffer offset:0 atIndex:0];
        [encoder setBuffer:inverse_buffer offset:0 atIndex:1];
        [encoder setBytes:alpha length:4u * sizeof(uint32_t) atIndex:2];
        [encoder setBuffer:destination_buffer offset:0 atIndex:3];
        [encoder setBytes:&destination_count length:sizeof(destination_count) atIndex:4];
        NSUInteger width = MIN(runtime.friFoldCircle.maxTotalThreadsPerThreadgroup, runtime.friFoldCircle.threadExecutionWidth * 8u);
        [encoder dispatchThreads:MTLSizeMake(destination_count, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [encoder endEncoding];
        [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len, command.error.localizedDescription); return false;
        }
        if (!direct_destination) memcpy(destination, destination_buffer.contents, destination_bytes);
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

bool stwo_zig_metal_fri_fold_line(
    void *runtime_ptr, const uint32_t *source, uint32_t source_count,
    const uint32_t *inverse_x, const uint32_t *alpha, uint32_t *destination,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || source == NULL || inverse_x == NULL || alpha == NULL || destination == NULL || source_count < 2u) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        uint32_t destination_count = source_count >> 1u;
        size_t source_bytes = (size_t)source_count * 4u * sizeof(uint32_t);
        size_t destination_bytes = (size_t)destination_count * 4u * sizeof(uint32_t);
        id<MTLBuffer> source_buffer = alias_shared_buffer(runtime.device, (void *)source, source_bytes);
        if (source_buffer == nil) source_buffer = [runtime.device newBufferWithBytes:source length:source_bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> destination_buffer = alias_shared_buffer(runtime.device, destination, destination_bytes);
        bool direct_destination = destination_buffer != nil;
        if (destination_buffer == nil) destination_buffer = [runtime.device newBufferWithLength:destination_bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> inverse_buffer = [runtime.device newBufferWithBytes:inverse_x length:(size_t)destination_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        if (source_buffer == nil || destination_buffer == nil || inverse_buffer == nil) {
            write_error(error_message, error_message_len, @"FRI line fold buffer allocation failed"); return false;
        }
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.friFoldLine];
        [encoder setBuffer:source_buffer offset:0 atIndex:0]; [encoder setBuffer:inverse_buffer offset:0 atIndex:1];
        [encoder setBytes:alpha length:4u * sizeof(uint32_t) atIndex:2]; [encoder setBuffer:destination_buffer offset:0 atIndex:3];
        [encoder setBytes:&destination_count length:sizeof(destination_count) atIndex:4];
        NSUInteger width = MIN(runtime.friFoldLine.maxTotalThreadsPerThreadgroup, runtime.friFoldLine.threadExecutionWidth * 8u);
        [encoder dispatchThreads:MTLSizeMake(destination_count, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (!direct_destination) memcpy(destination, destination_buffer.contents, destination_bytes);
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_fri_fold_prepare(
    void *runtime_ptr, uint32_t source_offset_words, uint32_t inverse_offset_words,
    uint32_t alpha_offset_words, uint32_t destination_offset_words,
    uint32_t source_count, bool circle,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || source_count < 2u || (source_count & 1u) != 0u) return NULL;
    @autoreleasepool {
        StwoZigFriFoldPlan *plan = [StwoZigFriFoldPlan new];
        plan.sourceByteOffset = (NSUInteger)source_offset_words * sizeof(uint32_t);
        plan.inverseByteOffset = (NSUInteger)inverse_offset_words * sizeof(uint32_t);
        plan.alphaByteOffset = (NSUInteger)alpha_offset_words * sizeof(uint32_t);
        plan.destinationByteOffset = (NSUInteger)destination_offset_words * sizeof(uint32_t);
        plan.sourceCount = source_count;
        plan.circle = circle;
        if (plan == nil) {
            write_error(error_message, error_message_len, @"Metal FRI fold plan allocation failed");
            return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_fri_fold_plan_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

bool stwo_zig_metal_fri_fold_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigFriFoldPlan *plan = (__bridge StwoZigFriFoldPlan *)plan_ptr;
        uint32_t destination_count = plan.sourceCount >> 1u;
        if (plan.sourceByteOffset + (NSUInteger)plan.sourceCount * 4u * sizeof(uint32_t) > arena.length ||
            plan.inverseByteOffset + (NSUInteger)destination_count * sizeof(uint32_t) > arena.length ||
            plan.alphaByteOffset + 4u * sizeof(uint32_t) > arena.length ||
            plan.destinationByteOffset + (NSUInteger)destination_count * 4u * sizeof(uint32_t) > arena.length) {
            write_error(error_message, error_message_len, @"Metal FRI fold plan exceeds arena");
            return false;
        }
        id<MTLComputePipelineState> pipeline = plan.circle ? runtime.friFoldCircle : runtime.friFoldLine;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:arena offset:plan.sourceByteOffset atIndex:0];
        [encoder setBuffer:arena offset:plan.inverseByteOffset atIndex:1];
        [encoder setBuffer:arena offset:plan.alphaByteOffset atIndex:2];
        [encoder setBuffer:arena offset:plan.destinationByteOffset atIndex:3];
        [encoder setBytes:&destination_count length:sizeof(destination_count) atIndex:4];
        NSUInteger width = MIN(pipeline.maxTotalThreadsPerThreadgroup, pipeline.threadExecutionWidth * 8u);
        [encoder dispatchThreads:MTLSizeMake(destination_count, 1u, 1u)
             threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len, command.error.localizedDescription);
            return false;
        }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_quotient_combine_prepare(
    void *runtime_ptr, const uint32_t *partial_offsets, const uint32_t *partial_logs,
    uint32_t sample_count, uint32_t sample_offset, uint32_t linear_offset,
    uint32_t scratch_offset, uint32_t output_offset, uint32_t row_count,
    uint32_t log_size, uint32_t initial_index, uint32_t step_size,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || partial_offsets == NULL || partial_logs == NULL || sample_count == 0u ||
        row_count < 4u || (row_count & (row_count - 1u)) != 0u || log_size >= 31u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigQuotientCombinePlan *plan = [StwoZigQuotientCombinePlan new];
        plan.partialOffsets = [runtime.device newBufferWithBytes:partial_offsets length:(NSUInteger)sample_count * 4u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.partialLogs = [runtime.device newBufferWithBytes:partial_logs length:(NSUInteger)sample_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.sampleCount = sample_count; plan.sampleOffset = sample_offset; plan.linearOffset = linear_offset;
        plan.scratchOffset = scratch_offset; plan.outputOffset = output_offset; plan.rowCount = row_count;
        plan.logSize = log_size; plan.initialIndex = initial_index; plan.stepSize = step_size;
        if (plan.partialOffsets == nil || plan.partialLogs == nil) {
            write_error(error_message, error_message_len, @"Metal quotient-combine plan allocation failed");
            return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_quotient_combine_plan_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

bool stwo_zig_metal_quotient_combine_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigQuotientCombinePlan *plan = (__bridge StwoZigQuotientCombinePlan *)plan_ptr;
        uint32_t rows = plan.rowCount, log_size = plan.logSize, samples = plan.sampleCount;
        NSUInteger output_end = ((NSUInteger)plan.outputOffset + (NSUInteger)rows * 4u) * sizeof(uint32_t);
        NSUInteger scratch_end = ((NSUInteger)plan.scratchOffset + (NSUInteger)rows * samples * 2u) * sizeof(uint32_t);
        NSUInteger sample_end = ((NSUInteger)plan.sampleOffset + (NSUInteger)samples * 8u) * sizeof(uint32_t);
        NSUInteger linear_end = ((NSUInteger)plan.linearOffset + (NSUInteger)samples * 4u) * sizeof(uint32_t);
        if (output_end > arena.length || scratch_end > arena.length || sample_end > arena.length || linear_end > arena.length) {
            write_error(error_message, error_message_len, @"Metal quotient-combine plan exceeds arena");
            return false;
        }
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> domain = [command computeCommandEncoder];
        [domain setComputePipelineState:runtime.quotientDomainPointsResident]; [domain setBuffer:arena offset:0 atIndex:0];
        uint32_t output = plan.outputOffset, initial = plan.initialIndex, step = plan.stepSize;
        [domain setBytes:&output length:sizeof(output) atIndex:1]; [domain setBytes:&rows length:sizeof(rows) atIndex:2];
        [domain setBytes:&log_size length:sizeof(log_size) atIndex:3]; [domain setBytes:&initial length:sizeof(initial) atIndex:4];
        [domain setBytes:&step length:sizeof(step) atIndex:5];
        NSUInteger domain_width = MIN(runtime.quotientDomainPointsResident.maxTotalThreadsPerThreadgroup, runtime.quotientDomainPointsResident.threadExecutionWidth * 8u);
        [domain dispatchThreads:MTLSizeMake(rows, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(domain_width, 1u, 1u)];
        [domain endEncoding];

        id<MTLComputeCommandEncoder> denominators = [command computeCommandEncoder];
        [denominators setComputePipelineState:runtime.quotientDenominatorsResident]; [denominators setBuffer:arena offset:0 atIndex:0];
        uint32_t sample = plan.sampleOffset, scratch = plan.scratchOffset;
        [denominators setBytes:&output length:sizeof(output) atIndex:1]; [denominators setBytes:&sample length:sizeof(sample) atIndex:2];
        [denominators setBytes:&scratch length:sizeof(scratch) atIndex:3]; [denominators setBytes:&rows length:sizeof(rows) atIndex:4];
        [denominators setBytes:&samples length:sizeof(samples) atIndex:5];
        NSUInteger denominator_width = MIN(runtime.quotientDenominatorsResident.maxTotalThreadsPerThreadgroup, runtime.quotientDenominatorsResident.threadExecutionWidth * 8u);
        [denominators dispatchThreads:MTLSizeMake((NSUInteger)rows * samples, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(denominator_width, 1u, 1u)];
        [denominators endEncoding];

        id<MTLComputeCommandEncoder> combine = [command computeCommandEncoder];
        [combine setComputePipelineState:runtime.quotientCombineResident]; [combine setBuffer:arena offset:0 atIndex:0];
        [combine setBuffer:plan.partialOffsets offset:0 atIndex:1]; [combine setBuffer:plan.partialLogs offset:0 atIndex:2];
        uint32_t linear = plan.linearOffset;
        [combine setBytes:&sample length:sizeof(sample) atIndex:3]; [combine setBytes:&linear length:sizeof(linear) atIndex:4];
        [combine setBytes:&scratch length:sizeof(scratch) atIndex:5]; [combine setBytes:&output length:sizeof(output) atIndex:6];
        [combine setBytes:&rows length:sizeof(rows) atIndex:7]; [combine setBytes:&log_size length:sizeof(log_size) atIndex:8];
        [combine setBytes:&samples length:sizeof(samples) atIndex:9];
        NSUInteger combine_width = MIN(runtime.quotientCombineResident.maxTotalThreadsPerThreadgroup, runtime.quotientCombineResident.threadExecutionWidth * 8u);
        [combine dispatchThreads:MTLSizeMake(rows, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(combine_width, 1u, 1u)];
        [combine endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len, command.error.localizedDescription); return false;
        }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_fri_round_prepare(
    void *runtime_ptr, uint32_t twiddle_base, uint32_t twiddle_words,
    uint32_t input_base, uint32_t input_stride, uint32_t alpha_base,
    uint32_t output_base, uint32_t output_stride, uint32_t n,
    uint32_t fold_count, bool first_circle,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || n < 4u || (n & (n - 1u)) != 0u ||
        (fold_count != 2u && fold_count != 3u) || (first_circle && fold_count != 3u)) return NULL;
    uint32_t consumed0 = first_circle ? (n >> 1u) : n;
    if (twiddle_words < consumed0 || twiddle_words < (n >> 1u) ||
        (fold_count == 3u && twiddle_words < (n >> 2u))) return NULL;
    @autoreleasepool {
        StwoZigFriRoundPlan *plan = [StwoZigFriRoundPlan new];
        plan.twiddleBase = twiddle_base; plan.twiddleOffset0 = twiddle_words - consumed0;
        plan.twiddleOffset1 = twiddle_words - (n >> 1u);
        plan.twiddleOffset2 = fold_count == 3u ? twiddle_words - (n >> 2u) : 0u;
        plan.inputBase = input_base; plan.inputStride = input_stride; plan.alphaBase = alpha_base;
        plan.outputBase = output_base; plan.outputStride = output_stride; plan.n = n;
        plan.foldCount = fold_count; plan.firstCircle = first_circle ? 1u : 0u;
        if (plan == nil) { write_error(error_message, error_message_len, @"Metal FRI round plan allocation failed"); return NULL; }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_fri_round_plan_destroy(void *plan_ptr) { if (plan_ptr != NULL) CFRelease(plan_ptr); }

bool stwo_zig_metal_fri_round_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigFriRoundPlan *plan = (__bridge StwoZigFriRoundPlan *)plan_ptr;
        uint32_t output_count = plan.n >> plan.foldCount;
        NSUInteger input_end = ((NSUInteger)plan.inputBase + (NSUInteger)plan.inputStride * 3u + plan.n) * sizeof(uint32_t);
        NSUInteger output_end = ((NSUInteger)plan.outputBase + (NSUInteger)plan.outputStride * 3u + output_count) * sizeof(uint32_t);
        NSUInteger alpha_end = ((NSUInteger)plan.alphaBase + 4u) * sizeof(uint32_t);
        if (input_end > arena.length || output_end > arena.length || alpha_end > arena.length) {
            write_error(error_message, error_message_len, @"Metal FRI round exceeds arena"); return false;
        }
        id<MTLComputePipelineState> pipeline = plan.foldCount == 3u ? runtime.friFold3Resident : runtime.friFold2Resident;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:pipeline]; [encoder setBuffer:arena offset:0 atIndex:0];
        uint32_t values[] = { plan.twiddleBase, plan.twiddleOffset0, plan.twiddleOffset1, plan.twiddleOffset2,
            plan.inputBase, plan.inputStride, plan.alphaBase, plan.outputBase, plan.outputStride, plan.n, plan.firstCircle };
        if (plan.foldCount == 3u) {
            for (NSUInteger i = 0; i < 11u; ++i) [encoder setBytes:&values[i] length:sizeof(uint32_t) atIndex:i + 1u];
        } else {
            uint32_t compact[] = { plan.twiddleBase, plan.twiddleOffset0, plan.twiddleOffset1,
                plan.inputBase, plan.inputStride, plan.alphaBase, plan.outputBase, plan.outputStride, plan.n };
            for (NSUInteger i = 0; i < 9u; ++i) [encoder setBytes:&compact[i] length:sizeof(uint32_t) atIndex:i + 1u];
        }
        NSUInteger width = MIN(pipeline.maxTotalThreadsPerThreadgroup, pipeline.threadExecutionWidth * 8u);
        [encoder dispatchThreads:MTLSizeMake(output_count, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_fri_tree_prepare(
    void *runtime_ptr, uint32_t evaluation_base, uint32_t coordinate_stride,
    uint32_t evaluation_size, uint32_t log_rows_per_leaf,
    const uint32_t *layer_offsets, uint32_t layer_count,
    const uint32_t *leaf_seed, const uint32_t *node_seed,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || evaluation_size == 0u || (evaluation_size & (evaluation_size - 1u)) != 0u ||
        log_rows_per_leaf > 2u || layer_offsets == NULL || layer_count < 2u || leaf_seed == NULL || node_seed == NULL) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigFriTreePlan *plan = [StwoZigFriTreePlan new];
        plan.evaluationBase = evaluation_base; plan.coordinateStride = coordinate_stride;
        plan.evaluationSize = evaluation_size; plan.logRowsPerLeaf = log_rows_per_leaf; plan.layerCount = layer_count;
        plan.layerOffsets = [NSData dataWithBytes:layer_offsets length:(NSUInteger)layer_count * sizeof(uint32_t)];
        plan.leafSeed = [runtime.device newBufferWithBytes:leaf_seed length:8u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.nodeSeed = [runtime.device newBufferWithBytes:node_seed length:8u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        if (plan.layerOffsets == nil || plan.leafSeed == nil || plan.nodeSeed == nil) {
            write_error(error_message, error_message_len, @"Metal FRI tree plan allocation failed"); return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_fri_tree_plan_destroy(void *plan_ptr) { if (plan_ptr != NULL) CFRelease(plan_ptr); }

bool stwo_zig_metal_fri_tree_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigFriTreePlan *plan = (__bridge StwoZigFriTreePlan *)plan_ptr;
        const uint32_t *layers = plan.layerOffsets.bytes;
        uint32_t leaves = plan.evaluationSize >> plan.logRowsPerLeaf;
        NSUInteger evaluation_end = ((NSUInteger)plan.evaluationBase + (NSUInteger)plan.coordinateStride * 3u + plan.evaluationSize) * sizeof(uint32_t);
        NSUInteger leaf_end = ((NSUInteger)layers[0] + (NSUInteger)leaves * 8u) * sizeof(uint32_t);
        if (evaluation_end > arena.length || leaf_end > arena.length) { write_error(error_message, error_message_len, @"Metal FRI tree exceeds arena"); return false; }
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> leaf = [command computeCommandEncoder];
        [leaf setComputePipelineState:runtime.friPackedLeavesResident]; [leaf setBuffer:arena offset:0 atIndex:0];
        uint32_t base = plan.evaluationBase, stride = plan.coordinateStride, size = plan.evaluationSize;
        uint32_t packed = plan.logRowsPerLeaf, destination = layers[0];
        [leaf setBytes:&base length:sizeof(base) atIndex:1]; [leaf setBytes:&stride length:sizeof(stride) atIndex:2];
        [leaf setBytes:&size length:sizeof(size) atIndex:3]; [leaf setBytes:&packed length:sizeof(packed) atIndex:4];
        [leaf setBytes:&destination length:sizeof(destination) atIndex:5]; [leaf setBuffer:plan.leafSeed offset:0 atIndex:6];
        NSUInteger leaf_width = MIN(runtime.friPackedLeavesResident.maxTotalThreadsPerThreadgroup, runtime.friPackedLeavesResident.threadExecutionWidth * 8u);
        [leaf dispatchThreads:MTLSizeMake(leaves, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(leaf_width, 1u, 1u)];
        [leaf endEncoding];
        uint32_t parents = leaves >> 1u;
        for (uint32_t level = 1u; level < plan.layerCount; ++level) {
            id<MTLComputeCommandEncoder> parent = [command computeCommandEncoder];
            [parent setComputePipelineState:runtime.parentsSparse]; [parent setBuffer:arena offset:0 atIndex:0];
            uint32_t child = layers[level - 1u], output = layers[level];
            [parent setBytes:&child length:sizeof(child) atIndex:1]; [parent setBytes:&output length:sizeof(output) atIndex:2];
            [parent setBytes:&parents length:sizeof(parents) atIndex:3]; [parent setBuffer:plan.nodeSeed offset:0 atIndex:4];
            NSUInteger width = MIN(runtime.parentsSparse.maxTotalThreadsPerThreadgroup, runtime.parentsSparse.threadExecutionWidth * 8u);
            [parent dispatchThreads:MTLSizeMake(parents, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
            [parent endEncoding]; parents >>= 1u;
        }
        [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_fri_final_prepare(
    void *runtime_ptr, uint32_t evaluation_base, uint32_t coordinate_stride,
    uint32_t inverse_x, uint32_t coefficient_base, uint32_t degree_error,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || coordinate_stride < 2u || inverse_x == 0u) return NULL;
    @autoreleasepool {
        StwoZigFriFinalPlan *plan = [StwoZigFriFinalPlan new];
        plan.evaluationBase = evaluation_base; plan.coordinateStride = coordinate_stride;
        plan.inverseX = inverse_x; plan.coefficientBase = coefficient_base; plan.degreeError = degree_error;
        if (plan == nil) { write_error(error_message, error_message_len, @"Metal FRI final plan allocation failed"); return NULL; }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_fri_final_plan_destroy(void *plan_ptr) { if (plan_ptr != NULL) CFRelease(plan_ptr); }

bool stwo_zig_metal_fri_final_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigFriFinalPlan *plan = (__bridge StwoZigFriFinalPlan *)plan_ptr;
        NSUInteger evaluation_end = ((NSUInteger)plan.evaluationBase + (NSUInteger)plan.coordinateStride * 3u + 2u) * sizeof(uint32_t);
        NSUInteger coefficient_end = ((NSUInteger)plan.coefficientBase + 8u) * sizeof(uint32_t);
        NSUInteger error_end = ((NSUInteger)plan.degreeError + 1u) * sizeof(uint32_t);
        if (evaluation_end > arena.length || coefficient_end > arena.length || error_end > arena.length) {
            write_error(error_message, error_message_len, @"Metal FRI final exceeds arena"); return false;
        }
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.friFinalLineResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        uint32_t values[] = { plan.evaluationBase, plan.coordinateStride, plan.inverseX, plan.coefficientBase, plan.degreeError };
        for (NSUInteger i = 0; i < 5u; ++i) [encoder setBytes:&values[i] length:sizeof(uint32_t) atIndex:i + 1u];
        [encoder dispatchThreads:MTLSizeMake(1u, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(1u, 1u, 1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

bool stwo_zig_metal_transcript_init(
    void *runtime_ptr, void *arena_ptr, uint32_t state_base,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        if (((NSUInteger)state_base + 10u) * sizeof(uint32_t) > arena.length) return false;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.transcriptInitResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBytes:&state_base length:sizeof(state_base) atIndex:1];
        [encoder dispatchThreads:MTLSizeMake(1u,1u,1u) threadsPerThreadgroup:MTLSizeMake(1u,1u,1u)]; [encoder endEncoding];
        [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_transcript_mix(
    void *runtime_ptr, void *arena_ptr, uint32_t state_base, uint32_t source_base, uint32_t source_words,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || source_words == 0u) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        if (((NSUInteger)source_base + source_words) * 4u > arena.length || ((NSUInteger)state_base + 10u) * 4u > arena.length) return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.transcriptMixResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        uint32_t values[]={state_base,source_base,source_words}; for(NSUInteger i=0;i<3u;++i)[encoder setBytes:&values[i] length:4u atIndex:i+1u];
        [encoder dispatchThreads:MTLSizeMake(1u,1u,1u) threadsPerThreadgroup:MTLSizeMake(1u,1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_transcript_draw_secure(
    void *runtime_ptr, void *arena_ptr, uint32_t state_base, uint32_t destination_base, uint32_t felt_count,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || felt_count == 0u) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        if(((NSUInteger)destination_base+(NSUInteger)felt_count*4u)*4u>arena.length||((NSUInteger)state_base+10u)*4u>arena.length)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.transcriptDrawSecureResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        uint32_t values[]={state_base,destination_base,felt_count}; for(NSUInteger i=0;i<3u;++i)[encoder setBytes:&values[i] length:4u atIndex:i+1u];
        [encoder dispatchThreads:MTLSizeMake(1u,1u,1u) threadsPerThreadgroup:MTLSizeMake(1u,1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_transcript_draw_queries(
    void *runtime_ptr, void *arena_ptr, uint32_t state_base, uint32_t destination_base,
    uint32_t log_domain_size, uint32_t query_count, double *gpu_milliseconds,
    char *error_message, size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||log_domain_size>=32u||query_count==0u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        if(((NSUInteger)destination_base+query_count)*4u>arena.length||((NSUInteger)state_base+10u)*4u>arena.length)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.transcriptDrawQueriesResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        uint32_t values[]={state_base,destination_base,log_domain_size,query_count}; for(NSUInteger i=0;i<4u;++i)[encoder setBytes:&values[i] length:4u atIndex:i+1u];
        [encoder dispatchThreads:MTLSizeMake(1u,1u,1u) threadsPerThreadgroup:MTLSizeMake(1u,1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_normalize_queries(
    void *runtime_ptr, void *arena_ptr, uint32_t raw_base, uint32_t raw_count,
    uint32_t log_domain_size, uint32_t unique_base, uint32_t unique_count_base,
    uint32_t tree_count, uint32_t assembly_base, uint32_t assembly_capacity,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||raw_count==0u||log_domain_size==0u||log_domain_size>=31u||tree_count==0u||assembly_capacity<8u+tree_count*16u+raw_count)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t);
        if((NSUInteger)raw_base+raw_count>words||(NSUInteger)unique_base+raw_count>words||unique_count_base>=words||(NSUInteger)assembly_base+assembly_capacity>words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitNormalizeQueriesResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        uint32_t values[]={raw_base,raw_count,log_domain_size,unique_base,unique_count_base,tree_count,assembly_base,assembly_capacity}; for(NSUInteger i=0;i<8u;++i)[encoder setBytes:&values[i] length:4u atIndex:i+1u];
        [encoder dispatchThreads:MTLSizeMake(1u,1u,1u) threadsPerThreadgroup:MTLSizeMake(1u,1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_prepare_fri_queries(
    void *runtime_ptr, void *arena_ptr, uint32_t unique_base, uint32_t unique_count_base,
    uint32_t max_queries, uint32_t cumulative_fold, uint32_t fold_step, uint32_t packed_log,
    uint32_t tree_queries_base, uint32_t tree_count_base, uint32_t expanded_base,
    uint32_t expanded_count_base, uint32_t walk_base, uint32_t walk_count_base,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||max_queries==0u||fold_step==0u||fold_step>=8u||packed_log>=31u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t), expanded=(NSUInteger)max_queries<<fold_step;
        if((NSUInteger)unique_base+max_queries>words||unique_count_base>=words||(NSUInteger)tree_queries_base+max_queries>words||tree_count_base>=words||(NSUInteger)expanded_base+expanded>words||expanded_count_base>=words||(NSUInteger)walk_base+expanded>words||walk_count_base>=words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitPrepareFriQueriesResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        uint32_t values[]={unique_base,unique_count_base,max_queries,cumulative_fold,fold_step,packed_log,tree_queries_base,tree_count_base,expanded_base,expanded_count_base,walk_base,walk_count_base};
        for(NSUInteger i=0;i<12u;++i)[encoder setBytes:&values[i] length:4u atIndex:i+1u];
        [encoder dispatchThreads:MTLSizeMake(1u,1u,1u) threadsPerThreadgroup:MTLSizeMake(1u,1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_prepare_trace_queries(
    void *runtime_ptr, void *arena_ptr, uint32_t unique_base, uint32_t unique_count_base,
    uint32_t max_queries, uint32_t source_log, uint32_t tree_log, uint32_t leaf_log,
    uint32_t unretained, uint32_t mapped_base, uint32_t mapped_count_base,
    uint32_t walk_base, uint32_t walk_count_base, uint32_t leaves_base,
    uint32_t leaf_count_base, double *gpu_milliseconds, char *error_message,
    size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||max_queries==0u||source_log>=31u||tree_log>=31u||leaf_log>=31u||unretained>=8u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t), leaves=(NSUInteger)max_queries<<unretained;
        if((NSUInteger)unique_base+max_queries>words||unique_count_base>=words||(NSUInteger)mapped_base+max_queries>words||mapped_count_base>=words||(NSUInteger)walk_base+max_queries>words||walk_count_base>=words||(NSUInteger)leaves_base+leaves>words||leaf_count_base>=words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitPrepareTraceQueriesResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        uint32_t values[]={unique_base,unique_count_base,max_queries,source_log,tree_log,leaf_log,unretained,mapped_base,mapped_count_base,walk_base,walk_count_base,leaves_base,leaf_count_base};
        for(NSUInteger i=0;i<13u;++i)[encoder setBytes:&values[i] length:4u atIndex:i+1u];
        [encoder dispatchThreads:MTLSizeMake(1u,1u,1u) threadsPerThreadgroup:MTLSizeMake(1u,1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_gather_trace_values(
    void *runtime_ptr, void *arena_ptr, uint32_t column_offsets_base,
    uint32_t column_logs_base, uint32_t column_count, uint32_t lifting_log,
    uint32_t queries_base, uint32_t query_count_base, uint32_t max_queries,
    uint32_t first_column, uint32_t stride, uint32_t output_base,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||column_count==0u||max_queries==0u||stride<max_queries||lifting_log>=31u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t);
        NSUInteger output_end=(NSUInteger)output_base+((NSUInteger)first_column+column_count)*stride;
        if((NSUInteger)column_offsets_base+column_count>words||(NSUInteger)column_logs_base+column_count>words||
           (NSUInteger)queries_base+max_queries>words||query_count_base>=words||output_end>words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitGatherTraceValuesResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        uint32_t values[]={column_offsets_base,column_logs_base,column_count,lifting_log,queries_base,query_count_base,max_queries,first_column,stride,output_base};
        for(NSUInteger i=0;i<10u;++i)[encoder setBytes:&values[i] length:4u atIndex:i+1u];
        MTLSize threads=MTLSizeMake(MIN((NSUInteger)max_queries,32u),MIN((NSUInteger)column_count,8u),1u);
        [encoder dispatchThreads:MTLSizeMake(max_queries,column_count,1u) threadsPerThreadgroup:threads]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_gather_fri_values(
    void *runtime_ptr, void *arena_ptr, uint32_t coordinate_bases,
    uint32_t positions_base, uint32_t count_base, uint32_t max_positions,
    uint32_t values_base, double *gpu_milliseconds, char *error_message,
    size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||max_positions==0u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t);
        if((NSUInteger)coordinate_bases+4u>words||(NSUInteger)positions_base+max_positions>words||
           count_base>=words||(NSUInteger)values_base+(NSUInteger)max_positions*4u>words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitGatherFriValuesResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBuffer:arena offset:(NSUInteger)coordinate_bases*sizeof(uint32_t) atIndex:1];
        uint32_t values[]={positions_base,count_base,max_positions,values_base}; for(NSUInteger i=0;i<4u;++i)[encoder setBytes:&values[i] length:4u atIndex:i+2u];
        [encoder dispatchThreads:MTLSizeMake(max_positions,1u,1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)max_positions,256u),1u,1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_assemble_fri(
    void *runtime_ptr, void *arena_ptr, uint32_t tree_index, uint32_t leaf_log,
    uint32_t tree_queries, uint32_t tree_count_at, uint32_t expanded,
    uint32_t expanded_count_at, uint32_t values, uint32_t walk, uint32_t scratch,
    uint32_t walk_count_at, uint32_t retained_offsets, uint32_t assembly,
    uint32_t capacity, double *gpu_milliseconds, char *error_message,
    size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||leaf_log>=31u||capacity==0u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena_buffer=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena_buffer.length/sizeof(uint32_t);
        if(tree_count_at>=words||expanded_count_at>=words||walk_count_at>=words||
           (NSUInteger)retained_offsets+leaf_log+1u>words||(NSUInteger)assembly+capacity>words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitAssembleFriResident]; [encoder setBuffer:arena_buffer offset:0 atIndex:0];
        uint32_t args[]={tree_index,leaf_log,tree_queries,tree_count_at,expanded,expanded_count_at,values,walk,scratch,walk_count_at,retained_offsets,assembly,capacity};
        for(NSUInteger i=0;i<13u;++i)[encoder setBytes:&args[i] length:4u atIndex:i+1u];
        [encoder dispatchThreads:MTLSizeMake(1u,1u,1u) threadsPerThreadgroup:MTLSizeMake(1u,1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_sparse_parent(
    void *runtime_ptr, void *arena_ptr, uint32_t child_indices, uint32_t child_hashes,
    uint32_t child_count_at, uint32_t max_child_count, uint32_t parent_indices,
    uint32_t parent_hashes, uint32_t parent_count_at, const uint32_t node_seed[8],
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||node_seed==NULL||max_child_count<2u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t), parents=max_child_count/2u;
        if((NSUInteger)child_indices+max_child_count>words||(NSUInteger)child_hashes+(NSUInteger)max_child_count*8u>words||
           child_count_at>=words||(NSUInteger)parent_indices+parents>words||(NSUInteger)parent_hashes+parents*8u>words||parent_count_at>=words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitSparseParentResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        uint32_t args[]={child_indices,child_hashes,child_count_at,max_child_count,parent_indices,parent_hashes,parent_count_at};
        for(NSUInteger i=0;i<7u;++i)[encoder setBytes:&args[i] length:4u atIndex:i+1u]; [encoder setBytes:node_seed length:32u atIndex:8];
        [encoder dispatchThreads:MTLSizeMake(parents,1u,1u) threadsPerThreadgroup:MTLSizeMake(MIN(parents,256u),1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_sparse_leaves(
    void *runtime_ptr, void *arena_ptr, uint32_t column_offsets, uint32_t column_logs,
    uint32_t column_count, uint32_t lifting_log, uint32_t leaf_indices,
    uint32_t leaf_count_at, uint32_t max_leaf_count, uint32_t output_hashes,
    const uint32_t leaf_seed[8], double *gpu_milliseconds, char *error_message,
    size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||leaf_seed==NULL||column_count==0u||lifting_log>=31u||max_leaf_count==0u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t);
        if((NSUInteger)column_offsets+column_count>words||(NSUInteger)column_logs+column_count>words||
           (NSUInteger)leaf_indices+max_leaf_count>words||leaf_count_at>=words||(NSUInteger)output_hashes+(NSUInteger)max_leaf_count*8u>words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitSparseLeavesResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        uint32_t args[]={column_offsets,column_logs,column_count,lifting_log,leaf_indices,leaf_count_at,max_leaf_count,output_hashes};
        for(NSUInteger i=0;i<8u;++i)[encoder setBytes:&args[i] length:4u atIndex:i+1u]; [encoder setBytes:leaf_seed length:32u atIndex:9];
        [encoder dispatchThreads:MTLSizeMake(max_leaf_count,1u,1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)max_leaf_count,256u),1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_assemble_trace(
    void *runtime_ptr, void *arena_ptr, uint32_t tree_index, uint32_t role,
    uint32_t leaf_log, uint32_t first_retained_log, uint32_t column_count,
    uint32_t mapped, uint32_t mapped_count_at, uint32_t max_queries,
    uint32_t walk, uint32_t scratch, uint32_t walk_count_at, uint32_t values,
    uint32_t retained_offsets, uint32_t sparse_indices, uint32_t sparse_hashes,
    uint32_t sparse_offsets, uint32_t sparse_counts, uint32_t sparse_level_count,
    uint32_t assembly, uint32_t capacity, double *gpu_milliseconds,
    char *error_message, size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||leaf_log>=31u||column_count==0u||max_queries==0u||capacity==0u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t);
        if(mapped_count_at>=words||walk_count_at>=words||(NSUInteger)retained_offsets+first_retained_log+1u>words||
           (NSUInteger)sparse_offsets+sparse_level_count>words||(NSUInteger)sparse_counts+sparse_level_count>words||(NSUInteger)assembly+capacity>words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitAssembleTraceResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        uint32_t args[]={tree_index,role,leaf_log,first_retained_log,column_count,mapped,mapped_count_at,max_queries,walk,scratch,walk_count_at,values,retained_offsets,sparse_indices,sparse_hashes,sparse_offsets,sparse_counts,sparse_level_count,assembly,capacity};
        for(NSUInteger i=0;i<20u;++i)[encoder setBytes:&args[i] length:4u atIndex:i+1u];
        [encoder dispatchThreads:MTLSizeMake(1u,1u,1u) threadsPerThreadgroup:MTLSizeMake(1u,1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_witness_input_gather(
    void *runtime_ptr, void *arena_ptr, const uint32_t *producer_offsets,
    const uint32_t *edge_descriptors, uint32_t edge_count, uint32_t input_width,
    uint32_t total_real_rows, uint32_t consumer_rows, const uint32_t *consumer_offsets,
    uint32_t include_enabler, uint32_t include_iota, double *gpu_milliseconds,
    char *error_message, size_t error_message_len
) {
    uint32_t output_count=input_width+include_enabler+include_iota;
    if(runtime_ptr==NULL||arena_ptr==NULL||producer_offsets==NULL||edge_descriptors==NULL||consumer_offsets==NULL||
       edge_count==0u||input_width==0u||consumer_rows==0u||total_real_rows==0u||total_real_rows>consumer_rows||output_count==0u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t);
        for(uint32_t i=0u;i<output_count;++i)if((NSUInteger)consumer_offsets[i]+consumer_rows>words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.witnessInputGatherResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBytes:producer_offsets length:(NSUInteger)edge_count*4u atIndex:1];
        [encoder setBytes:edge_descriptors length:(NSUInteger)edge_count*5u*4u atIndex:2];
        uint32_t args[]={edge_count,input_width,total_real_rows,consumer_rows}; for(NSUInteger i=0;i<4u;++i)[encoder setBytes:&args[i] length:4u atIndex:i+3u];
        [encoder setBytes:consumer_offsets length:(NSUInteger)output_count*4u atIndex:7];
        [encoder setBytes:&include_enabler length:4u atIndex:8]; [encoder setBytes:&include_iota length:4u atIndex:9];
        [encoder dispatchThreads:MTLSizeMake(consumer_rows,1u,1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)consumer_rows,256u),1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_execution_table_split(
    void *runtime_ptr, void *arena_ptr, uint32_t source_offset, uint32_t value_count,
    uint32_t column_rows, uint32_t source_words, uint32_t limb_count,
    const uint32_t *destination_offsets, double *gpu_milliseconds,
    char *error_message, size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||destination_offsets==NULL||value_count>column_rows||
       column_rows==0u||!((source_words==8u&&limb_count==28u)||(source_words==4u&&limb_count==8u)))return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t);
        if((NSUInteger)source_offset+(NSUInteger)value_count*source_words>words)return false;
        for(uint32_t i=0u;i<limb_count;++i)if((NSUInteger)destination_offsets[i]+column_rows>words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.executionTableSplitResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        uint32_t args[]={source_offset,value_count,column_rows,source_words,limb_count};
        for(NSUInteger i=0;i<5u;++i)[encoder setBytes:&args[i] length:4u atIndex:i+1u];
        [encoder setBytes:destination_offsets length:(NSUInteger)limb_count*4u atIndex:6];
        [encoder dispatchThreads:MTLSizeMake(column_rows,1u,1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)column_rows,256u),1u,1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

void *stwo_zig_metal_buffer_create(
    void *runtime_ptr,
    size_t byte_length,
    void **contents,
    char *error_message,
    size_t error_message_len
) {
    if (runtime_ptr == NULL || byte_length == 0u || contents == NULL) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> buffer = [runtime.device newBufferWithLength:byte_length
                                                           options:MTLResourceStorageModeShared];
        if (buffer == nil || buffer.contents == NULL) {
            write_error(error_message, error_message_len, @"Metal resident buffer allocation failed");
            return NULL;
        }
        *contents = buffer.contents;
        return (__bridge_retained void *)buffer;
    }
}

void stwo_zig_metal_buffer_destroy(void *buffer) {
    if (buffer == NULL) return;
    @autoreleasepool { __unused id value = (__bridge_transfer id)buffer; }
}

bool stwo_zig_metal_clear_arena_ranges(
    void *runtime_ptr, void *arena_ptr, const uint32_t *ranges, uint32_t range_count,
    uint32_t max_length, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || ranges == NULL || range_count == 0u) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        id<MTLBuffer> range_buffer = [runtime.device newBufferWithBytes:ranges length:(NSUInteger)range_count * 2u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        if (range_buffer == nil) { write_error(error_message, error_message_len, @"Metal range upload failed"); return false; }
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.clearArenaRanges];
        [encoder setBuffer:arena offset:0 atIndex:0]; [encoder setBuffer:range_buffer offset:0 atIndex:1];
        [encoder setBytes:&range_count length:sizeof(range_count) atIndex:2]; [encoder setBytes:&max_length length:sizeof(max_length) atIndex:3];
        NSUInteger width = MIN(runtime.clearArenaRanges.maxTotalThreadsPerThreadgroup, runtime.clearArenaRanges.threadExecutionWidth * 8u);
        [encoder dispatchThreads:MTLSizeMake(max_length, range_count, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        return true;
    }
}

void *stwo_zig_metal_arena_copy_prepare(
    void *runtime_ptr, const uint32_t *ranges, uint32_t range_count,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || ranges == NULL || range_count == 0u) return NULL;
    @autoreleasepool {
        StwoZigArenaCopyPlan *plan = [StwoZigArenaCopyPlan new];
        plan.ranges = [NSData dataWithBytes:ranges length:(NSUInteger)range_count * 3u * sizeof(uint32_t)];
        plan.rangeCount = range_count;
        if (plan.ranges == nil) {
            write_error(error_message, error_message_len, @"Metal arena copy plan allocation failed");
            return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_arena_copy_plan_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

bool stwo_zig_metal_arena_copy_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigArenaCopyPlan *plan = (__bridge StwoZigArenaCopyPlan *)plan_ptr;
        const uint32_t *ranges = plan.ranges.bytes;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        for (uint32_t index = 0; index < plan.rangeCount; ++index) {
            NSUInteger source = (NSUInteger)ranges[index * 3u] * sizeof(uint32_t);
            NSUInteger destination = (NSUInteger)ranges[index * 3u + 1u] * sizeof(uint32_t);
            NSUInteger bytes = (NSUInteger)ranges[index * 3u + 2u] * sizeof(uint32_t);
            if (bytes == 0u || source + bytes > arena.length || destination + bytes > arena.length) {
                [blit endEncoding];
                write_error(error_message, error_message_len, @"Metal arena copy range exceeds arena");
                return false;
            }
            [blit copyFromBuffer:arena sourceOffset:source toBuffer:arena destinationOffset:destination size:bytes];
        }
        [blit endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len, command.error.localizedDescription);
            return false;
        }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_witness_feed_prepare(
    void *runtime_ptr,
    const uint32_t *descriptors, uint32_t descriptor_count,
    const uint32_t *luts, size_t lut_words,
    const uint32_t *destination_offsets, size_t destination_count,
    const uint32_t *source_offsets, size_t source_count,
    const uint32_t *clear_ranges, uint32_t clear_range_count, uint32_t clear_max_length,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || descriptors == NULL || descriptor_count == 0u || destination_offsets == NULL || destination_count == 0u || source_offsets == NULL || source_count == 0u || clear_ranges == NULL || clear_range_count == 0u || clear_max_length == 0u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigWitnessFeedPlan *plan = [StwoZigWitnessFeedPlan new];
        plan.descriptorCount = descriptor_count;
        plan.clearRangeCount = clear_range_count;
        (void)clear_max_length;
        plan.descriptors = [runtime.device newBufferWithBytes:descriptors length:(NSUInteger)descriptor_count * 14u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        uint32_t zero = 0u;
        plan.luts = [runtime.device newBufferWithBytes:(lut_words == 0u ? &zero : luts) length:MAX((size_t)1u, lut_words) * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.destinationOffsets = [runtime.device newBufferWithBytes:destination_offsets length:destination_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.sourceOffsets = [runtime.device newBufferWithBytes:source_offsets length:source_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        uint32_t *spans = calloc((size_t)clear_range_count * 3u, sizeof(uint32_t));
        if (spans == NULL) { write_error(error_message, error_message_len, @"Metal witness clear plan allocation failed"); return NULL; }
        uint64_t total_words = 0u;
        for (uint32_t i = 0; i < clear_range_count; ++i) {
            if (total_words > UINT32_MAX) { free(spans); write_error(error_message, error_message_len, @"Metal witness clear plan is too large"); return NULL; }
            spans[i * 3u] = clear_ranges[i * 2u];
            spans[i * 3u + 1u] = clear_ranges[i * 2u + 1u];
            spans[i * 3u + 2u] = (uint32_t)total_words;
            total_words += clear_ranges[i * 2u + 1u];
        }
        if (total_words == 0u || total_words > UINT32_MAX) { free(spans); write_error(error_message, error_message_len, @"Metal witness clear plan is too large"); return NULL; }
        plan.clearTotalWords = (uint32_t)total_words;
        plan.clearRanges = [runtime.device newBufferWithBytes:spans length:(NSUInteger)clear_range_count * 3u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        free(spans);
        if (plan.descriptors == nil || plan.luts == nil || plan.destinationOffsets == nil || plan.sourceOffsets == nil || plan.clearRanges == nil) { write_error(error_message, error_message_len, @"Metal witness feed upload failed"); return NULL; }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_witness_feed_plan_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

void *stwo_zig_metal_witness_feed_batch_prepare(
    void *runtime_ptr, void *const *plan_ptrs, const uint32_t *column_lengths, uint32_t plan_count,
    const uint32_t *clear_ranges, uint32_t clear_range_count,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || plan_ptrs == NULL || column_lengths == NULL || plan_count == 0u || clear_ranges == NULL || clear_range_count == 0u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        NSMutableArray<StwoZigWitnessFeedPlan *> *plans = [NSMutableArray arrayWithCapacity:plan_count];
        for (uint32_t i = 0; i < plan_count; ++i) {
            if (plan_ptrs[i] == NULL || column_lengths[i] == 0u) return NULL;
            [plans addObject:(__bridge StwoZigWitnessFeedPlan *)plan_ptrs[i]];
        }
        uint32_t *spans = calloc((size_t)clear_range_count * 3u, sizeof(uint32_t));
        if (spans == NULL) return NULL;
        uint64_t total_words = 0u;
        for (uint32_t i = 0; i < clear_range_count; ++i) {
            if (total_words > UINT32_MAX) { free(spans); return NULL; }
            spans[i * 3u] = clear_ranges[i * 2u];
            spans[i * 3u + 1u] = clear_ranges[i * 2u + 1u];
            spans[i * 3u + 2u] = (uint32_t)total_words;
            total_words += clear_ranges[i * 2u + 1u];
        }
        if (total_words == 0u || total_words > UINT32_MAX) { free(spans); return NULL; }
        StwoZigWitnessFeedBatch *batch = [StwoZigWitnessFeedBatch new];
        batch.plans = plans;
        batch.columnLengths = [NSData dataWithBytes:column_lengths length:(NSUInteger)plan_count * sizeof(uint32_t)];
        batch.clearRangeCount = clear_range_count;
        batch.clearTotalWords = (uint32_t)total_words;
        batch.clearSpans = [runtime.device newBufferWithBytes:spans length:(NSUInteger)clear_range_count * 3u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        free(spans);
        if (batch.clearSpans == nil) { write_error(error_message, error_message_len, @"Metal witness batch upload failed"); return NULL; }
        return (__bridge_retained void *)batch;
    }
}

void stwo_zig_metal_witness_feed_batch_destroy(void *batch_ptr) {
    if (batch_ptr != NULL) CFRelease(batch_ptr);
}

bool stwo_zig_metal_witness_feed_batch_counts_prepared(
    void *runtime_ptr, void *arena_ptr, void *batch_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || batch_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigWitnessFeedBatch *batch = (__bridge StwoZigWitnessFeedBatch *)batch_ptr;
        const uint32_t *column_lengths = batch.columnLengths.bytes;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        uint32_t clear_range_count = batch.clearRangeCount, clear_total_words = batch.clearTotalWords;
        [encoder setComputePipelineState:runtime.clearArenaSpans];
        [encoder setBuffer:arena offset:0 atIndex:0]; [encoder setBuffer:batch.clearSpans offset:0 atIndex:1];
        [encoder setBytes:&clear_range_count length:sizeof(clear_range_count) atIndex:2]; [encoder setBytes:&clear_total_words length:sizeof(clear_total_words) atIndex:3];
        NSUInteger clear_width = MIN(runtime.clearArenaSpans.maxTotalThreadsPerThreadgroup, runtime.clearArenaSpans.threadExecutionWidth * 8u);
        [encoder dispatchThreads:MTLSizeMake(clear_total_words, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(clear_width, 1u, 1u)];
        [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];
        [encoder setComputePipelineState:runtime.witnessFeedCounts];
        for (NSUInteger i = 0; i < batch.plans.count; ++i) {
            StwoZigWitnessFeedPlan *plan = batch.plans[i];
            uint32_t descriptor_count = plan.descriptorCount, column_length = column_lengths[i];
            [encoder setBuffer:arena offset:0 atIndex:0]; [encoder setBuffer:plan.descriptors offset:0 atIndex:1]; [encoder setBuffer:plan.luts offset:0 atIndex:2];
            [encoder setBuffer:plan.destinationOffsets offset:0 atIndex:3]; [encoder setBuffer:plan.sourceOffsets offset:0 atIndex:4];
            [encoder setBytes:&column_length length:sizeof(column_length) atIndex:5]; [encoder setBytes:&descriptor_count length:sizeof(descriptor_count) atIndex:6];
            NSUInteger width = MIN(runtime.witnessFeedCounts.maxTotalThreadsPerThreadgroup, runtime.witnessFeedCounts.threadExecutionWidth * 8u);
            [encoder dispatchThreads:MTLSizeMake(column_length, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        }
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_circle_lde_prepare(
    void *runtime_ptr, const uint32_t *source_offsets, const uint32_t *destination_offsets,
    uint32_t column_count, uint32_t base_log_size, uint32_t extended_log_size,
    uint32_t twiddle_offset_words, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || source_offsets == NULL || destination_offsets == NULL || column_count == 0u ||
        base_log_size < 3u || extended_log_size <= base_log_size || extended_log_size >= 31u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigCircleLdePlan *plan = [StwoZigCircleLdePlan new];
        plan.sourceOffsets = [runtime.device newBufferWithBytes:source_offsets length:(NSUInteger)column_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.destinationOffsets = [runtime.device newBufferWithBytes:destination_offsets length:(NSUInteger)column_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.columnCount = column_count;
        plan.baseLogSize = base_log_size;
        plan.extendedLogSize = extended_log_size;
        plan.twiddleByteOffset = (NSUInteger)twiddle_offset_words * sizeof(uint32_t);
        if (plan.sourceOffsets == nil || plan.destinationOffsets == nil) {
            write_error(error_message, error_message_len, @"Metal sparse circle LDE plan allocation failed");
            return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_circle_lde_plan_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

bool stwo_zig_metal_circle_lde_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigCircleLdePlan *plan = (__bridge StwoZigCircleLdePlan *)plan_ptr;
        uint32_t column_count = plan.columnCount, base_log_size = plan.baseLogSize, extended_log_size = plan.extendedLogSize;
        uint32_t extended_len = 1u << extended_log_size, extended_pairs = extended_len >> 1u;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> expand = [command computeCommandEncoder];
        [expand setComputePipelineState:runtime.circleExpandSparse];
        [expand setBuffer:arena offset:0 atIndex:0]; [expand setBuffer:plan.sourceOffsets offset:0 atIndex:1];
        [expand setBuffer:plan.destinationOffsets offset:0 atIndex:2]; [expand setBytes:&base_log_size length:sizeof(base_log_size) atIndex:3];
        [expand setBytes:&extended_log_size length:sizeof(extended_log_size) atIndex:4]; [expand setBytes:&column_count length:sizeof(column_count) atIndex:5];
        NSUInteger expand_width = MIN((NSUInteger)256u, runtime.circleExpandSparse.maxTotalThreadsPerThreadgroup);
        [expand dispatchThreads:MTLSizeMake(extended_len, column_count, 1u) threadsPerThreadgroup:MTLSizeMake(expand_width, 1u, 1u)];
        [expand endEncoding];
        MTLSize grid = MTLSizeMake(extended_pairs, column_count, 1u);
        for (uint32_t layer = extended_log_size - 1u; layer > 0u; --layer) {
            uint32_t twiddle_offset = extended_pairs - (1u << (extended_log_size - layer));
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:runtime.circleRfftLayerSparse];
            [encoder setBuffer:arena offset:0 atIndex:0]; [encoder setBuffer:plan.destinationOffsets offset:0 atIndex:1];
            [encoder setBuffer:arena offset:plan.twiddleByteOffset atIndex:2]; [encoder setBytes:&extended_log_size length:sizeof(extended_log_size) atIndex:3];
            [encoder setBytes:&layer length:sizeof(layer) atIndex:4]; [encoder setBytes:&twiddle_offset length:sizeof(twiddle_offset) atIndex:5];
            [encoder setBytes:&column_count length:sizeof(column_count) atIndex:6];
            NSUInteger width = MIN((NSUInteger)256u, runtime.circleRfftLayerSparse.maxTotalThreadsPerThreadgroup);
            [encoder dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
            [encoder endEncoding];
        }
        id<MTLComputeCommandEncoder> last = [command computeCommandEncoder];
        [last setComputePipelineState:runtime.circleRfftLastSparse];
        [last setBuffer:arena offset:0 atIndex:0]; [last setBuffer:plan.destinationOffsets offset:0 atIndex:1];
        [last setBuffer:arena offset:plan.twiddleByteOffset atIndex:2]; [last setBytes:&extended_log_size length:sizeof(extended_log_size) atIndex:3];
        [last setBytes:&column_count length:sizeof(column_count) atIndex:4];
        NSUInteger last_width = MIN((NSUInteger)256u, runtime.circleRfftLastSparse.maxTotalThreadsPerThreadgroup);
        [last dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(last_width, 1u, 1u)];
        [last endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_circle_ifft_prepare(
    void *runtime_ptr, const uint32_t *source_offsets, const uint32_t *destination_offsets,
    uint32_t column_count, uint32_t log_size, uint32_t twiddle_offset_words,
    uint32_t scale_factor, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || source_offsets == NULL || destination_offsets == NULL ||
        column_count == 0u || log_size < 3u || log_size >= 31u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigCircleIfftPlan *plan = [StwoZigCircleIfftPlan new];
        plan.sourceOffsets = [runtime.device newBufferWithBytes:source_offsets length:(NSUInteger)column_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.destinationOffsets = [runtime.device newBufferWithBytes:destination_offsets length:(NSUInteger)column_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.columnCount = column_count; plan.logSize = log_size; plan.scaleFactor = scale_factor;
        plan.twiddleByteOffset = (NSUInteger)twiddle_offset_words * sizeof(uint32_t);
        if (plan.sourceOffsets == nil || plan.destinationOffsets == nil) {
            write_error(error_message, error_message_len, @"Metal sparse circle IFFT plan allocation failed");
            return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_circle_ifft_plan_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

bool stwo_zig_metal_circle_ifft_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigCircleIfftPlan *plan = (__bridge StwoZigCircleIfftPlan *)plan_ptr;
        uint32_t column_count = plan.columnCount, log_size = plan.logSize;
        uint32_t length = 1u << log_size, pair_count = length >> 1u;
        MTLSize values_grid = MTLSizeMake(length, column_count, 1u);
        MTLSize pairs_grid = MTLSizeMake(pair_count, column_count, 1u);
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];

        id<MTLComputeCommandEncoder> copy = [command computeCommandEncoder];
        [copy setComputePipelineState:runtime.circleCopySparse];
        [copy setBuffer:arena offset:0 atIndex:0]; [copy setBuffer:plan.sourceOffsets offset:0 atIndex:1];
        [copy setBuffer:plan.destinationOffsets offset:0 atIndex:2]; [copy setBytes:&log_size length:sizeof(log_size) atIndex:3];
        [copy setBytes:&column_count length:sizeof(column_count) atIndex:4];
        NSUInteger copy_width = MIN((NSUInteger)256u, runtime.circleCopySparse.maxTotalThreadsPerThreadgroup);
        [copy dispatchThreads:values_grid threadsPerThreadgroup:MTLSizeMake(copy_width, 1u, 1u)];
        [copy endEncoding];

        id<MTLComputeCommandEncoder> first = [command computeCommandEncoder];
        [first setComputePipelineState:runtime.circleIfftFirstSparse];
        [first setBuffer:arena offset:0 atIndex:0]; [first setBuffer:plan.destinationOffsets offset:0 atIndex:1];
        [first setBuffer:arena offset:plan.twiddleByteOffset atIndex:2]; [first setBytes:&log_size length:sizeof(log_size) atIndex:3];
        [first setBytes:&column_count length:sizeof(column_count) atIndex:4];
        NSUInteger first_width = MIN((NSUInteger)256u, runtime.circleIfftFirstSparse.maxTotalThreadsPerThreadgroup);
        [first dispatchThreads:pairs_grid threadsPerThreadgroup:MTLSizeMake(first_width, 1u, 1u)];
        [first endEncoding];

        for (uint32_t layer = 1u; layer < log_size; ++layer) {
            uint32_t twiddle_offset = pair_count - (1u << (log_size - layer));
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:runtime.circleIfftLayerSparse];
            [encoder setBuffer:arena offset:0 atIndex:0]; [encoder setBuffer:plan.destinationOffsets offset:0 atIndex:1];
            [encoder setBuffer:arena offset:plan.twiddleByteOffset atIndex:2]; [encoder setBytes:&log_size length:sizeof(log_size) atIndex:3];
            [encoder setBytes:&layer length:sizeof(layer) atIndex:4]; [encoder setBytes:&twiddle_offset length:sizeof(twiddle_offset) atIndex:5];
            [encoder setBytes:&column_count length:sizeof(column_count) atIndex:6];
            NSUInteger width = MIN((NSUInteger)256u, runtime.circleIfftLayerSparse.maxTotalThreadsPerThreadgroup);
            [encoder dispatchThreads:pairs_grid threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
            [encoder endEncoding];
        }

        uint32_t scale_factor = plan.scaleFactor;
        id<MTLComputeCommandEncoder> rescale = [command computeCommandEncoder];
        [rescale setComputePipelineState:runtime.circleRescaleSparse];
        [rescale setBuffer:arena offset:0 atIndex:0]; [rescale setBuffer:plan.destinationOffsets offset:0 atIndex:1];
        [rescale setBytes:&log_size length:sizeof(log_size) atIndex:2]; [rescale setBytes:&column_count length:sizeof(column_count) atIndex:3];
        [rescale setBytes:&scale_factor length:sizeof(scale_factor) atIndex:4];
        NSUInteger rescale_width = MIN((NSUInteger)256u, runtime.circleRescaleSparse.maxTotalThreadsPerThreadgroup);
        [rescale dispatchThreads:values_grid threadsPerThreadgroup:MTLSizeMake(rescale_width, 1u, 1u)];
        [rescale endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_fixed_table_prepare(
    void *runtime_ptr, const uint32_t *descriptors, uint32_t descriptor_words,
    const uint32_t *source_offsets, uint32_t source_count,
    const uint32_t *multiplicity_offsets, uint32_t multiplicity_count,
    uint32_t destination_offset, uint32_t row_count,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || descriptors == NULL || descriptor_words == 0u || descriptor_words % 4u != 0u ||
        multiplicity_offsets == NULL || multiplicity_count == 0u || row_count == 0u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigFixedTablePlan *plan = [StwoZigFixedTablePlan new];
        uint32_t zero = 0u;
        plan.descriptors = [runtime.device newBufferWithBytes:descriptors length:(NSUInteger)descriptor_words * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.sourceOffsets = [runtime.device newBufferWithBytes:source_count == 0u ? &zero : source_offsets length:(NSUInteger)MAX(source_count, 1u) * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.multiplicityOffsets = [runtime.device newBufferWithBytes:multiplicity_offsets length:(NSUInteger)multiplicity_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.destinationOffset = destination_offset; plan.rowCount = row_count; plan.outputCount = descriptor_words / 4u;
        if (plan.descriptors == nil || plan.sourceOffsets == nil || plan.multiplicityOffsets == nil) {
            write_error(error_message, error_message_len, @"Metal fixed-table plan allocation failed"); return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_fixed_table_plan_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

void *stwo_zig_metal_fixed_table_batch_prepare(
    void *runtime_ptr, void *const *plan_ptrs, uint32_t plan_count,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || plan_ptrs == NULL || plan_count == 0u) return NULL;
    @autoreleasepool {
        NSMutableArray<StwoZigFixedTablePlan *> *plans = [NSMutableArray arrayWithCapacity:plan_count];
        for (uint32_t i = 0; i < plan_count; ++i) {
            if (plan_ptrs[i] == NULL) { write_error(error_message, error_message_len, @"Null fixed-table plan"); return NULL; }
            [plans addObject:(__bridge StwoZigFixedTablePlan *)plan_ptrs[i]];
        }
        StwoZigFixedTableBatch *batch = [StwoZigFixedTableBatch new]; batch.plans = plans;
        return (__bridge_retained void *)batch;
    }
}

void stwo_zig_metal_fixed_table_batch_destroy(void *batch_ptr) {
    if (batch_ptr != NULL) CFRelease(batch_ptr);
}

bool stwo_zig_metal_fixed_table_batch_prepared(
    void *runtime_ptr, void *arena_ptr, void *batch_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || batch_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigFixedTableBatch *batch = (__bridge StwoZigFixedTableBatch *)batch_ptr;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.fixedTableLookup]; [encoder setBuffer:arena offset:0 atIndex:0];
        NSUInteger width = MIN((NSUInteger)256u, runtime.fixedTableLookup.maxTotalThreadsPerThreadgroup);
        for (StwoZigFixedTablePlan *plan in batch.plans) {
            uint32_t destination = plan.destinationOffset, rows = plan.rowCount, outputs = plan.outputCount;
            [encoder setBuffer:plan.descriptors offset:0 atIndex:1]; [encoder setBuffer:plan.sourceOffsets offset:0 atIndex:2];
            [encoder setBuffer:plan.multiplicityOffsets offset:0 atIndex:3]; [encoder setBytes:&destination length:sizeof(destination) atIndex:4];
            [encoder setBytes:&rows length:sizeof(rows) atIndex:5]; [encoder setBytes:&outputs length:sizeof(outputs) atIndex:6];
            [encoder dispatchThreads:MTLSizeMake((NSUInteger)rows * outputs, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        }
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_merkle_leaf_prepare(
    void *runtime_ptr, const uint32_t *column_offsets, const uint32_t *column_log_sizes,
    uint32_t column_count, uint32_t lifting_log_size, uint32_t destination_offset,
    const uint32_t *leaf_seed, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || column_offsets == NULL || column_log_sizes == NULL || column_count == 0u ||
        lifting_log_size >= 31u || (destination_offset & 63u) != 0u || leaf_seed == NULL) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        for (uint32_t column = 0; column < column_count; ++column) if (column_log_sizes[column] > lifting_log_size) return NULL;
        StwoZigMerkleLeafPlan *plan = [StwoZigMerkleLeafPlan new];
        plan.columnOffsets = [runtime.device newBufferWithBytes:column_offsets length:column_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.columnLogSizes = [runtime.device newBufferWithBytes:column_log_sizes length:column_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.leafSeed = [runtime.device newBufferWithBytes:leaf_seed length:8u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.columnCount = column_count; plan.liftingLogSize = lifting_log_size; plan.destinationOffset = destination_offset;
        if (plan.columnOffsets == nil || plan.columnLogSizes == nil || plan.leafSeed == nil) {
            write_error(error_message, error_message_len, @"Metal Merkle leaf plan allocation failed"); return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_merkle_leaf_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

bool stwo_zig_metal_merkle_leaf_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigMerkleLeafPlan *plan = (__bridge StwoZigMerkleLeafPlan *)plan_ptr;
        uint32_t leaf_count = 1u << plan.liftingLogSize;
        uint32_t column_count = plan.columnCount, lifting_log_size = plan.liftingLogSize;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.leaves]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBuffer:plan.columnOffsets offset:0 atIndex:1]; [encoder setBuffer:plan.columnLogSizes offset:0 atIndex:2];
        [encoder setBuffer:arena offset:(NSUInteger)plan.destinationOffset * sizeof(uint32_t) atIndex:3];
        [encoder setBytes:&column_count length:sizeof(column_count) atIndex:4];
        [encoder setBytes:&lifting_log_size length:sizeof(lifting_log_size) atIndex:5]; [encoder setBuffer:plan.leafSeed offset:0 atIndex:6];
        NSUInteger width = MIN((NSUInteger)256u, runtime.leaves.maxTotalThreadsPerThreadgroup);
        [encoder dispatchThreads:MTLSizeMake(leaf_count, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len, command.error.localizedDescription); return false;
        }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_resident_merkle_prepare(
    void *runtime_ptr, const uint32_t *column_offsets, const uint32_t *column_log_sizes,
    uint32_t column_count, uint32_t lifting_log_size, const uint32_t *layer_offsets,
    uint32_t layer_count, const uint32_t *leaf_seed, const uint32_t *node_seed,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || column_offsets == NULL || column_log_sizes == NULL || column_count == 0u ||
        lifting_log_size >= 31u || layer_offsets == NULL || layer_count < 2u ||
        layer_count > lifting_log_size + 1u || leaf_seed == NULL || node_seed == NULL) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        for (uint32_t column = 0; column < column_count; ++column) {
            if (column_log_sizes[column] > lifting_log_size ||
                (column != 0u && column_log_sizes[column - 1u] > column_log_sizes[column])) return NULL;
        }
        for (uint32_t layer = 0; layer < layer_count; ++layer) if ((layer_offsets[layer] & 63u) != 0u) return NULL;
        StwoZigResidentMerklePlan *plan = [StwoZigResidentMerklePlan new];
        plan.columnOffsets = [runtime.device newBufferWithBytes:column_offsets length:column_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.columnLogSizes = [runtime.device newBufferWithBytes:column_log_sizes length:column_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.layerOffsets = [NSData dataWithBytes:layer_offsets length:layer_count * sizeof(uint32_t)];
        plan.leafSeed = [runtime.device newBufferWithBytes:leaf_seed length:8u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.nodeSeed = [runtime.device newBufferWithBytes:node_seed length:8u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.columnCount = column_count; plan.liftingLogSize = lifting_log_size; plan.layerCount = layer_count;
        if (plan.columnOffsets == nil || plan.columnLogSizes == nil || plan.layerOffsets == nil ||
            plan.leafSeed == nil || plan.nodeSeed == nil) {
            write_error(error_message, error_message_len, @"Resident Merkle plan allocation failed"); return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_resident_merkle_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

bool stwo_zig_metal_resident_merkle_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigResidentMerklePlan *plan = (__bridge StwoZigResidentMerklePlan *)plan_ptr;
        const uint32_t *layers = plan.layerOffsets.bytes;
        uint32_t leaf_count = 1u << plan.liftingLogSize;
        uint32_t column_count = plan.columnCount, lifting_log_size = plan.liftingLogSize;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> leaves = [command computeCommandEncoder];
        [leaves setComputePipelineState:runtime.leaves]; [leaves setBuffer:arena offset:0 atIndex:0];
        [leaves setBuffer:plan.columnOffsets offset:0 atIndex:1]; [leaves setBuffer:plan.columnLogSizes offset:0 atIndex:2];
        [leaves setBuffer:arena offset:(NSUInteger)layers[0] * sizeof(uint32_t) atIndex:3];
        [leaves setBytes:&column_count length:sizeof(column_count) atIndex:4];
        [leaves setBytes:&lifting_log_size length:sizeof(lifting_log_size) atIndex:5]; [leaves setBuffer:plan.leafSeed offset:0 atIndex:6];
        NSUInteger leaf_width = MIN((NSUInteger)256u, runtime.leaves.maxTotalThreadsPerThreadgroup);
        [leaves dispatchThreads:MTLSizeMake(leaf_count, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(leaf_width, 1u, 1u)];
        [leaves endEncoding];
        for (uint32_t level = 1u; level < plan.layerCount; ++level) {
            uint32_t child = layers[level - 1u], destination = layers[level], parent_count = leaf_count >> level;
            id<MTLComputeCommandEncoder> parents = [command computeCommandEncoder];
            [parents setComputePipelineState:runtime.parentsSparse]; [parents setBuffer:arena offset:0 atIndex:0];
            [parents setBytes:&child length:sizeof(child) atIndex:1]; [parents setBytes:&destination length:sizeof(destination) atIndex:2];
            [parents setBytes:&parent_count length:sizeof(parent_count) atIndex:3]; [parents setBuffer:plan.nodeSeed offset:0 atIndex:4];
            NSUInteger width = MIN((NSUInteger)256u, runtime.parentsSparse.maxTotalThreadsPerThreadgroup);
            [parents dispatchThreads:MTLSizeMake(parent_count, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
            [parents endEncoding];
        }
        [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len, command.error.localizedDescription); return false;
        }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_merkle_parent_chain_prepare(
    void *runtime_ptr, const uint32_t *child_offsets, const uint32_t *destination_offsets,
    const uint32_t *parent_counts, uint32_t level_count, const uint32_t *node_seed,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || child_offsets == NULL || destination_offsets == NULL ||
        parent_counts == NULL || level_count == 0u || node_seed == NULL) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        for (uint32_t level = 0; level < level_count; ++level) if (parent_counts[level] == 0u) return NULL;
        StwoZigMerkleParentChain *plan = [StwoZigMerkleParentChain new];
        plan.childOffsets = [NSData dataWithBytes:child_offsets length:(NSUInteger)level_count * sizeof(uint32_t)];
        plan.destinationOffsets = [NSData dataWithBytes:destination_offsets length:(NSUInteger)level_count * sizeof(uint32_t)];
        plan.parentCounts = [NSData dataWithBytes:parent_counts length:(NSUInteger)level_count * sizeof(uint32_t)];
        plan.nodeSeed = [runtime.device newBufferWithBytes:node_seed length:8u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.levelCount = level_count;
        if (plan.nodeSeed == nil) { write_error(error_message, error_message_len, @"Metal Merkle parent-chain allocation failed"); return NULL; }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_merkle_parent_chain_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

bool stwo_zig_metal_merkle_parent_chain_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigMerkleParentChain *plan = (__bridge StwoZigMerkleParentChain *)plan_ptr;
        const uint32_t *children = plan.childOffsets.bytes, *destinations = plan.destinationOffsets.bytes, *counts = plan.parentCounts.bytes;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        NSUInteger width = MIN((NSUInteger)256u, runtime.parentsSparse.maxTotalThreadsPerThreadgroup);
        for (uint32_t level = 0; level < plan.levelCount; ++level) {
            uint32_t child = children[level], destination = destinations[level], count = counts[level];
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:runtime.parentsSparse]; [encoder setBuffer:arena offset:0 atIndex:0];
            [encoder setBytes:&child length:sizeof(child) atIndex:1]; [encoder setBytes:&destination length:sizeof(destination) atIndex:2];
            [encoder setBytes:&count length:sizeof(count) atIndex:3]; [encoder setBuffer:plan.nodeSeed offset:0 atIndex:4];
            [encoder dispatchThreads:MTLSizeMake(count, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
            [encoder endEncoding];
        }
        [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_ec_op_prepare(
    void *runtime_ptr, const uint32_t *execution_offsets, const uint32_t *trace_offsets,
    const uint32_t *partial_offsets, const uint32_t *multiplicity_offsets,
    uint32_t lookup_offset, uint32_t segment_offset, uint32_t scratch_offset, uint32_t row_count,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || execution_offsets == NULL || trace_offsets == NULL || partial_offsets == NULL ||
        multiplicity_offsets == NULL || row_count < 16u || (row_count & (row_count - 1u)) != 0u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigEcOpPlan *plan = [StwoZigEcOpPlan new];
        uint32_t params[4] = { lookup_offset, segment_offset, scratch_offset, row_count };
        plan.executionOffsets = [runtime.device newBufferWithBytes:execution_offsets length:37u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.traceOffsets = [runtime.device newBufferWithBytes:trace_offsets length:273u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.partialOffsets = [runtime.device newBufferWithBytes:partial_offsets length:127u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.multiplicityOffsets = [runtime.device newBufferWithBytes:multiplicity_offsets length:4u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.params = [runtime.device newBufferWithBytes:params length:sizeof(params) options:MTLResourceStorageModeShared];
        plan.rowCount = row_count;
        if (plan.executionOffsets == nil || plan.traceOffsets == nil || plan.partialOffsets == nil ||
            plan.multiplicityOffsets == nil || plan.params == nil) {
            write_error(error_message, error_message_len, @"Metal EC-op plan allocation failed"); return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_ec_op_plan_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

void *stwo_zig_metal_compact_prepare(
    void *runtime_ptr, const uint32_t *source_offsets, uint32_t source_count,
    const uint32_t *descriptors, uint32_t descriptor_words,
    const uint32_t *output_offsets, uint32_t output_count, const uint32_t *params,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || source_offsets == NULL || source_count == 0u || descriptors == NULL ||
        descriptor_words != source_count * 5u || output_offsets == NULL || output_count == 0u || params == NULL) return NULL;
    uint32_t total_rows = params[2], sort_rows = params[3], key_words = params[14], consumer_rows = params[16];
    if (params[0] != source_count || params[1] == 0u || key_words == 0u || key_words > params[1] ||
        total_rows == 0u || sort_rows < total_rows || sort_rows < 16u || (sort_rows & (sort_rows - 1u)) != 0u ||
        consumer_rows < 16u || (consumer_rows & (consumer_rows - 1u)) != 0u || params[15] != output_count) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigCompactPlan *plan = [StwoZigCompactPlan new];
        plan.sourceOffsets = [runtime.device newBufferWithBytes:source_offsets length:source_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.descriptors = [runtime.device newBufferWithBytes:descriptors length:descriptor_words * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.outputOffsets = [runtime.device newBufferWithBytes:output_offsets length:output_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.params = [runtime.device newBufferWithBytes:params length:21u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.sortRows = sort_rows; plan.totalRows = total_rows; plan.consumerRows = consumer_rows;
        plan.keyWords = key_words; plan.indicesA = params[5]; plan.indicesB = params[6];
        if (plan.sourceOffsets == nil || plan.descriptors == nil || plan.outputOffsets == nil || plan.params == nil) {
            write_error(error_message, error_message_len, @"Metal compact plan allocation failed"); return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_compact_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

void *stwo_zig_metal_eval_prepare(
    void *runtime_ptr, const char *source_bytes, size_t source_len,
    const char *name_bytes, size_t name_len, const uint32_t *arguments,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || source_bytes == NULL || source_len == 0u ||
        name_bytes == NULL || name_len == 0u || arguments == NULL || arguments[10] == 0u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        NSString *source = [[NSString alloc] initWithBytes:source_bytes length:source_len encoding:NSUTF8StringEncoding];
        NSString *name = [[NSString alloc] initWithBytes:name_bytes length:name_len encoding:NSUTF8StringEncoding];
        if (source == nil || name == nil) {
            write_error(error_message, error_message_len, @"Invalid Metal evaluation source encoding"); return NULL;
        }
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.mathMode = MTLMathModeSafe;
        NSError *error = nil;
        id<MTLLibrary> library = [runtime.device newLibraryWithSource:source options:options error:&error];
        if (library == nil) {
            write_error(error_message, error_message_len,
                        error.localizedDescription ?: @"Failed to compile Metal evaluation program");
            return NULL;
        }
        id<MTLComputePipelineState> pipeline = make_pipeline(runtime.device, library, name, error_message, error_message_len);
        if (pipeline == nil) return NULL;
        StwoZigEvalPlan *plan = [StwoZigEvalPlan new];
        plan.pipeline = pipeline;
        plan.arguments = [runtime.device newBufferWithBytes:arguments length:14u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.rowCount = arguments[10];
        if (plan.arguments == nil) {
            write_error(error_message, error_message_len, @"Metal evaluation argument allocation failed"); return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void *stwo_zig_metal_eval_library_load(
    void *runtime_ptr, const char *path_bytes, size_t path_len,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || path_bytes == NULL || path_len == 0u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        NSString *path = [[NSString alloc] initWithBytes:path_bytes length:path_len encoding:NSUTF8StringEncoding];
        if (path == nil) { write_error(error_message, error_message_len, @"Invalid metallib path encoding"); return NULL; }
        NSError *error = nil;
        id<MTLLibrary> library = [runtime.device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error];
        if (library == nil) {
            write_error(error_message, error_message_len, error.localizedDescription ?: @"Failed to load Metal evaluation library");
            return NULL;
        }
        StwoZigEvalLibrary *result = [StwoZigEvalLibrary new];
        result.library = library;
        NSString *archivePath = [path stringByAppendingString:@".binarchive"];
        result.archiveURL = [NSURL fileURLWithPath:archivePath];
        MTLBinaryArchiveDescriptor *archiveDescriptor = [MTLBinaryArchiveDescriptor new];
        if ([[NSFileManager defaultManager] fileExistsAtPath:archivePath]) archiveDescriptor.url = result.archiveURL;
        result.archive = [runtime.device newBinaryArchiveWithDescriptor:archiveDescriptor error:&error];
        if (result.archive == nil) {
            write_error(error_message, error_message_len, error.localizedDescription ?: @"Failed to load Metal binary archive");
            return NULL;
        }
        return (__bridge_retained void *)result;
    }
}

void stwo_zig_metal_eval_library_destroy(void *library_ptr) {
    if (library_ptr != NULL) CFRelease(library_ptr);
}

void *stwo_zig_metal_witness_prepare_library(
    void *runtime_ptr, void *library_ptr, const char *name_bytes, size_t name_len,
    const uint32_t *arguments, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || library_ptr == NULL || name_bytes == NULL || name_len == 0u ||
        arguments == NULL || arguments[7] == 0u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigEvalLibrary *library = (__bridge StwoZigEvalLibrary *)library_ptr;
        NSString *name = [[NSString alloc] initWithBytes:name_bytes length:name_len encoding:NSUTF8StringEncoding];
        if (name == nil) { write_error(error_message, error_message_len, @"Invalid Metal witness function encoding"); return NULL; }
        id<MTLFunction> function = [library.library newFunctionWithName:name];
        if (function == nil) { write_error(error_message, error_message_len, @"Missing Metal witness function"); return NULL; }
        MTLComputePipelineDescriptor *descriptor = [MTLComputePipelineDescriptor new];
        descriptor.computeFunction = function; descriptor.binaryArchives = @[library.archive];
        NSError *error = nil;
        if (![library.archive addComputePipelineFunctionsWithDescriptor:descriptor error:&error]) {
            write_error(error_message, error_message_len, error.localizedDescription ?: @"Failed to archive Metal witness pipeline"); return NULL;
        }
        id<MTLComputePipelineState> pipeline =
            [runtime.device newComputePipelineStateWithDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error];
        if (pipeline == nil) { write_error(error_message, error_message_len, error.localizedDescription ?: @"Failed to resolve Metal witness pipeline"); return NULL; }
        StwoZigWitnessPlan *plan = [StwoZigWitnessPlan new];
        plan.pipeline = pipeline;
        plan.arguments = [runtime.device newBufferWithBytes:arguments length:11u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.rowCount = arguments[7];
        if (plan.arguments == nil) { write_error(error_message, error_message_len, @"Metal witness argument allocation failed"); return NULL; }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_witness_plan_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

bool stwo_zig_metal_witness_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigWitnessPlan *plan = (__bridge StwoZigWitnessPlan *)plan_ptr;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:plan.pipeline]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBuffer:plan.arguments offset:0 atIndex:1];
        NSUInteger width = MIN((NSUInteger)256u, MIN((NSUInteger)plan.rowCount, plan.pipeline.maxTotalThreadsPerThreadgroup));
        [encoder dispatchThreads:MTLSizeMake(plan.rowCount, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_eval_prepare_library(
    void *runtime_ptr, void *library_ptr, const char *name_bytes, size_t name_len,
    const uint32_t *arguments, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || library_ptr == NULL || name_bytes == NULL || name_len == 0u ||
        arguments == NULL || arguments[10] == 0u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigEvalLibrary *library = (__bridge StwoZigEvalLibrary *)library_ptr;
        NSString *name = [[NSString alloc] initWithBytes:name_bytes length:name_len encoding:NSUTF8StringEncoding];
        if (name == nil) { write_error(error_message, error_message_len, @"Invalid Metal function encoding"); return NULL; }
        id<MTLFunction> function = [library.library newFunctionWithName:name];
        if (function == nil) { write_error(error_message, error_message_len, @"Missing Metal evaluation function"); return NULL; }
        MTLComputePipelineDescriptor *descriptor = [MTLComputePipelineDescriptor new];
        descriptor.computeFunction = function;
        descriptor.binaryArchives = @[library.archive];
        NSError *error = nil;
        if (![library.archive addComputePipelineFunctionsWithDescriptor:descriptor error:&error]) {
            write_error(error_message, error_message_len, error.localizedDescription ?: @"Failed to add Metal pipeline to archive"); return NULL;
        }
        id<MTLComputePipelineState> pipeline =
            [runtime.device newComputePipelineStateWithDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error];
        if (pipeline == nil) {
            write_error(error_message, error_message_len, error.localizedDescription ?: @"Failed to resolve Metal evaluation pipeline"); return NULL;
        }
        StwoZigEvalPlan *plan = [StwoZigEvalPlan new];
        plan.pipeline = pipeline;
        plan.arguments = [runtime.device newBufferWithBytes:arguments length:14u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.rowCount = arguments[10];
        if (plan.arguments == nil) { write_error(error_message, error_message_len, @"Metal evaluation argument allocation failed"); return NULL; }
        return (__bridge_retained void *)plan;
    }
}

bool stwo_zig_metal_eval_library_serialize(
    void *library_ptr, char *error_message, size_t error_message_len
) {
    if (library_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigEvalLibrary *library = (__bridge StwoZigEvalLibrary *)library_ptr;
        NSError *error = nil;
        if (![library.archive serializeToURL:library.archiveURL error:&error]) {
            write_error(error_message, error_message_len, error.localizedDescription ?: @"Failed to serialize Metal binary archive");
            return false;
        }
        return true;
    }
}

void stwo_zig_metal_eval_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

void *stwo_zig_metal_eval_batch_prepare(
    const void *const *plan_ptrs, uint32_t plan_count,
    char *error_message, size_t error_message_len
) {
    if (plan_ptrs == NULL || plan_count == 0u) return NULL;
    @autoreleasepool {
        NSMutableArray<StwoZigEvalPlan *> *plans = [NSMutableArray arrayWithCapacity:plan_count];
        for (uint32_t i = 0; i < plan_count; ++i) {
            if (plan_ptrs[i] == NULL) {
                write_error(error_message, error_message_len, @"Null Metal evaluation plan in batch"); return NULL;
            }
            [plans addObject:(__bridge StwoZigEvalPlan *)plan_ptrs[i]];
        }
        StwoZigEvalBatch *batch = [StwoZigEvalBatch new];
        batch.plans = plans;
        return (__bridge_retained void *)batch;
    }
}

void stwo_zig_metal_eval_batch_destroy(void *batch_ptr) {
    if (batch_ptr != NULL) CFRelease(batch_ptr);
}

bool stwo_zig_metal_eval_batch_prepared(
    void *runtime_ptr, void *arena_ptr, void *batch_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || batch_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigEvalBatch *batch = (__bridge StwoZigEvalBatch *)batch_ptr;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        for (StwoZigEvalPlan *plan in batch.plans) {
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:plan.pipeline];
            [encoder setBuffer:arena offset:0 atIndex:0];
            [encoder setBuffer:plan.arguments offset:0 atIndex:1];
            NSUInteger width = MIN((NSUInteger)256u, MIN((NSUInteger)plan.rowCount, plan.pipeline.maxTotalThreadsPerThreadgroup));
            [encoder dispatchThreads:MTLSizeMake(plan.rowCount, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
            [encoder endEncoding];
        }
        [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len, command.error.localizedDescription); return false;
        }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_composition_lde_prepare(
    void *runtime_ptr, const uint32_t *source_offsets, const uint32_t *source_logs,
    const uint32_t *destination_offsets, uint32_t column_count, uint32_t extended_log,
    uint32_t twiddle_offset_words, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || source_offsets == NULL || source_logs == NULL || destination_offsets == NULL ||
        column_count == 0u || extended_log < 3u || extended_log >= 31u) return NULL;
    for (uint32_t i = 0; i < column_count; ++i) if (source_logs[i] < 3u || source_logs[i] > extended_log) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigCompositionLdePlan *plan = [StwoZigCompositionLdePlan new];
        plan.sourceOffsets = [runtime.device newBufferWithBytes:source_offsets length:column_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.sourceLogs = [runtime.device newBufferWithBytes:source_logs length:column_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.destinationOffsets = [runtime.device newBufferWithBytes:destination_offsets length:column_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.columnCount = column_count; plan.extendedLog = extended_log;
        plan.twiddleByteOffset = (NSUInteger)twiddle_offset_words * sizeof(uint32_t);
        if (plan.sourceOffsets == nil || plan.sourceLogs == nil || plan.destinationOffsets == nil) {
            write_error(error_message, error_message_len, @"Metal composition LDE plan allocation failed"); return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_composition_lde_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

static void encode_composition_lde(
    StwoZigMetalRuntime *runtime, id<MTLBuffer> arena,
    StwoZigCompositionLdePlan *plan, id<MTLCommandBuffer> command
) {
    uint32_t log_size = plan.extendedLog, columns = plan.columnCount;
    uint32_t rows = 1u << log_size, pairs = rows >> 1u;
    id<MTLComputeCommandEncoder> expand = [command computeCommandEncoder];
    [expand setComputePipelineState:runtime.compositionExpand]; [expand setBuffer:arena offset:0 atIndex:0];
    [expand setBuffer:plan.sourceOffsets offset:0 atIndex:1]; [expand setBuffer:plan.sourceLogs offset:0 atIndex:2];
    [expand setBuffer:plan.destinationOffsets offset:0 atIndex:3]; [expand setBytes:&log_size length:sizeof(log_size) atIndex:4];
    [expand setBytes:&columns length:sizeof(columns) atIndex:5];
    [expand dispatchThreads:MTLSizeMake(rows, columns, 1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.compositionExpand.maxTotalThreadsPerThreadgroup), 1u, 1u)];
    [expand endEncoding];
    MTLSize grid = MTLSizeMake(pairs, columns, 1u);
    for (uint32_t layer = log_size - 1u; layer > 0u; --layer) {
        uint32_t twiddle_offset = pairs - (1u << (log_size - layer));
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.circleRfftLayerSparse]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBuffer:plan.destinationOffsets offset:0 atIndex:1]; [encoder setBuffer:arena offset:plan.twiddleByteOffset atIndex:2];
        [encoder setBytes:&log_size length:sizeof(log_size) atIndex:3]; [encoder setBytes:&layer length:sizeof(layer) atIndex:4];
        [encoder setBytes:&twiddle_offset length:sizeof(twiddle_offset) atIndex:5]; [encoder setBytes:&columns length:sizeof(columns) atIndex:6];
        [encoder dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleRfftLayerSparse.maxTotalThreadsPerThreadgroup), 1u, 1u)];
        [encoder endEncoding];
    }
    id<MTLComputeCommandEncoder> last = [command computeCommandEncoder];
    [last setComputePipelineState:runtime.circleRfftLastSparse]; [last setBuffer:arena offset:0 atIndex:0];
    [last setBuffer:plan.destinationOffsets offset:0 atIndex:1]; [last setBuffer:arena offset:plan.twiddleByteOffset atIndex:2];
    [last setBytes:&log_size length:sizeof(log_size) atIndex:3]; [last setBytes:&columns length:sizeof(columns) atIndex:4];
    [last dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleRfftLastSparse.maxTotalThreadsPerThreadgroup), 1u, 1u)];
    [last endEncoding];
}

bool stwo_zig_metal_composition_lde_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||plan_ptr==NULL)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        StwoZigCompositionLdePlan *plan=(__bridge StwoZigCompositionLdePlan *)plan_ptr;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer];
        encode_composition_lde(runtime,arena,plan,command); [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

void *stwo_zig_metal_composition_inputs_prepare(
    void *runtime_ptr, const uint32_t *descriptors, uint32_t descriptor_count,
    uint32_t random_offset, uint32_t powers_offset, uint32_t power_count,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || power_count == 0u || (descriptor_count != 0u && descriptors == NULL)) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigCompositionInputPlan *plan = [StwoZigCompositionInputPlan new];
        if (descriptor_count != 0u) plan.descriptors = [runtime.device newBufferWithBytes:descriptors length:descriptor_count * 8u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.descriptorCount = descriptor_count; plan.randomOffset = random_offset;
        plan.powersOffset = powers_offset; plan.powerCount = power_count;
        if (descriptor_count != 0u && plan.descriptors == nil) {
            write_error(error_message, error_message_len, @"Metal composition input descriptor allocation failed"); return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_composition_inputs_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

void *stwo_zig_metal_composition_front_prepare(
    void *input_ptr, const void *const *lde_ptrs, const void *const *batch_ptrs, uint32_t component_count,
    uint32_t accumulator_offset, uint32_t accumulator_words,
    char *error_message, size_t error_message_len
) {
    if (input_ptr == NULL || lde_ptrs == NULL || batch_ptrs == NULL || component_count == 0u || accumulator_words == 0u) return NULL;
    @autoreleasepool {
        NSMutableArray *ldes = [NSMutableArray arrayWithCapacity:component_count];
        NSMutableArray *batches = [NSMutableArray arrayWithCapacity:component_count];
        for (uint32_t i = 0; i < component_count; ++i) {
            if (lde_ptrs[i] == NULL || batch_ptrs[i] == NULL) {
                write_error(error_message, error_message_len, @"Null component in Metal composition front plan"); return NULL;
            }
            [ldes addObject:(__bridge StwoZigCompositionLdePlan *)lde_ptrs[i]];
            [batches addObject:(__bridge StwoZigEvalBatch *)batch_ptrs[i]];
        }
        StwoZigCompositionFrontPlan *plan = [StwoZigCompositionFrontPlan new];
        plan.inputs = (__bridge StwoZigCompositionInputPlan *)input_ptr;
        plan.ldePlans = ldes; plan.evalBatches = batches;
        plan.accumulatorOffset = accumulator_offset; plan.accumulatorWords = accumulator_words;
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_composition_front_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

bool stwo_zig_metal_composition_front_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigCompositionFrontPlan *plan = (__bridge StwoZigCompositionFrontPlan *)plan_ptr;
        if ((NSUInteger)plan.accumulatorOffset * 4u + (NSUInteger)plan.accumulatorWords * 4u > arena.length) return false;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        StwoZigCompositionInputPlan *inputs = plan.inputs;
        id<MTLComputeCommandEncoder> powers = [command computeCommandEncoder];
        [powers setComputePipelineState:runtime.compositionRandomPowers]; [powers setBuffer:arena offset:0 atIndex:0];
        uint32_t random_offset = inputs.randomOffset, powers_offset = inputs.powersOffset, power_count = inputs.powerCount;
        [powers setBytes:&random_offset length:sizeof(random_offset) atIndex:1]; [powers setBytes:&powers_offset length:sizeof(powers_offset) atIndex:2];
        [powers setBytes:&power_count length:sizeof(power_count) atIndex:3];
        [powers dispatchThreads:MTLSizeMake(power_count, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.compositionRandomPowers.maxTotalThreadsPerThreadgroup), 1u, 1u)];
        [powers endEncoding];
        if (inputs.descriptorCount != 0u) {
            id<MTLComputeCommandEncoder> params = [command computeCommandEncoder];
            uint32_t descriptor_count = inputs.descriptorCount;
            [params setComputePipelineState:runtime.compositionExtParams]; [params setBuffer:arena offset:0 atIndex:0];
            [params setBuffer:inputs.descriptors offset:0 atIndex:1]; [params setBytes:&descriptor_count length:sizeof(descriptor_count) atIndex:2];
            [params dispatchThreads:MTLSizeMake(descriptor_count, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.compositionExtParams.maxTotalThreadsPerThreadgroup), 1u, 1u)];
            [params endEncoding];
        }
        id<MTLBlitCommandEncoder> clear = [command blitCommandEncoder];
        [clear fillBuffer:arena range:NSMakeRange((NSUInteger)plan.accumulatorOffset * 4u, (NSUInteger)plan.accumulatorWords * 4u) value:0u];
        [clear endEncoding];
        for (NSUInteger component = 0; component < plan.ldePlans.count; ++component) {
            encode_composition_lde(runtime, arena, plan.ldePlans[component], command);
            StwoZigEvalBatch *batch = plan.evalBatches[component];
            for (StwoZigEvalPlan *eval in batch.plans) {
                id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
                [encoder setComputePipelineState:eval.pipeline]; [encoder setBuffer:arena offset:0 atIndex:0];
                [encoder setBuffer:eval.arguments offset:0 atIndex:1];
                NSUInteger width = MIN((NSUInteger)256u, MIN((NSUInteger)eval.rowCount, eval.pipeline.maxTotalThreadsPerThreadgroup));
                [encoder dispatchThreads:MTLSizeMake(eval.rowCount, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
                [encoder endEncoding];
            }
        }
        [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_composition_finalize_prepare(
    void *runtime_ptr, const uint32_t *accumulator_offsets, const uint32_t *accumulator_logs,
    uint32_t accumulator_count, uint32_t inverse_twiddle_offset_words,
    const uint32_t *output_offsets, uint32_t scale_factor,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || accumulator_offsets == NULL || accumulator_logs == NULL ||
        accumulator_count == 0u || output_offsets == NULL || scale_factor == 0u) return NULL;
    for (uint32_t i = 0; i < accumulator_count; ++i) {
        if (accumulator_logs[i] < 3u || accumulator_logs[i] >= 31u ||
            (i > 0u && accumulator_logs[i] <= accumulator_logs[i - 1u])) return NULL;
    }
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigCompositionFinalizePlan *plan = [StwoZigCompositionFinalizePlan new];
        plan.accumulatorOffsets = [NSData dataWithBytes:accumulator_offsets length:accumulator_count * sizeof(uint32_t)];
        plan.accumulatorLogs = [NSData dataWithBytes:accumulator_logs length:accumulator_count * sizeof(uint32_t)];
        uint32_t final_offset = accumulator_offsets[accumulator_count - 1u];
        uint32_t final_rows = 1u << accumulator_logs[accumulator_count - 1u];
        uint32_t coordinates[4] = { final_offset, final_offset + final_rows, final_offset + 2u * final_rows, final_offset + 3u * final_rows };
        plan.coordinateOffsets = [runtime.device newBufferWithLength:5u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.outputOffsets = [runtime.device newBufferWithBytes:output_offsets length:8u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.accumulatorCount = accumulator_count;
        plan.inverseTwiddleByteOffset = (NSUInteger)inverse_twiddle_offset_words * sizeof(uint32_t);
        if (plan.coordinateOffsets == nil || plan.outputOffsets == nil) {
            write_error(error_message, error_message_len, @"Metal composition-finalize plan allocation failed"); return NULL;
        }
        memcpy(plan.coordinateOffsets.contents, coordinates, sizeof(coordinates));
        ((uint32_t *)plan.coordinateOffsets.contents)[4] = scale_factor;
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_composition_finalize_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

bool stwo_zig_metal_composition_finalize_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigCompositionFinalizePlan *plan = (__bridge StwoZigCompositionFinalizePlan *)plan_ptr;
        const uint32_t *offsets = plan.accumulatorOffsets.bytes, *logs = plan.accumulatorLogs.bytes;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        for (uint32_t i = 1u; i < plan.accumulatorCount; ++i) {
            uint32_t previous_offset = offsets[i - 1u], previous_log = logs[i - 1u];
            uint32_t current_offset = offsets[i], current_log = logs[i], current_rows = 1u << current_log;
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:runtime.compositionLift]; [encoder setBuffer:arena offset:0 atIndex:0];
            [encoder setBytes:&previous_offset length:sizeof(previous_offset) atIndex:1];
            [encoder setBytes:&previous_log length:sizeof(previous_log) atIndex:2];
            [encoder setBytes:&current_offset length:sizeof(current_offset) atIndex:3];
            [encoder setBytes:&current_log length:sizeof(current_log) atIndex:4];
            NSUInteger width = MIN((NSUInteger)256u, runtime.compositionLift.maxTotalThreadsPerThreadgroup);
            [encoder dispatchThreads:MTLSizeMake(current_rows, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
            [encoder endEncoding];
        }
        uint32_t log_size = logs[plan.accumulatorCount - 1u], rows = 1u << log_size, pairs = rows >> 1u;
        uint32_t column_count = 4u;
        MTLSize grid = MTLSizeMake(pairs, column_count, 1u);
        id<MTLComputeCommandEncoder> first = [command computeCommandEncoder];
        [first setComputePipelineState:runtime.circleIfftFirstSparse]; [first setBuffer:arena offset:0 atIndex:0];
        [first setBuffer:plan.coordinateOffsets offset:0 atIndex:1]; [first setBuffer:arena offset:plan.inverseTwiddleByteOffset atIndex:2];
        [first setBytes:&log_size length:sizeof(log_size) atIndex:3]; [first setBytes:&column_count length:sizeof(column_count) atIndex:4];
        [first dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleIfftFirstSparse.maxTotalThreadsPerThreadgroup), 1u, 1u)];
        [first endEncoding];
        for (uint32_t layer = 1u; layer < log_size; ++layer) {
            uint32_t twiddle_offset = pairs - (1u << (log_size - layer));
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:runtime.circleIfftLayerSparse]; [encoder setBuffer:arena offset:0 atIndex:0];
            [encoder setBuffer:plan.coordinateOffsets offset:0 atIndex:1]; [encoder setBuffer:arena offset:plan.inverseTwiddleByteOffset atIndex:2];
            [encoder setBytes:&log_size length:sizeof(log_size) atIndex:3]; [encoder setBytes:&layer length:sizeof(layer) atIndex:4];
            [encoder setBytes:&twiddle_offset length:sizeof(twiddle_offset) atIndex:5]; [encoder setBytes:&column_count length:sizeof(column_count) atIndex:6];
            [encoder dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleIfftLayerSparse.maxTotalThreadsPerThreadgroup), 1u, 1u)];
            [encoder endEncoding];
        }
        uint32_t factor = ((uint32_t *)plan.coordinateOffsets.contents)[4];
        id<MTLComputeCommandEncoder> scale = [command computeCommandEncoder];
        [scale setComputePipelineState:runtime.circleRescaleSparse]; [scale setBuffer:arena offset:0 atIndex:0];
        [scale setBuffer:plan.coordinateOffsets offset:0 atIndex:1]; [scale setBytes:&log_size length:sizeof(log_size) atIndex:2];
        [scale setBytes:&column_count length:sizeof(column_count) atIndex:3]; [scale setBytes:&factor length:sizeof(factor) atIndex:4];
        [scale dispatchThreads:MTLSizeMake(rows, column_count, 1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleRescaleSparse.maxTotalThreadsPerThreadgroup), 1u, 1u)];
        [scale endEncoding];
        uint32_t source_offset = offsets[plan.accumulatorCount - 1u];
        id<MTLComputeCommandEncoder> split = [command computeCommandEncoder];
        [split setComputePipelineState:runtime.compositionSplit]; [split setBuffer:arena offset:0 atIndex:0];
        [split setBuffer:plan.outputOffsets offset:0 atIndex:1]; [split setBytes:&source_offset length:sizeof(source_offset) atIndex:2];
        [split setBytes:&log_size length:sizeof(log_size) atIndex:3];
        NSUInteger split_width = MIN((NSUInteger)256u, runtime.compositionSplit.maxTotalThreadsPerThreadgroup);
        [split dispatchThreads:MTLSizeMake((rows >> 1u) * 8u, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(split_width, 1u, 1u)];
        [split endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

bool stwo_zig_metal_eval_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigEvalPlan *plan = (__bridge StwoZigEvalPlan *)plan_ptr;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:plan.pipeline];
        [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBuffer:plan.arguments offset:0 atIndex:1];
        NSUInteger width = MIN((NSUInteger)256u, MIN((NSUInteger)plan.rowCount, plan.pipeline.maxTotalThreadsPerThreadgroup));
        [encoder dispatchThreads:MTLSizeMake(plan.rowCount, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len, command.error.localizedDescription); return false;
        }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

bool stwo_zig_metal_compact_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigCompactPlan *plan = (__bridge StwoZigCompactPlan *)plan_ptr;
        NSUInteger width = MIN((NSUInteger)256u, MIN((NSUInteger)plan.sortRows, runtime.compactGather.maxTotalThreadsPerThreadgroup));
        uint32_t block_count = (uint32_t)(plan.sortRows / width);
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> gather = [command computeCommandEncoder];
        [gather setComputePipelineState:runtime.compactGather]; [gather setBuffer:arena offset:0 atIndex:0];
        [gather setBuffer:plan.sourceOffsets offset:0 atIndex:1]; [gather setBuffer:plan.descriptors offset:0 atIndex:2];
        [gather setBuffer:plan.params offset:0 atIndex:3];
        [gather dispatchThreads:MTLSizeMake(plan.sortRows, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [gather endEncoding];

        uint32_t current = plan.indicesA, next = plan.indicesB;
        for (uint32_t word = plan.keyWords; word-- > 0u;) {
            for (uint32_t shift = 0u; shift < 32u; shift += 4u) {
                id<MTLComputeCommandEncoder> histogram = [command computeCommandEncoder];
                [histogram setComputePipelineState:runtime.compactRadixHistogram]; [histogram setBuffer:arena offset:0 atIndex:0];
                [histogram setBuffer:plan.params offset:0 atIndex:1]; [histogram setBytes:&word length:sizeof(word) atIndex:2];
                [histogram setBytes:&shift length:sizeof(shift) atIndex:3]; [histogram setBytes:&current length:sizeof(current) atIndex:4];
                [histogram dispatchThreads:MTLSizeMake(plan.sortRows, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
                [histogram endEncoding];

                id<MTLComputeCommandEncoder> prefix = [command computeCommandEncoder];
                [prefix setComputePipelineState:runtime.compactRadixPrefix]; [prefix setBuffer:arena offset:0 atIndex:0];
                [prefix setBuffer:plan.params offset:0 atIndex:1]; [prefix setBytes:&block_count length:sizeof(block_count) atIndex:2];
                [prefix dispatchThreadgroups:MTLSizeMake(1u, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(16u, 1u, 1u)];
                [prefix endEncoding];

                id<MTLComputeCommandEncoder> scatter = [command computeCommandEncoder];
                [scatter setComputePipelineState:runtime.compactRadixScatter]; [scatter setBuffer:arena offset:0 atIndex:0];
                [scatter setBuffer:plan.params offset:0 atIndex:1]; [scatter setBytes:&word length:sizeof(word) atIndex:2];
                [scatter setBytes:&shift length:sizeof(shift) atIndex:3]; [scatter setBytes:&current length:sizeof(current) atIndex:4];
                [scatter setBytes:&next length:sizeof(next) atIndex:5];
                [scatter dispatchThreads:MTLSizeMake(plan.sortRows, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
                [scatter endEncoding];
                uint32_t swap = current; current = next; next = swap;
            }
        }
        if (current != plan.indicesA) {
            write_error(error_message, error_message_len, @"Metal compact radix parity invariant failed"); return false;
        }

        id<MTLComputeCommandEncoder> heads = [command computeCommandEncoder];
        [heads setComputePipelineState:runtime.compactHeads]; [heads setBuffer:arena offset:0 atIndex:0];
        [heads setBuffer:plan.params offset:0 atIndex:1];
        [heads dispatchThreads:MTLSizeMake(plan.sortRows, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [heads endEncoding];
        id<MTLComputeCommandEncoder> scan = [command computeCommandEncoder];
        [scan setComputePipelineState:runtime.compactScanLocal]; [scan setBuffer:arena offset:0 atIndex:0];
        [scan setBuffer:plan.params offset:0 atIndex:1];
        [scan dispatchThreads:MTLSizeMake(plan.sortRows, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [scan endEncoding];
        id<MTLComputeCommandEncoder> scan_blocks = [command computeCommandEncoder];
        [scan_blocks setComputePipelineState:runtime.compactScanBlocks]; [scan_blocks setBuffer:arena offset:0 atIndex:0];
        [scan_blocks setBuffer:plan.params offset:0 atIndex:1]; [scan_blocks setBytes:&block_count length:sizeof(block_count) atIndex:2];
        [scan_blocks dispatchThreads:MTLSizeMake(1u, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(1u, 1u, 1u)];
        [scan_blocks endEncoding];
        id<MTLComputeCommandEncoder> scan_add = [command computeCommandEncoder];
        [scan_add setComputePipelineState:runtime.compactScanAdd]; [scan_add setBuffer:arena offset:0 atIndex:0];
        [scan_add setBuffer:plan.params offset:0 atIndex:1];
        [scan_add dispatchThreads:MTLSizeMake(plan.sortRows, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [scan_add endEncoding];
        NSUInteger consumer_width = MIN((NSUInteger)256u, MIN((NSUInteger)plan.consumerRows, runtime.compactClearOutputs.maxTotalThreadsPerThreadgroup));
        id<MTLComputeCommandEncoder> clear = [command computeCommandEncoder];
        [clear setComputePipelineState:runtime.compactClearOutputs]; [clear setBuffer:arena offset:0 atIndex:0];
        [clear setBuffer:plan.outputOffsets offset:0 atIndex:1]; [clear setBuffer:plan.params offset:0 atIndex:2];
        [clear dispatchThreads:MTLSizeMake(plan.consumerRows, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(consumer_width, 1u, 1u)];
        [clear endEncoding];
        id<MTLComputeCommandEncoder> compact_scatter = [command computeCommandEncoder];
        [compact_scatter setComputePipelineState:runtime.compactScatter]; [compact_scatter setBuffer:arena offset:0 atIndex:0];
        [compact_scatter setBuffer:plan.outputOffsets offset:0 atIndex:1]; [compact_scatter setBuffer:plan.params offset:0 atIndex:2];
        [compact_scatter dispatchThreads:MTLSizeMake(plan.totalRows, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [compact_scatter endEncoding];
        id<MTLComputeCommandEncoder> finalize = [command computeCommandEncoder];
        [finalize setComputePipelineState:runtime.compactFinalize]; [finalize setBuffer:arena offset:0 atIndex:0];
        [finalize setBuffer:plan.outputOffsets offset:0 atIndex:1]; [finalize setBuffer:plan.params offset:0 atIndex:2];
        [finalize dispatchThreads:MTLSizeMake(plan.consumerRows, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(consumer_width, 1u, 1u)];
        [finalize endEncoding];
        [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len, command.error.localizedDescription); return false;
        }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

bool stwo_zig_metal_ec_op_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigEcOpPlan *plan = (__bridge StwoZigEcOpPlan *)plan_ptr;
        uint32_t rows = plan.rowCount;
        NSUInteger width = MIN((NSUInteger)256u, MIN((NSUInteger)rows, runtime.ecOpWitness.maxTotalThreadsPerThreadgroup));
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.ecOpWitness]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBuffer:plan.executionOffsets offset:0 atIndex:1]; [encoder setBuffer:plan.traceOffsets offset:0 atIndex:2];
        [encoder setBuffer:plan.partialOffsets offset:0 atIndex:3]; [encoder setBuffer:plan.multiplicityOffsets offset:0 atIndex:4];
        [encoder setBuffer:plan.params offset:0 atIndex:5];
        [encoder dispatchThreads:MTLSizeMake(rows, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_relation_prepare(
    void *runtime_ptr, const uint32_t *geometry, uint32_t instance_count,
    const uint32_t *source_offsets, uint32_t source_count,
    const uint32_t *descriptors, uint32_t descriptor_words,
    const uint32_t *output_offsets, uint32_t output_count,
    uint32_t total_blocks, uint32_t alpha_offset_words, uint32_t z_offset_words,
    uint32_t scratch_offset_words, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || geometry == NULL || instance_count == 0u || source_offsets == NULL || source_count == 0u ||
        descriptors == NULL || descriptor_words == 0u || output_offsets == NULL || output_count == 0u || total_blocks == 0u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigRelationPlan *plan = [StwoZigRelationPlan new];
        plan.geometry = [runtime.device newBufferWithBytes:geometry length:(NSUInteger)instance_count * 10u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.sourceOffsets = [runtime.device newBufferWithBytes:source_offsets length:(NSUInteger)source_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.descriptors = [runtime.device newBufferWithBytes:descriptors length:(NSUInteger)descriptor_words * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.outputOffsets = [runtime.device newBufferWithBytes:output_offsets length:(NSUInteger)output_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.instanceCount = instance_count; plan.totalBlocks = total_blocks;
        plan.alphaByteOffset = (NSUInteger)alpha_offset_words * sizeof(uint32_t);
        plan.zByteOffset = (NSUInteger)z_offset_words * sizeof(uint32_t);
        plan.scratchByteOffset = (NSUInteger)scratch_offset_words * sizeof(uint32_t);
        if (plan.geometry == nil || plan.sourceOffsets == nil || plan.descriptors == nil || plan.outputOffsets == nil) {
            write_error(error_message, error_message_len, @"Metal relation plan allocation failed"); return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_relation_plan_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

bool stwo_zig_metal_relation_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigRelationPlan *plan = (__bridge StwoZigRelationPlan *)plan_ptr;
        uint32_t instances = plan.instanceCount, blocks = plan.totalBlocks;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> fused = [command computeCommandEncoder];
        [fused setComputePipelineState:runtime.relationFused];
        [fused setBuffer:arena offset:0 atIndex:0]; [fused setBuffer:plan.geometry offset:0 atIndex:1];
        [fused setBuffer:plan.sourceOffsets offset:0 atIndex:2]; [fused setBuffer:plan.descriptors offset:0 atIndex:3];
        [fused setBuffer:plan.outputOffsets offset:0 atIndex:4]; [fused setBuffer:arena offset:plan.alphaByteOffset atIndex:5];
        [fused setBuffer:arena offset:plan.zByteOffset atIndex:6]; [fused setBytes:&instances length:sizeof(instances) atIndex:7];
        [fused dispatchThreads:MTLSizeMake((NSUInteger)blocks * 256u, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(256u, 1u, 1u)];
        [fused endEncoding];
        id<MTLComputeCommandEncoder> local_scan = [command computeCommandEncoder];
        [local_scan setComputePipelineState:runtime.relationBlockScan];
        [local_scan setBuffer:arena offset:0 atIndex:0]; [local_scan setBuffer:plan.geometry offset:0 atIndex:1];
        [local_scan setBuffer:plan.outputOffsets offset:0 atIndex:2]; [local_scan setBuffer:arena offset:plan.scratchByteOffset atIndex:3];
        [local_scan setBytes:&instances length:sizeof(instances) atIndex:4];
        [local_scan dispatchThreadgroups:MTLSizeMake(blocks, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(256u, 1u, 1u)];
        [local_scan endEncoding];
        id<MTLComputeCommandEncoder> block_scan = [command computeCommandEncoder];
        [block_scan setComputePipelineState:runtime.relationScanBlocks];
        [block_scan setBuffer:arena offset:0 atIndex:0]; [block_scan setBuffer:plan.geometry offset:0 atIndex:1];
        [block_scan setBuffer:arena offset:plan.scratchByteOffset atIndex:2]; [block_scan setBytes:&instances length:sizeof(instances) atIndex:3];
        NSUInteger scan_width = MIN((NSUInteger)256u, runtime.relationScanBlocks.maxTotalThreadsPerThreadgroup);
        [block_scan dispatchThreads:MTLSizeMake(instances, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(scan_width, 1u, 1u)];
        [block_scan endEncoding];
        id<MTLComputeCommandEncoder> finalize = [command computeCommandEncoder];
        [finalize setComputePipelineState:runtime.relationScanFinalize];
        [finalize setBuffer:arena offset:0 atIndex:0]; [finalize setBuffer:plan.geometry offset:0 atIndex:1];
        [finalize setBuffer:plan.outputOffsets offset:0 atIndex:2]; [finalize setBuffer:arena offset:plan.scratchByteOffset atIndex:3];
        [finalize setBytes:&instances length:sizeof(instances) atIndex:4];
        [finalize dispatchThreads:MTLSizeMake((NSUInteger)blocks * 256u, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(256u, 1u, 1u)];
        [finalize endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

bool stwo_zig_metal_witness_feed_counts_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr, uint32_t column_length,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL || column_length == 0u) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigWitnessFeedPlan *plan = (__bridge StwoZigWitnessFeedPlan *)plan_ptr;
        uint32_t descriptor_count = plan.descriptorCount;
        uint32_t clear_range_count = plan.clearRangeCount;
        uint32_t clear_total_words = plan.clearTotalWords;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.clearArenaSpans];
        [encoder setBuffer:arena offset:0 atIndex:0]; [encoder setBuffer:plan.clearRanges offset:0 atIndex:1];
        [encoder setBytes:&clear_range_count length:sizeof(clear_range_count) atIndex:2]; [encoder setBytes:&clear_total_words length:sizeof(clear_total_words) atIndex:3];
        NSUInteger clear_width = MIN(runtime.clearArenaSpans.maxTotalThreadsPerThreadgroup, runtime.clearArenaSpans.threadExecutionWidth * 8u);
        [encoder dispatchThreads:MTLSizeMake(clear_total_words, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(clear_width, 1u, 1u)];
        [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];
        [encoder setComputePipelineState:runtime.witnessFeedCounts];
        [encoder setBuffer:arena offset:0 atIndex:0]; [encoder setBuffer:plan.descriptors offset:0 atIndex:1]; [encoder setBuffer:plan.luts offset:0 atIndex:2];
        [encoder setBuffer:plan.destinationOffsets offset:0 atIndex:3]; [encoder setBuffer:plan.sourceOffsets offset:0 atIndex:4];
        [encoder setBytes:&column_length length:sizeof(column_length) atIndex:5]; [encoder setBytes:&descriptor_count length:sizeof(descriptor_count) atIndex:6];
        NSUInteger width = MIN(runtime.witnessFeedCounts.maxTotalThreadsPerThreadgroup, runtime.witnessFeedCounts.threadExecutionWidth * 8u);
        [encoder dispatchThreads:MTLSizeMake(column_length, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

bool stwo_zig_metal_circle_transform(
    void *runtime_ptr,
    uint32_t *const *columns,
    uint32_t column_count,
    uint32_t log_size,
    const uint32_t *twiddles,
    bool inverse,
    uint32_t scale_factor,
    double *gpu_milliseconds,
    char *error_message,
    size_t error_message_len
) {
    if (runtime_ptr == NULL || columns == NULL || twiddles == NULL || column_count == 0u || log_size < 3u || log_size >= 31u) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        uint32_t value_count = 1u << log_size;
        uint32_t pair_count = value_count >> 1u;
        size_t flat_count = (size_t)column_count * value_count;
        id<MTLBuffer> values = [runtime.device newBufferWithLength:flat_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        id<MTLBuffer> twiddle_buffer = [runtime.device newBufferWithBytes:twiddles length:(NSUInteger)pair_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        if (values == nil || twiddle_buffer == nil) {
            write_error(error_message, error_message_len, @"Metal circle transform allocation failed");
            return false;
        }
        uint32_t *flat = values.contents;
        for (uint32_t column = 0; column < column_count; ++column) {
            memcpy(flat + (size_t)column * value_count, columns[column], (size_t)value_count * sizeof(uint32_t));
        }

        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        MTLSize grid = MTLSizeMake(pair_count, column_count, 1u);
        if (inverse) {
            id<MTLComputeCommandEncoder> first = [command computeCommandEncoder];
            [first setComputePipelineState:runtime.circleIfftFirst];
            [first setBuffer:values offset:0 atIndex:0];
            [first setBuffer:twiddle_buffer offset:0 atIndex:1];
            [first setBytes:&log_size length:sizeof(log_size) atIndex:2];
            [first setBytes:&column_count length:sizeof(column_count) atIndex:3];
            [first dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleIfftFirst.maxTotalThreadsPerThreadgroup), 1u, 1u)];
            [first endEncoding];

            uint32_t twiddle_offset = 0u;
            uint32_t layer_size = pair_count;
            for (uint32_t layer = 1u; layer < log_size; ++layer) {
                id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
                [encoder setComputePipelineState:runtime.circleIfftLayer];
                [encoder setBuffer:values offset:0 atIndex:0];
                [encoder setBuffer:twiddle_buffer offset:0 atIndex:1];
                [encoder setBytes:&log_size length:sizeof(log_size) atIndex:2];
                [encoder setBytes:&layer length:sizeof(layer) atIndex:3];
                [encoder setBytes:&twiddle_offset length:sizeof(twiddle_offset) atIndex:4];
                [encoder setBytes:&column_count length:sizeof(column_count) atIndex:5];
                [encoder dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleIfftLayer.maxTotalThreadsPerThreadgroup), 1u, 1u)];
                [encoder endEncoding];
                layer_size >>= 1u;
                twiddle_offset += layer_size;
            }
            id<MTLComputeCommandEncoder> scale = [command computeCommandEncoder];
            uint32_t total_values = (uint32_t)flat_count;
            [scale setComputePipelineState:runtime.circleRescale];
            [scale setBuffer:values offset:0 atIndex:0];
            [scale setBytes:&total_values length:sizeof(total_values) atIndex:1];
            [scale setBytes:&scale_factor length:sizeof(scale_factor) atIndex:2];
            [scale dispatchThreads:MTLSizeMake(total_values, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleRescale.maxTotalThreadsPerThreadgroup), 1u, 1u)];
            [scale endEncoding];
        } else {
            uint32_t layer_size = 1u;
            uint32_t twiddle_offset = pair_count - 2u;
            for (uint32_t layer = log_size - 1u; layer > 0u; --layer) {
                id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
                [encoder setComputePipelineState:runtime.circleRfftLayer];
                [encoder setBuffer:values offset:0 atIndex:0];
                [encoder setBuffer:twiddle_buffer offset:0 atIndex:1];
                [encoder setBytes:&log_size length:sizeof(log_size) atIndex:2];
                [encoder setBytes:&layer length:sizeof(layer) atIndex:3];
                [encoder setBytes:&twiddle_offset length:sizeof(twiddle_offset) atIndex:4];
                [encoder setBytes:&column_count length:sizeof(column_count) atIndex:5];
                [encoder dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleRfftLayer.maxTotalThreadsPerThreadgroup), 1u, 1u)];
                [encoder endEncoding];
                layer_size <<= 1u;
                twiddle_offset -= layer_size;
            }
            id<MTLComputeCommandEncoder> last = [command computeCommandEncoder];
            [last setComputePipelineState:runtime.circleRfftLast];
            [last setBuffer:values offset:0 atIndex:0];
            [last setBuffer:twiddle_buffer offset:0 atIndex:1];
            [last setBytes:&log_size length:sizeof(log_size) atIndex:2];
            [last setBytes:&column_count length:sizeof(column_count) atIndex:3];
            [last dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleRfftLast.maxTotalThreadsPerThreadgroup), 1u, 1u)];
            [last endEncoding];
        }
        [command commit];
        [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len, command.error.localizedDescription ?: @"Metal circle transform failed");
            return false;
        }
        for (uint32_t column = 0; column < column_count; ++column) {
            memcpy(columns[column], flat + (size_t)column * value_count, (size_t)value_count * sizeof(uint32_t));
        }
        if (gpu_milliseconds != NULL) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

bool stwo_zig_metal_circle_lde(
    void *runtime_ptr,
    const uint32_t *const *source_columns,
    uint32_t *const *base_columns,
    uint32_t *const *extended_columns,
    uint32_t column_count,
    uint32_t base_log_size,
    uint32_t extended_log_size,
    const uint32_t *inverse_twiddles,
    const uint32_t *forward_twiddles,
    uint32_t scale_factor,
    double *gpu_milliseconds,
    char *error_message,
    size_t error_message_len
) {
    if (runtime_ptr == NULL || source_columns == NULL || base_columns == NULL || extended_columns == NULL ||
        inverse_twiddles == NULL || forward_twiddles == NULL || column_count == 0u ||
        base_log_size < 3u || extended_log_size <= base_log_size || extended_log_size >= 31u) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        uint32_t base_len = 1u << base_log_size;
        uint32_t extended_len = 1u << extended_log_size;
        uint32_t base_pairs = base_len >> 1u;
        uint32_t extended_pairs = extended_len >> 1u;
        size_t flat_base_count = (size_t)column_count * base_len;
        size_t flat_extended_count = (size_t)column_count * extended_len;
        bool contiguous_base = true;
        bool contiguous_extended = true;
        bool source_is_base = true;
        for (uint32_t column = 1; column < column_count; ++column) {
            contiguous_base &= base_columns[column] == base_columns[0] + (size_t)column * base_len;
            contiguous_extended &= extended_columns[column] == extended_columns[0] + (size_t)column * extended_len;
        }
        for (uint32_t column = 0; column < column_count; ++column) {
            source_is_base &= source_columns[column] == base_columns[column];
        }
        id<MTLBuffer> coefficients = contiguous_base
            ? [runtime.device newBufferWithBytesNoCopy:base_columns[0]
                                                length:flat_base_count * sizeof(uint32_t)
                                               options:MTLResourceStorageModeShared
                                           deallocator:nil]
            : [runtime.device newBufferWithLength:flat_base_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        id<MTLBuffer> extended = contiguous_extended
            ? [runtime.device newBufferWithBytesNoCopy:extended_columns[0]
                                                length:flat_extended_count * sizeof(uint32_t)
                                               options:MTLResourceStorageModeShared
                                           deallocator:nil]
            : [runtime.device newBufferWithLength:flat_extended_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        id<MTLBuffer> inverse_buffer = [runtime.device newBufferWithBytes:inverse_twiddles length:(NSUInteger)base_pairs * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        id<MTLBuffer> forward_buffer = [runtime.device newBufferWithBytes:forward_twiddles length:(NSUInteger)extended_pairs * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        if (coefficients == nil || extended == nil || inverse_buffer == nil || forward_buffer == nil) {
            write_error(error_message, error_message_len, @"Metal circle LDE allocation failed");
            return false;
        }
        uint32_t *coefficient_words = coefficients.contents;
        if (source_is_base && !contiguous_base) {
            for (uint32_t column = 0; column < column_count; ++column) {
                memcpy(coefficient_words + (size_t)column * base_len, source_columns[column], (size_t)base_len * sizeof(uint32_t));
            }
        }

        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        NSMutableArray<id<MTLBuffer>> *input_sources = [NSMutableArray array];
        if (!source_is_base) {
            id<MTLBlitCommandEncoder> upload = [command blitCommandEncoder];
            size_t column = 0;
            size_t destination_words = 0;
            size_t page_size = (size_t)getpagesize();
            while (column < column_count) {
                size_t run_start = column;
                size_t run_words = base_len;
                column += 1;
                while (column < column_count && source_columns[column] == source_columns[run_start] + run_words) {
                    run_words += base_len;
                    column += 1;
                }
                size_t run_bytes = run_words * sizeof(uint32_t);
                uintptr_t address = (uintptr_t)source_columns[run_start];
                bool no_copy = (address % page_size) == 0u && (run_bytes % page_size) == 0u;
                id<MTLBuffer> source = no_copy
                    ? [runtime.device newBufferWithBytesNoCopy:(void *)source_columns[run_start]
                                                        length:run_bytes
                                                       options:MTLResourceStorageModeShared
                                                   deallocator:nil]
                    : [runtime.device newBufferWithBytes:source_columns[run_start]
                                                  length:run_bytes
                                                 options:MTLResourceStorageModeShared];
                if (source == nil) {
                    write_error(error_message, error_message_len, @"Metal circle source allocation failed");
                    return false;
                }
                [input_sources addObject:source];
                [upload copyFromBuffer:source sourceOffset:0 toBuffer:coefficients
                     destinationOffset:destination_words * sizeof(uint32_t) size:run_bytes];
                destination_words += run_words;
            }
            [upload endEncoding];
        }
        MTLSize base_grid = MTLSizeMake(base_pairs, column_count, 1u);
        uint32_t inverse_start_layer = 1u;
        if (base_log_size >= 11u) {
            id<MTLComputeCommandEncoder> fused = [command computeCommandEncoder];
            [fused setComputePipelineState:runtime.circleIfftFused];
            [fused setBuffer:coefficients offset:0 atIndex:0];
            [fused setBuffer:inverse_buffer offset:0 atIndex:1];
            [fused setBytes:&base_log_size length:sizeof(base_log_size) atIndex:2];
            [fused setBytes:&column_count length:sizeof(column_count) atIndex:3];
            [fused dispatchThreadgroups:MTLSizeMake(base_len >> 11u, column_count, 1u)
                     threadsPerThreadgroup:MTLSizeMake(256u, 1u, 1u)];
            [fused endEncoding];
            inverse_start_layer = 11u;
        } else {
            id<MTLComputeCommandEncoder> first = [command computeCommandEncoder];
            [first setComputePipelineState:runtime.circleIfftFirst];
            [first setBuffer:coefficients offset:0 atIndex:0];
            [first setBuffer:inverse_buffer offset:0 atIndex:1];
            [first setBytes:&base_log_size length:sizeof(base_log_size) atIndex:2];
            [first setBytes:&column_count length:sizeof(column_count) atIndex:3];
            [first dispatchThreads:base_grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleIfftFirst.maxTotalThreadsPerThreadgroup), 1u, 1u)];
            [first endEncoding];
        }
        for (uint32_t layer = inverse_start_layer; layer < base_log_size; ++layer) {
            uint32_t inverse_offset = base_pairs - (1u << (base_log_size - layer));
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:runtime.circleIfftLayer];
            [encoder setBuffer:coefficients offset:0 atIndex:0];
            [encoder setBuffer:inverse_buffer offset:0 atIndex:1];
            [encoder setBytes:&base_log_size length:sizeof(base_log_size) atIndex:2];
            [encoder setBytes:&layer length:sizeof(layer) atIndex:3];
            [encoder setBytes:&inverse_offset length:sizeof(inverse_offset) atIndex:4];
            [encoder setBytes:&column_count length:sizeof(column_count) atIndex:5];
            [encoder dispatchThreads:base_grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleIfftLayer.maxTotalThreadsPerThreadgroup), 1u, 1u)];
            [encoder endEncoding];
        }
        id<MTLComputeCommandEncoder> scale = [command computeCommandEncoder];
        uint32_t total_base_values = (uint32_t)flat_base_count;
        [scale setComputePipelineState:runtime.circleRescale];
        [scale setBuffer:coefficients offset:0 atIndex:0];
        [scale setBytes:&total_base_values length:sizeof(total_base_values) atIndex:1];
        [scale setBytes:&scale_factor length:sizeof(scale_factor) atIndex:2];
        [scale dispatchThreads:MTLSizeMake(total_base_values, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleRescale.maxTotalThreadsPerThreadgroup), 1u, 1u)];
        [scale endEncoding];

        id<MTLComputeCommandEncoder> expand = [command computeCommandEncoder];
        [expand setComputePipelineState:runtime.circleExpand];
        [expand setBuffer:coefficients offset:0 atIndex:0];
        [expand setBuffer:extended offset:0 atIndex:1];
        [expand setBytes:&base_log_size length:sizeof(base_log_size) atIndex:2];
        [expand setBytes:&extended_log_size length:sizeof(extended_log_size) atIndex:3];
        [expand setBytes:&column_count length:sizeof(column_count) atIndex:4];
        [expand dispatchThreads:MTLSizeMake(extended_len, column_count, 1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleExpand.maxTotalThreadsPerThreadgroup), 1u, 1u)];
        [expand endEncoding];

        MTLSize extended_grid = MTLSizeMake(extended_pairs, column_count, 1u);
        uint32_t forward_stop_layer = extended_log_size >= 11u ? 10u : 0u;
        for (uint32_t layer = extended_log_size - 1u; layer > forward_stop_layer; --layer) {
            uint32_t forward_offset = extended_pairs - (1u << (extended_log_size - layer));
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:runtime.circleRfftLayer];
            [encoder setBuffer:extended offset:0 atIndex:0];
            [encoder setBuffer:forward_buffer offset:0 atIndex:1];
            [encoder setBytes:&extended_log_size length:sizeof(extended_log_size) atIndex:2];
            [encoder setBytes:&layer length:sizeof(layer) atIndex:3];
            [encoder setBytes:&forward_offset length:sizeof(forward_offset) atIndex:4];
            [encoder setBytes:&column_count length:sizeof(column_count) atIndex:5];
            [encoder dispatchThreads:extended_grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleRfftLayer.maxTotalThreadsPerThreadgroup), 1u, 1u)];
            [encoder endEncoding];
        }
        if (extended_log_size >= 11u) {
            id<MTLComputeCommandEncoder> fused = [command computeCommandEncoder];
            [fused setComputePipelineState:runtime.circleRfftFused];
            [fused setBuffer:extended offset:0 atIndex:0];
            [fused setBuffer:forward_buffer offset:0 atIndex:1];
            [fused setBytes:&extended_log_size length:sizeof(extended_log_size) atIndex:2];
            [fused setBytes:&column_count length:sizeof(column_count) atIndex:3];
            [fused dispatchThreadgroups:MTLSizeMake(extended_len >> 11u, column_count, 1u)
                     threadsPerThreadgroup:MTLSizeMake(256u, 1u, 1u)];
            [fused endEncoding];
        } else {
            id<MTLComputeCommandEncoder> last = [command computeCommandEncoder];
            [last setComputePipelineState:runtime.circleRfftLast];
            [last setBuffer:extended offset:0 atIndex:0];
            [last setBuffer:forward_buffer offset:0 atIndex:1];
            [last setBytes:&extended_log_size length:sizeof(extended_log_size) atIndex:2];
            [last setBytes:&column_count length:sizeof(column_count) atIndex:3];
            [last dispatchThreads:extended_grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleRfftLast.maxTotalThreadsPerThreadgroup), 1u, 1u)];
            [last endEncoding];
        }

        [command commit];
        [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len, command.error.localizedDescription ?: @"Metal circle LDE failed");
            return false;
        }
        uint32_t *extended_words = extended.contents;
        for (uint32_t column = 0; column < column_count; ++column) {
            if (!contiguous_base) memcpy(base_columns[column], coefficient_words + (size_t)column * base_len, (size_t)base_len * sizeof(uint32_t));
            if (!contiguous_extended) memcpy(extended_columns[column], extended_words + (size_t)column * extended_len, (size_t)extended_len * sizeof(uint32_t));
        }
        if (gpu_milliseconds != NULL) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

bool stwo_zig_metal_eval_polynomials(
    void *runtime_ptr,
    const uint32_t *const *coefficients,
    const size_t *coefficient_lengths,
    uint32_t coefficient_column_count,
    size_t coefficient_count,
    const uint32_t *factors, size_t factor_word_count,
    const void *basis_tasks, uint32_t basis_task_count,
    uint32_t basis_count,
    const void *tasks, uint32_t task_count,
    uint32_t output_count,
    uint32_t *output,
    double *gpu_milliseconds,
    char *error_message, size_t error_message_len
) {
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        bool gpu_coefficient_upload = coefficient_count * sizeof(uint32_t) >= (64u * 1024u * 1024u);
        id<MTLBuffer> coefficient_buffer = [runtime.device newBufferWithLength:gpu_coefficient_upload ? sizeof(uint32_t) : coefficient_count * sizeof(uint32_t)
                                                                      options:MTLResourceStorageModeShared];
        id<MTLBuffer> factor_buffer = [runtime.device newBufferWithBytes:factors
                                                                  length:factor_word_count * sizeof(uint32_t)
                                                                 options:MTLResourceStorageModeShared];
        id<MTLBuffer> task_buffer = [runtime.device newBufferWithBytes:tasks
                                                                length:(NSUInteger)task_count * 5u * sizeof(uint32_t)
                                                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> basis_task_buffer = [runtime.device newBufferWithBytes:basis_tasks
                                                                      length:(NSUInteger)basis_task_count * 4u * sizeof(uint32_t)
                                                                     options:MTLResourceStorageModeShared];
        id<MTLBuffer> basis_buffer = [runtime.device newBufferWithLength:(NSUInteger)basis_count * 4u * sizeof(uint32_t)
                                                                 options:MTLResourceStorageModePrivate];
        id<MTLBuffer> output_buffer = [runtime.device newBufferWithLength:(NSUInteger)output_count * 4u * sizeof(uint32_t)
                                                                 options:MTLResourceStorageModeShared];
        if (coefficient_buffer == nil || factor_buffer == nil || task_buffer == nil ||
            basis_task_buffer == nil || basis_buffer == nil || output_buffer == nil) {
            write_error(error_message, error_message_len, @"Metal polynomial evaluation allocation failed");
            return false;
        }
        if (!gpu_coefficient_upload) {
            uint32_t *coefficient_destination = coefficient_buffer.contents;
            size_t coefficient_cursor = 0;
            for (uint32_t i = 0; i < coefficient_column_count; ++i) {
                memcpy(coefficient_destination + coefficient_cursor, coefficients[i],
                       coefficient_lengths[i] * sizeof(uint32_t));
                coefficient_cursor += coefficient_lengths[i];
            }
        }
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        NSMutableArray<id<MTLBuffer>> *coefficient_sources = [NSMutableArray array];
        id<MTLComputeCommandEncoder> basis_encoder = [command computeCommandEncoder];
        [basis_encoder setComputePipelineState:runtime.polynomialBasis];
        [basis_encoder setBuffer:factor_buffer offset:0 atIndex:0];
        [basis_encoder setBuffer:basis_task_buffer offset:0 atIndex:1];
        [basis_encoder setBytes:&basis_task_count length:sizeof(basis_task_count) atIndex:2];
        [basis_encoder setBuffer:basis_buffer offset:0 atIndex:3];
        NSUInteger basis_width = MIN((NSUInteger)256u, runtime.polynomialBasis.maxTotalThreadsPerThreadgroup);
        [basis_encoder dispatchThreadgroups:MTLSizeMake(basis_task_count, 1, 1)
                      threadsPerThreadgroup:MTLSizeMake(basis_width, 1, 1)];
        [basis_encoder endEncoding];
        NSUInteger width = MIN((NSUInteger)256u, runtime.polynomialEval.maxTotalThreadsPerThreadgroup);
        if (gpu_coefficient_upload) {
            size_t column = 0;
            size_t flat_offset = 0;
            size_t page_size = (size_t)getpagesize();
            const StwoZigPolynomialEvalTask *all_tasks = (const StwoZigPolynomialEvalTask *)tasks;
            while (column < coefficient_column_count) {
                size_t run_start = column;
                size_t run_words = coefficient_lengths[column];
                column += 1;
                while (column < coefficient_column_count && coefficients[column] == coefficients[run_start] + run_words) {
                    run_words += coefficient_lengths[column];
                    column += 1;
                }
                size_t run_bytes = run_words * sizeof(uint32_t);
                uintptr_t address = (uintptr_t)coefficients[run_start];
                bool no_copy = (address % page_size) == 0u && (run_bytes % page_size) == 0u;
                id<MTLBuffer> source = no_copy
                    ? [runtime.device newBufferWithBytesNoCopy:(void *)coefficients[run_start]
                                                        length:run_bytes
                                                       options:MTLResourceStorageModeShared
                                                   deallocator:nil]
                    : [runtime.device newBufferWithBytes:coefficients[run_start]
                                                  length:run_bytes
                                                 options:MTLResourceStorageModeShared];
                NSMutableData *run_task_data = [NSMutableData data];
                for (uint32_t task_index = 0; task_index < task_count; ++task_index) {
                    StwoZigPolynomialEvalTask task = all_tasks[task_index];
                    if ((size_t)task.coefficient_offset >= flat_offset &&
                        (size_t)task.coefficient_offset < flat_offset + run_words) {
                        task.coefficient_offset -= (uint32_t)flat_offset;
                        [run_task_data appendBytes:&task length:sizeof(task)];
                    }
                }
                uint32_t run_task_count = (uint32_t)(run_task_data.length / sizeof(StwoZigPolynomialEvalTask));
                if (source == nil || run_task_count == 0u) {
                    if (source == nil) {
                        write_error(error_message, error_message_len, @"Metal coefficient source allocation failed");
                        return false;
                    }
                    flat_offset += run_words;
                    continue;
                }
                id<MTLBuffer> run_tasks = [runtime.device newBufferWithBytes:run_task_data.bytes
                                                                      length:run_task_data.length
                                                                     options:MTLResourceStorageModeShared];
                [coefficient_sources addObject:source];
                [coefficient_sources addObject:run_tasks];
                id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
                [encoder setComputePipelineState:runtime.polynomialEval];
                [encoder setBuffer:source offset:0 atIndex:0];
                [encoder setBuffer:basis_buffer offset:0 atIndex:1];
                [encoder setBuffer:run_tasks offset:0 atIndex:2];
                [encoder setBytes:&run_task_count length:sizeof(run_task_count) atIndex:3];
                [encoder setBuffer:output_buffer offset:0 atIndex:4];
                [encoder dispatchThreadgroups:MTLSizeMake(run_task_count, 1, 1)
                         threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
                [encoder endEncoding];
                flat_offset += run_words;
            }
        } else {
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:runtime.polynomialEval];
            [encoder setBuffer:coefficient_buffer offset:0 atIndex:0];
            [encoder setBuffer:basis_buffer offset:0 atIndex:1];
            [encoder setBuffer:task_buffer offset:0 atIndex:2];
            [encoder setBytes:&task_count length:sizeof(task_count) atIndex:3];
            [encoder setBuffer:output_buffer offset:0 atIndex:4];
            [encoder dispatchThreadgroups:MTLSizeMake(task_count, 1, 1)
                     threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
            [encoder endEncoding];
        }
        [command commit];
        [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len,
                        command.error.localizedDescription ?: @"Metal polynomial evaluation failed");
            return false;
        }
        memcpy(output, output_buffer.contents, (NSUInteger)output_count * 4u * sizeof(uint32_t));
        if (gpu_milliseconds != NULL) {
            *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        }
        return true;
    }
}

bool stwo_zig_metal_compute_quotients(
    void *runtime_ptr,
    const uint32_t *flat_views, size_t flat_views_len,
    const uint32_t *const *raw_columns,
    const size_t *raw_column_lengths,
    uint32_t raw_column_count,
    const void *views, uint32_t view_count,
    bool raw_views,
    const uint32_t *sample_components,
    const uint32_t *linear_terms,
    uint32_t batch_count,
    const uint32_t *domain_x,
    const uint32_t *domain_y,
    uint32_t row_count,
    uint32_t *output,
    double *gpu_milliseconds,
    char *error_message, size_t error_message_len
) {
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        NSUInteger view_word_count = raw_views ? 9u : 5u;
        id<MTLBuffer> flat_buffer;
        size_t raw_len = 0;
        bool gpu_raw_upload = false;
        if (raw_views) {
            for (uint32_t i = 0; i < raw_column_count; ++i) raw_len += raw_column_lengths[i];
            gpu_raw_upload = raw_len * sizeof(uint32_t) >= (64u * 1024u * 1024u);
            flat_buffer = gpu_raw_upload
                ? [runtime.device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared]
                : [runtime.device newBufferWithLength:raw_len * sizeof(uint32_t) options:MTLResourceStorageModeShared];
            if (!gpu_raw_upload) {
                uint32_t *destination = flat_buffer.contents;
                size_t cursor = 0;
                for (uint32_t i = 0; i < raw_column_count; ++i) {
                    memcpy(destination + cursor, raw_columns[i], raw_column_lengths[i] * sizeof(uint32_t));
                    cursor += raw_column_lengths[i];
                }
            }
        } else {
            flat_buffer = [runtime.device newBufferWithBytes:flat_views
                                                     length:flat_views_len * sizeof(uint32_t)
                                                    options:MTLResourceStorageModeShared];
        }
        id<MTLBuffer> view_buffer = [runtime.device newBufferWithBytes:views
                                                                length:(NSUInteger)view_count * view_word_count * sizeof(uint32_t)
                                                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> sample_buffer = [runtime.device newBufferWithBytes:sample_components
                                                                  length:(NSUInteger)batch_count * 8u * sizeof(uint32_t)
                                                                 options:MTLResourceStorageModeShared];
        id<MTLBuffer> linear_buffer = [runtime.device newBufferWithBytes:linear_terms
                                                                  length:(NSUInteger)batch_count * 8u * sizeof(uint32_t)
                                                                 options:MTLResourceStorageModeShared];
        id<MTLBuffer> x_buffer = [runtime.device newBufferWithBytes:domain_x
                                                             length:(NSUInteger)row_count * sizeof(uint32_t)
                                                            options:MTLResourceStorageModeShared];
        id<MTLBuffer> y_buffer = [runtime.device newBufferWithBytes:domain_y
                                                             length:(NSUInteger)row_count * sizeof(uint32_t)
                                                            options:MTLResourceStorageModeShared];
        size_t output_bytes = (size_t)row_count * 4u * sizeof(uint32_t);
        size_t page_size = (size_t)getpagesize();
        bool direct_output = ((uintptr_t)output % page_size) == 0u && (output_bytes % page_size) == 0u;
        id<MTLBuffer> output_buffer = direct_output
            ? [runtime.device newBufferWithBytesNoCopy:output
                                                length:output_bytes
                                               options:MTLResourceStorageModeShared
                                           deallocator:nil]
            : [runtime.device newBufferWithLength:output_bytes options:MTLResourceStorageModeShared];
        if (flat_buffer == nil || view_buffer == nil || sample_buffer == nil ||
            linear_buffer == nil || x_buffer == nil || y_buffer == nil || output_buffer == nil) {
            write_error(error_message, error_message_len, @"Metal quotient allocation failed");
            return false;
        }

        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        NSMutableArray<id<MTLBuffer>> *raw_sources = [NSMutableArray array];
        if (gpu_raw_upload) {
            id<MTLBuffer> numerators = [runtime.device newBufferWithLength:(NSUInteger)batch_count * row_count * 4u * sizeof(uint32_t)
                                                                   options:MTLResourceStorageModePrivate];
            if (numerators == nil) {
                write_error(error_message, error_message_len, @"Metal quotient numerator allocation failed");
                return false;
            }
            id<MTLBlitCommandEncoder> clear = [command blitCommandEncoder];
            [clear fillBuffer:numerators range:NSMakeRange(0, numerators.length) value:0u];
            [clear endEncoding];
            size_t column = 0;
            size_t flat_offset = 0;
            size_t page_size = (size_t)getpagesize();
            while (column < raw_column_count) {
                size_t run_start = column;
                size_t run_words = raw_column_lengths[column];
                column += 1;
                while (column < raw_column_count && raw_columns[column] == raw_columns[run_start] + run_words) {
                    run_words += raw_column_lengths[column];
                    column += 1;
                }
                size_t run_bytes = run_words * sizeof(uint32_t);
                uintptr_t address = (uintptr_t)raw_columns[run_start];
                bool no_copy = (address % page_size) == 0u && (run_bytes % page_size) == 0u;
                id<MTLBuffer> source = no_copy
                    ? [runtime.device newBufferWithBytesNoCopy:(void *)raw_columns[run_start]
                                                        length:run_bytes
                                                       options:MTLResourceStorageModeShared
                                                   deallocator:nil]
                    : [runtime.device newBufferWithBytes:raw_columns[run_start]
                                                  length:run_bytes
                                                 options:MTLResourceStorageModeShared];
                if (source == nil) {
                    write_error(error_message, error_message_len, @"Metal quotient upload allocation failed");
                    return false;
                }
                [raw_sources addObject:source];
                NSMutableData *run_view_data = [NSMutableData data];
                const StwoZigRawQuotientView *all_views = (const StwoZigRawQuotientView *)views;
                for (uint32_t view_index = 0; view_index < view_count; ++view_index) {
                    StwoZigRawQuotientView view = all_views[view_index];
                    if ((size_t)view.offset >= flat_offset && (size_t)view.offset < flat_offset + run_words) {
                        view.offset -= (uint32_t)flat_offset;
                        [run_view_data appendBytes:&view length:sizeof(view)];
                    }
                }
                uint32_t run_view_count = (uint32_t)(run_view_data.length / sizeof(StwoZigRawQuotientView));
                if (run_view_count != 0u) {
                    id<MTLBuffer> run_views = [runtime.device newBufferWithBytes:run_view_data.bytes
                                                                         length:run_view_data.length
                                                                        options:MTLResourceStorageModeShared];
                    [raw_sources addObject:run_views];
                    id<MTLComputeCommandEncoder> numerator_encoder = [command computeCommandEncoder];
                    [numerator_encoder setComputePipelineState:runtime.quotientNumerator];
                    [numerator_encoder setBuffer:source offset:0 atIndex:0];
                    [numerator_encoder setBuffer:run_views offset:0 atIndex:1];
                    [numerator_encoder setBytes:&run_view_count length:sizeof(run_view_count) atIndex:2];
                    [numerator_encoder setBuffer:numerators offset:0 atIndex:3];
                    [numerator_encoder setBytes:&batch_count length:sizeof(batch_count) atIndex:4];
                    [numerator_encoder setBytes:&row_count length:sizeof(row_count) atIndex:5];
                    NSUInteger numerator_width = MIN(runtime.quotientNumerator.maxTotalThreadsPerThreadgroup,
                                                     runtime.quotientNumerator.threadExecutionWidth * 8u);
                    [numerator_encoder dispatchThreads:MTLSizeMake(row_count, 1u, 1u)
                                 threadsPerThreadgroup:MTLSizeMake(numerator_width, 1u, 1u)];
                    [numerator_encoder endEncoding];
                }
                flat_offset += run_words;
            }
            id<MTLComputeCommandEncoder> finalize = [command computeCommandEncoder];
            [finalize setComputePipelineState:runtime.quotientFinalize];
            [finalize setBuffer:numerators offset:0 atIndex:0];
            [finalize setBuffer:sample_buffer offset:0 atIndex:1];
            [finalize setBuffer:linear_buffer offset:0 atIndex:2];
            [finalize setBytes:&batch_count length:sizeof(batch_count) atIndex:3];
            [finalize setBuffer:x_buffer offset:0 atIndex:4];
            [finalize setBuffer:y_buffer offset:0 atIndex:5];
            [finalize setBuffer:output_buffer offset:0 atIndex:6];
            [finalize setBytes:&row_count length:sizeof(row_count) atIndex:7];
            NSUInteger finalize_width = MIN(runtime.quotientFinalize.maxTotalThreadsPerThreadgroup,
                                            runtime.quotientFinalize.threadExecutionWidth * 8u);
            [finalize dispatchThreads:MTLSizeMake(row_count, 1u, 1u)
                   threadsPerThreadgroup:MTLSizeMake(finalize_width, 1u, 1u)];
            [finalize endEncoding];
        } else {
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            id<MTLComputePipelineState> quotient_pipeline = raw_views ? runtime.rawQuotients : runtime.quotients;
            [encoder setComputePipelineState:quotient_pipeline];
            [encoder setBuffer:flat_buffer offset:0 atIndex:0];
            [encoder setBuffer:view_buffer offset:0 atIndex:1];
            [encoder setBytes:&view_count length:sizeof(view_count) atIndex:2];
            [encoder setBuffer:sample_buffer offset:0 atIndex:3];
            [encoder setBuffer:linear_buffer offset:0 atIndex:4];
            [encoder setBytes:&batch_count length:sizeof(batch_count) atIndex:5];
            [encoder setBuffer:x_buffer offset:0 atIndex:6];
            [encoder setBuffer:y_buffer offset:0 atIndex:7];
            [encoder setBuffer:output_buffer offset:0 atIndex:8];
            [encoder setBytes:&row_count length:sizeof(row_count) atIndex:9];
            NSUInteger width = MIN(quotient_pipeline.maxTotalThreadsPerThreadgroup,
                                   quotient_pipeline.threadExecutionWidth * 8u);
            [encoder dispatchThreads:MTLSizeMake(row_count, 1, 1)
                    threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
            [encoder endEncoding];
        }
        [command commit];
        [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len,
                        command.error.localizedDescription ?: @"Metal quotient execution failed");
            return false;
        }
        if (!direct_output) memcpy(output, output_buffer.contents, output_bytes);
        if (gpu_milliseconds != NULL) {
            *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        }
        return true;
    }
}

void stwo_zig_metal_runtime_destroy(void *runtime) {
    if (runtime == NULL) return;
    @autoreleasepool { __unused id value = (__bridge_transfer id)runtime; }
}

void *stwo_zig_metal_merkle_commit(
    void *runtime_ptr,
    const uint32_t *const *columns,
    const size_t *column_lengths,
    const uint32_t *column_log_sizes,
    uint32_t column_count,
    uint32_t lifting_log_size,
    const uint32_t *leaf_seed,
    const uint32_t *node_seed,
    char *error_message,
    size_t error_message_len
) {
    @autoreleasepool {
        if (runtime_ptr == NULL || columns == NULL || column_lengths == NULL || column_count == 0 ||
            lifting_log_size >= 31u) {
            write_error(error_message, error_message_len, @"Invalid Metal Merkle arguments");
            return NULL;
        }
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        size_t flat_len = 0;
        for (uint32_t column = 0; column < column_count; ++column) {
            if (column_log_sizes[column] > lifting_log_size ||
                column_lengths[column] != ((size_t)1u << column_log_sizes[column])) {
                write_error(error_message, error_message_len, @"Invalid Metal column shape");
                return NULL;
            }
            flat_len += column_lengths[column];
        }
        NSUInteger flat_bytes = flat_len * sizeof(uint32_t);
        bool gpu_upload = flat_bytes >= (64u * 1024u * 1024u) && column_count >= 16u;
        id<MTLBuffer> staging = [runtime.device newBufferWithLength:flat_bytes
                                                            options:gpu_upload ? MTLResourceStorageModePrivate : MTLResourceStorageModeShared];
        id<MTLBuffer> offsets = [runtime.device newBufferWithLength:column_count * sizeof(uint32_t)
                                                            options:MTLResourceStorageModeShared];
        id<MTLBuffer> log_sizes = [runtime.device newBufferWithBytes:column_log_sizes
                                                              length:column_count * sizeof(uint32_t)
                                                             options:MTLResourceStorageModeShared];
        id<MTLBuffer> leaf_seed_buffer = [runtime.device newBufferWithBytes:leaf_seed
                                                                     length:8u * sizeof(uint32_t)
                                                                    options:MTLResourceStorageModeShared];
        id<MTLBuffer> node_seed_buffer = [runtime.device newBufferWithBytes:node_seed
                                                                     length:8u * sizeof(uint32_t)
                                                                    options:MTLResourceStorageModeShared];
        if (staging == nil || offsets == nil || log_sizes == nil ||
            leaf_seed_buffer == nil || node_seed_buffer == nil) {
            write_error(error_message, error_message_len, @"Metal Merkle allocation failed");
            return NULL;
        }
        uint32_t *offset_values = offsets.contents;
        uint32_t *staging_values = gpu_upload ? NULL : staging.contents;
        size_t cursor = 0;
        for (uint32_t column = 0; column < column_count; ++column) {
            if (cursor > UINT32_MAX) {
                write_error(error_message, error_message_len, @"Metal column arena exceeds u32 offsets");
                return NULL;
            }
            offset_values[column] = (uint32_t)cursor;
            if (!gpu_upload) memcpy(staging_values + cursor, columns[column], column_lengths[column] * sizeof(uint32_t));
            cursor += column_lengths[column];
        }

        uint32_t leaf_count = 1u << lifting_log_size;
        NSMutableArray<id<MTLBuffer>> *layers = [NSMutableArray arrayWithCapacity:lifting_log_size + 1u];
        uint32_t layer_count = leaf_count;
        for (uint32_t level = 0; level <= lifting_log_size; ++level) {
            MTLResourceOptions storage = level == lifting_log_size
                ? MTLResourceStorageModeShared
                : MTLResourceStorageModePrivate;
            id<MTLBuffer> layer = [runtime.device newBufferWithLength:(NSUInteger)layer_count * 32u
                                                              options:storage];
            if (layer == nil) {
                write_error(error_message, error_message_len, @"Metal Merkle layer allocation failed");
                return NULL;
            }
            [layers addObject:layer];
            layer_count >>= 1u;
        }

        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        NSMutableArray<id<MTLBuffer>> *upload_sources = [NSMutableArray array];
        if (gpu_upload) {
            id<MTLBlitCommandEncoder> upload = [command blitCommandEncoder];
            size_t column = 0;
            size_t destination_words = 0;
            size_t page_size = (size_t)getpagesize();
            while (column < column_count) {
                size_t run_start = column;
                size_t run_words = column_lengths[column];
                column += 1;
                while (column < column_count && columns[column] == columns[run_start] + run_words) {
                    run_words += column_lengths[column];
                    column += 1;
                }
                size_t run_bytes = run_words * sizeof(uint32_t);
                uintptr_t address = (uintptr_t)columns[run_start];
                bool no_copy = (address % page_size) == 0u && (run_bytes % page_size) == 0u;
                id<MTLBuffer> source = no_copy
                    ? [runtime.device newBufferWithBytesNoCopy:(void *)columns[run_start]
                                                        length:run_bytes
                                                       options:MTLResourceStorageModeShared
                                                   deallocator:nil]
                    : [runtime.device newBufferWithBytes:columns[run_start]
                                                  length:run_bytes
                                                 options:MTLResourceStorageModeShared];
                if (source == nil) {
                    write_error(error_message, error_message_len, @"Metal commitment upload allocation failed");
                    return NULL;
                }
                [upload_sources addObject:source];
                [upload copyFromBuffer:source sourceOffset:0 toBuffer:staging
                     destinationOffset:destination_words * sizeof(uint32_t) size:run_bytes];
                destination_words += run_words;
            }
            [upload endEncoding];
        }
        id<MTLComputeCommandEncoder> leaf_encoder = [command computeCommandEncoder];
        [leaf_encoder setComputePipelineState:runtime.leaves];
        [leaf_encoder setBuffer:staging offset:0 atIndex:0];
        [leaf_encoder setBuffer:offsets offset:0 atIndex:1];
        [leaf_encoder setBuffer:log_sizes offset:0 atIndex:2];
        [leaf_encoder setBuffer:layers[0] offset:0 atIndex:3];
        [leaf_encoder setBytes:&column_count length:sizeof(column_count) atIndex:4];
        [leaf_encoder setBytes:&lifting_log_size length:sizeof(lifting_log_size) atIndex:5];
        [leaf_encoder setBuffer:leaf_seed_buffer offset:0 atIndex:6];
        NSUInteger leaf_width = MIN(runtime.leaves.maxTotalThreadsPerThreadgroup,
                                    runtime.leaves.threadExecutionWidth * 8u);
        [leaf_encoder dispatchThreads:MTLSizeMake(leaf_count, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(leaf_width, 1, 1)];
        [leaf_encoder endEncoding];

        uint32_t parents = leaf_count >> 1u;
        for (uint32_t level = 1; level <= lifting_log_size; ++level) {
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:runtime.parents];
            [encoder setBuffer:layers[level - 1u] offset:0 atIndex:0];
            [encoder setBuffer:layers[level] offset:0 atIndex:1];
            [encoder setBytes:&parents length:sizeof(parents) atIndex:2];
            [encoder setBuffer:node_seed_buffer offset:0 atIndex:3];
            NSUInteger width = MIN(runtime.parents.maxTotalThreadsPerThreadgroup,
                                   runtime.parents.threadExecutionWidth * 8u);
            [encoder dispatchThreads:MTLSizeMake(parents, 1, 1)
                    threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
            [encoder endEncoding];
            parents >>= 1u;
        }

        [command commit];
        [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len,
                        command.error.localizedDescription ?: @"Metal Merkle execution failed");
            return NULL;
        }

        StwoZigMetalTree *tree = [StwoZigMetalTree new];
        tree.layers = layers;
        tree.rootReadback = layers.lastObject;
        tree.logSize = lifting_log_size;
        tree.gpuMilliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return (__bridge_retained void *)tree;
    }
}

void stwo_zig_metal_tree_destroy(void *tree) {
    if (tree == NULL) return;
    @autoreleasepool { __unused id value = (__bridge_transfer id)tree; }
}

bool stwo_zig_metal_tree_root(void *tree_ptr, uint8_t *root, double *gpu_milliseconds) {
    if (tree_ptr == NULL || root == NULL) return false;
    @autoreleasepool {
        StwoZigMetalTree *tree = (__bridge StwoZigMetalTree *)tree_ptr;
        memcpy(root, tree.rootReadback.contents, 32u);
        if (gpu_milliseconds != NULL) *gpu_milliseconds = tree.gpuMilliseconds;
        return true;
    }
}

bool stwo_zig_metal_tree_copy_layers(
    void *runtime_ptr,
    void *tree_ptr,
    uint8_t *destination,
    size_t destination_len,
    char *error_message,
    size_t error_message_len
) {
    if (runtime_ptr == NULL || tree_ptr == NULL || destination == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigMetalTree *tree = (__bridge StwoZigMetalTree *)tree_ptr;
        size_t required = ((((size_t)1u) << (tree.logSize + 1u)) - 1u) * 32u;
        if (destination_len != required) {
            write_error(error_message, error_message_len, @"Metal layer readback size mismatch");
            return false;
        }
        id<MTLBuffer> readback = [runtime.device newBufferWithLength:required
                                                            options:MTLResourceStorageModeShared];
        if (readback == nil) {
            write_error(error_message, error_message_len, @"Metal layer readback allocation failed");
            return false;
        }
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        size_t offset = 0;
        for (NSInteger level = (NSInteger)tree.logSize; level >= 0; --level) {
            id<MTLBuffer> layer = tree.layers[(NSUInteger)level];
            [blit copyFromBuffer:layer sourceOffset:0 toBuffer:readback
               destinationOffset:offset size:layer.length];
            offset += layer.length;
        }
        [blit endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len,
                        command.error.localizedDescription ?: @"Metal layer readback failed");
            return false;
        }
        memcpy(destination, readback.contents, required);
        return true;
    }
}

bool stwo_zig_metal_tree_copy_hashes(
    void *runtime_ptr,
    void *tree_ptr,
    uint32_t layer_log_size,
    const uint32_t *indices,
    uint32_t index_count,
    uint8_t *destination,
    char *error_message,
    size_t error_message_len
) {
    if (runtime_ptr == NULL || tree_ptr == NULL || indices == NULL || destination == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigMetalTree *tree = (__bridge StwoZigMetalTree *)tree_ptr;
        if (layer_log_size > tree.logSize) {
            write_error(error_message, error_message_len, @"Invalid Metal layer log size");
            return false;
        }
        uint32_t layer_count = 1u << layer_log_size;
        for (uint32_t i = 0; i < index_count; ++i) {
            if (indices[i] >= layer_count) {
                write_error(error_message, error_message_len, @"Invalid Metal layer hash index");
                return false;
            }
        }

        id<MTLBuffer> source = tree.layers[(NSUInteger)(tree.logSize - layer_log_size)];
        id<MTLBuffer> readback = [runtime.device newBufferWithLength:(NSUInteger)index_count * 32u
                                                            options:MTLResourceStorageModeShared];
        if (readback == nil) {
            write_error(error_message, error_message_len, @"Metal selective readback allocation failed");
            return false;
        }
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        for (uint32_t i = 0; i < index_count; ++i) {
            [blit copyFromBuffer:source sourceOffset:(NSUInteger)indices[i] * 32u
                       toBuffer:readback destinationOffset:(NSUInteger)i * 32u size:32u];
        }
        [blit endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len,
                        command.error.localizedDescription ?: @"Metal selective hash readback failed");
            return false;
        }
        memcpy(destination, readback.contents, (NSUInteger)index_count * 32u);
        return true;
    }
}
