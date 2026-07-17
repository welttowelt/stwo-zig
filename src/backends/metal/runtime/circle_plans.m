void *stwo_zig_metal_circle_lde_prepare(
    void *runtime_ptr, const uint64_t *source_offsets, const uint64_t *destination_offsets,
    uint32_t column_count, uint32_t base_log_size, uint32_t extended_log_size,
    uint32_t twiddle_offset_words, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || source_offsets == NULL || destination_offsets == NULL || column_count == 0u ||
        base_log_size < 3u || extended_log_size <= base_log_size || extended_log_size >= 31u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigCircleLdePlan *plan = [StwoZigCircleLdePlan new];
        plan.sourceOffsets = [runtime.device newBufferWithBytes:source_offsets length:(NSUInteger)column_count * sizeof(uint64_t) options:MTLResourceStorageModeShared];
        plan.destinationOffsets = [runtime.device newBufferWithBytes:destination_offsets length:(NSUInteger)column_count * sizeof(uint64_t) options:MTLResourceStorageModeShared];
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

static bool encode_circle_lde_prepared(
    StwoZigMetalRuntime *runtime, id<MTLBuffer> arena, StwoZigCircleLdePlan *plan,
    id<MTLCommandBuffer> command, uint64_t *compute_encoders, uint64_t *dispatches
) {
        if (runtime == nil || arena == nil || plan == nil || command == nil) return false;
        uint32_t column_count = plan.columnCount, base_log_size = plan.baseLogSize, extended_log_size = plan.extendedLogSize;
        uint32_t extended_len = 1u << extended_log_size, extended_pairs = extended_len >> 1u;
        id<MTLComputeCommandEncoder> expand = [command computeCommandEncoder];
        if (expand == nil) return false;
        [expand setComputePipelineState:runtime.circleExpandSparse];
        [expand setBuffer:arena offset:0 atIndex:0]; [expand setBuffer:plan.sourceOffsets offset:0 atIndex:1];
        [expand setBuffer:plan.destinationOffsets offset:0 atIndex:2]; [expand setBytes:&base_log_size length:sizeof(base_log_size) atIndex:3];
        [expand setBytes:&extended_log_size length:sizeof(extended_log_size) atIndex:4]; [expand setBytes:&column_count length:sizeof(column_count) atIndex:5];
        NSUInteger expand_width = MIN((NSUInteger)256u, runtime.circleExpandSparse.maxTotalThreadsPerThreadgroup);
        [expand dispatchThreads:MTLSizeMake(extended_len, column_count, 1u) threadsPerThreadgroup:MTLSizeMake(expand_width, 1u, 1u)];
        [expand endEncoding];
        *compute_encoders += 1u; *dispatches += 1u;
        MTLSize grid = MTLSizeMake(extended_pairs, column_count, 1u);
        for (uint32_t layer = extended_log_size - 1u; layer > 0u; --layer) {
            uint32_t twiddle_offset = extended_pairs - (1u << (extended_log_size - layer));
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            if (encoder == nil) return false;
            [encoder setComputePipelineState:runtime.circleRfftLayerSparseWide];
            [encoder setBuffer:arena offset:0 atIndex:0]; [encoder setBuffer:plan.destinationOffsets offset:0 atIndex:1];
            [encoder setBuffer:arena offset:plan.twiddleByteOffset atIndex:2]; [encoder setBytes:&extended_log_size length:sizeof(extended_log_size) atIndex:3];
            [encoder setBytes:&layer length:sizeof(layer) atIndex:4]; [encoder setBytes:&twiddle_offset length:sizeof(twiddle_offset) atIndex:5];
            [encoder setBytes:&column_count length:sizeof(column_count) atIndex:6];
            NSUInteger width = MIN((NSUInteger)256u, runtime.circleRfftLayerSparseWide.maxTotalThreadsPerThreadgroup);
            [encoder dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
            [encoder endEncoding];
            *compute_encoders += 1u; *dispatches += 1u;
        }
        id<MTLComputeCommandEncoder> last = [command computeCommandEncoder];
        if (last == nil) return false;
        [last setComputePipelineState:runtime.circleRfftLastSparseWide];
        [last setBuffer:arena offset:0 atIndex:0]; [last setBuffer:plan.destinationOffsets offset:0 atIndex:1];
        [last setBuffer:arena offset:plan.twiddleByteOffset atIndex:2]; [last setBytes:&extended_log_size length:sizeof(extended_log_size) atIndex:3];
        [last setBytes:&column_count length:sizeof(column_count) atIndex:4];
        NSUInteger last_width = MIN((NSUInteger)256u, runtime.circleRfftLastSparseWide.maxTotalThreadsPerThreadgroup);
        [last dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(last_width, 1u, 1u)];
        [last endEncoding];
        *compute_encoders += 1u; *dispatches += 1u;
        return true;
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
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        uint64_t compute_encoders = 0u, dispatches = 0u;
        if (!encode_circle_lde_prepared(runtime, arena, plan, command, &compute_encoders, &dispatches)) {
            write_error(error_message, error_message_len, @"Metal sparse circle LDE encoding failed"); return false;
        }
        [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_circle_ifft_prepare(
    void *runtime_ptr, const uint64_t *source_offsets, const uint64_t *destination_offsets,
    uint32_t column_count, uint32_t log_size, uint32_t twiddle_offset_words,
    uint32_t scale_factor, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || source_offsets == NULL || destination_offsets == NULL ||
        column_count == 0u || log_size < 3u || log_size >= 31u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigCircleIfftPlan *plan = [StwoZigCircleIfftPlan new];
        plan.sourceOffsets = [runtime.device newBufferWithBytes:source_offsets length:(NSUInteger)column_count * sizeof(uint64_t) options:MTLResourceStorageModeShared];
        plan.destinationOffsets = [runtime.device newBufferWithBytes:destination_offsets length:(NSUInteger)column_count * sizeof(uint64_t) options:MTLResourceStorageModeShared];
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

static bool encode_circle_ifft_prepared(
    StwoZigMetalRuntime *runtime, id<MTLBuffer> arena, StwoZigCircleIfftPlan *plan,
    id<MTLCommandBuffer> command, uint64_t *compute_encoders, uint64_t *dispatches
) {
        if (runtime == nil || arena == nil || plan == nil || command == nil) return false;
        uint32_t column_count = plan.columnCount, log_size = plan.logSize;
        uint32_t length = 1u << log_size, pair_count = length >> 1u;
        MTLSize values_grid = MTLSizeMake(length, column_count, 1u);
        MTLSize pairs_grid = MTLSizeMake(pair_count, column_count, 1u);

        id<MTLComputeCommandEncoder> copy = [command computeCommandEncoder];
        if (copy == nil) return false;
        [copy setComputePipelineState:runtime.circleCopySparse];
        [copy setBuffer:arena offset:0 atIndex:0]; [copy setBuffer:plan.sourceOffsets offset:0 atIndex:1];
        [copy setBuffer:plan.destinationOffsets offset:0 atIndex:2]; [copy setBytes:&log_size length:sizeof(log_size) atIndex:3];
        [copy setBytes:&column_count length:sizeof(column_count) atIndex:4];
        NSUInteger copy_width = MIN((NSUInteger)256u, runtime.circleCopySparse.maxTotalThreadsPerThreadgroup);
        [copy dispatchThreads:values_grid threadsPerThreadgroup:MTLSizeMake(copy_width, 1u, 1u)];
        [copy endEncoding];
        *compute_encoders += 1u; *dispatches += 1u;

        id<MTLComputeCommandEncoder> first = [command computeCommandEncoder];
        if (first == nil) return false;
        [first setComputePipelineState:runtime.circleIfftFirstSparse];
        [first setBuffer:arena offset:0 atIndex:0]; [first setBuffer:plan.destinationOffsets offset:0 atIndex:1];
        [first setBuffer:arena offset:plan.twiddleByteOffset atIndex:2]; [first setBytes:&log_size length:sizeof(log_size) atIndex:3];
        [first setBytes:&column_count length:sizeof(column_count) atIndex:4];
        NSUInteger first_width = MIN((NSUInteger)256u, runtime.circleIfftFirstSparse.maxTotalThreadsPerThreadgroup);
        [first dispatchThreads:pairs_grid threadsPerThreadgroup:MTLSizeMake(first_width, 1u, 1u)];
        [first endEncoding];
        *compute_encoders += 1u; *dispatches += 1u;

        for (uint32_t layer = 1u; layer < log_size; ++layer) {
            uint32_t twiddle_offset = pair_count - (1u << (log_size - layer));
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            if (encoder == nil) return false;
            [encoder setComputePipelineState:runtime.circleIfftLayerSparse];
            [encoder setBuffer:arena offset:0 atIndex:0]; [encoder setBuffer:plan.destinationOffsets offset:0 atIndex:1];
            [encoder setBuffer:arena offset:plan.twiddleByteOffset atIndex:2]; [encoder setBytes:&log_size length:sizeof(log_size) atIndex:3];
            [encoder setBytes:&layer length:sizeof(layer) atIndex:4]; [encoder setBytes:&twiddle_offset length:sizeof(twiddle_offset) atIndex:5];
            [encoder setBytes:&column_count length:sizeof(column_count) atIndex:6];
            NSUInteger width = MIN((NSUInteger)256u, runtime.circleIfftLayerSparse.maxTotalThreadsPerThreadgroup);
            [encoder dispatchThreads:pairs_grid threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
            [encoder endEncoding];
            *compute_encoders += 1u; *dispatches += 1u;
        }

        uint32_t scale_factor = plan.scaleFactor;
        id<MTLComputeCommandEncoder> rescale = [command computeCommandEncoder];
        if (rescale == nil) return false;
        [rescale setComputePipelineState:runtime.circleRescaleSparse];
        [rescale setBuffer:arena offset:0 atIndex:0]; [rescale setBuffer:plan.destinationOffsets offset:0 atIndex:1];
        [rescale setBytes:&log_size length:sizeof(log_size) atIndex:2]; [rescale setBytes:&column_count length:sizeof(column_count) atIndex:3];
        [rescale setBytes:&scale_factor length:sizeof(scale_factor) atIndex:4];
        NSUInteger rescale_width = MIN((NSUInteger)256u, runtime.circleRescaleSparse.maxTotalThreadsPerThreadgroup);
        [rescale dispatchThreads:values_grid threadsPerThreadgroup:MTLSizeMake(rescale_width, 1u, 1u)];
        [rescale endEncoding];
        *compute_encoders += 1u; *dispatches += 1u;
        return true;
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
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        uint64_t compute_encoders = 0u, dispatches = 0u;
        if (!encode_circle_ifft_prepared(runtime, arena, plan, command, &compute_encoders, &dispatches)) {
            write_error(error_message, error_message_len, @"Metal sparse circle IFFT encoding failed"); return false;
        }
        [command commit]; [command waitUntilCompleted];
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
