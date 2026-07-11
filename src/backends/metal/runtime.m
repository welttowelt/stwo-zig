#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdbool.h>
#include <stdint.h>
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
        if (runtime.queue == nil || runtime.leaves == nil || runtime.parents == nil ||
            runtime.quotients == nil || runtime.rawQuotients == nil || runtime.polynomialEval == nil ||
            runtime.polynomialBasis == nil || runtime.circleIfftFirst == nil || runtime.circleIfftLayer == nil ||
            runtime.circleRfftLayer == nil || runtime.circleRfftLast == nil || runtime.circleRescale == nil ||
            runtime.circleExpand == nil || runtime.circleIfftFused == nil || runtime.circleRfftFused == nil ||
            runtime.quotientNumerator == nil || runtime.quotientFinalize == nil) return NULL;
        return (__bridge_retained void *)runtime;
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
