static void stwo_zig_metal_dynamic_cache_stats(
    StwoZigMetalRuntime *runtime,
    StwoZigPipelineCacheStats *stats
);

bool stwo_zig_metal_pipeline_cache_stats(
    void *runtime_ptr, StwoZigPipelineCacheStats *stats
) {
    if (runtime_ptr == NULL || stats == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        @synchronized(runtime) {
            stats->library_cache_hits = runtime.evalLibraryCacheHits;
            stats->library_cache_misses = runtime.evalLibraryCacheMisses;
            stats->pipeline_cache_hits = runtime.evalPipelineCacheHits;
            stats->binary_archive_hits = runtime.evalBinaryArchiveHits;
            stats->binary_archive_misses = runtime.evalBinaryArchiveMisses;
            stats->direct_compiles = runtime.evalDirectCompiles;
            stats->archive_populations = runtime.evalArchivePopulations;
            stats->archive_serializations = runtime.evalArchiveSerializations;
            stats->pipeline_preparation_seconds = runtime.evalPipelinePreparationSeconds;
            stats->library_preparation_seconds = runtime.evalLibraryPreparationSeconds;
            stwo_zig_metal_dynamic_cache_stats(runtime, stats);
        }
        return true;
    }
}

uint64_t stwo_zig_metal_max_buffer_length(void *runtime_ptr) {
    if (runtime_ptr == NULL) return 0u;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        return (uint64_t)runtime.device.maxBufferLength;
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
