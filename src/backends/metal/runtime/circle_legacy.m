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
