bool stwo_zig_metal_clear_arena_ranges(
    void *runtime_ptr, void *arena_ptr, const uint32_t *ranges, uint32_t range_count,
    uint32_t max_length, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || ranges == NULL || range_count == 0u) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        (void)max_length;
        for (uint32_t index = 0; index < range_count; ++index) {
            uint64_t offset = (uint64_t)ranges[(size_t)index * 2u] * sizeof(uint32_t);
            uint64_t bytes = (uint64_t)ranges[(size_t)index * 2u + 1u] * sizeof(uint32_t);
            if (offset > arena.length || bytes > arena.length - offset) {
                write_error(error_message, error_message_len, @"Metal arena clear range exceeds arena");
                return false;
            }
        }
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        for (uint32_t index = 0; index < range_count; ++index) {
            NSUInteger offset = (NSUInteger)ranges[(size_t)index * 2u] * sizeof(uint32_t);
            NSUInteger bytes = (NSUInteger)ranges[(size_t)index * 2u + 1u] * sizeof(uint32_t);
            if (bytes != 0u) [blit fillBuffer:arena range:NSMakeRange(offset, bytes) value:0u];
        }
        [blit endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        return true;
    }
}

void *stwo_zig_metal_arena_copy_prepare(
    void *runtime_ptr, const StwoZigArenaCopyRange *ranges, uint32_t range_count,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || ranges == NULL || range_count == 0u) return NULL;
    @autoreleasepool {
        StwoZigArenaCopyPlan *plan = [StwoZigArenaCopyPlan new];
        plan.ranges = [NSData dataWithBytes:ranges length:(NSUInteger)range_count * sizeof(StwoZigArenaCopyRange)];
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

static bool encode_arena_copy_prepared(
    id<MTLBuffer> arena, StwoZigArenaCopyPlan *plan, id<MTLCommandBuffer> command,
    uint64_t *blit_encoders, char *error_message, size_t error_message_len
) {
    if (arena == nil || plan == nil || command == nil) return false;
    const StwoZigArenaCopyRange *ranges = plan.ranges.bytes;
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    if (blit == nil) return false;
    for (uint32_t index = 0; index < plan.rangeCount; ++index) {
        NSUInteger source = (NSUInteger)ranges[index].source_word_offset * sizeof(uint32_t);
        NSUInteger destination = (NSUInteger)ranges[index].destination_word_offset * sizeof(uint32_t);
        NSUInteger bytes = (NSUInteger)ranges[index].word_count * sizeof(uint32_t);
        if (bytes == 0u || source + bytes > arena.length || destination + bytes > arena.length) {
            [blit endEncoding];
            write_error(error_message, error_message_len, @"Metal arena copy range exceeds arena");
            return false;
        }
        [blit copyFromBuffer:arena sourceOffset:source toBuffer:arena destinationOffset:destination size:bytes];
    }
    [blit endEncoding];
    *blit_encoders += 1u;
    return true;
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
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        uint64_t blit_encoders = 0u;
        if (!encode_arena_copy_prepared(arena, plan, command, &blit_encoders, error_message, error_message_len)) return false;
        [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len, command.error.localizedDescription);
            return false;
        }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

bool stwo_zig_metal_prepared_state_transfer(
    void *runtime_ptr, void *arena_ptr, void *snapshot_ptr,
    const StwoZigPreparedStateRange *ranges, uint32_t range_count,
    bool capture, bool clear_arena, double *gpu_milliseconds,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || snapshot_ptr == NULL ||
        ranges == NULL || range_count == 0u || (capture && clear_arena)) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        id<MTLBuffer> snapshot = (__bridge id<MTLBuffer>)snapshot_ptr;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        if (!capture && clear_arena)
            [blit fillBuffer:arena range:NSMakeRange(0u, arena.length) value:0u];
        for (uint32_t index = 0; index < range_count; ++index) {
            const uint64_t arena_offset = ranges[index].arena_byte_offset;
            const uint64_t snapshot_offset = ranges[index].snapshot_byte_offset;
            const uint64_t bytes = ranges[index].byte_count;
            if (bytes == 0u || arena_offset > arena.length || bytes > arena.length - arena_offset ||
                snapshot_offset > snapshot.length || bytes > snapshot.length - snapshot_offset) {
                [blit endEncoding];
                write_error(error_message, error_message_len, @"Prepared-state range exceeds a Metal buffer");
                return false;
            }
            if (capture) {
                [blit copyFromBuffer:arena sourceOffset:(NSUInteger)arena_offset
                            toBuffer:snapshot destinationOffset:(NSUInteger)snapshot_offset
                                size:(NSUInteger)bytes];
            } else {
                [blit copyFromBuffer:snapshot sourceOffset:(NSUInteger)snapshot_offset
                            toBuffer:arena destinationOffset:(NSUInteger)arena_offset
                                size:(NSUInteger)bytes];
            }
        }
        [blit endEncoding];
        [command commit];
        [command waitUntilCompleted];
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

bool stwo_zig_metal_witness_feed_batch_clear_prepared(
    void *runtime_ptr, void *arena_ptr, void *batch_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || batch_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigWitnessFeedBatch *batch = (__bridge StwoZigWitnessFeedBatch *)batch_ptr;
        uint32_t clear_range_count = batch.clearRangeCount, clear_total_words = batch.clearTotalWords;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.clearArenaSpans];
        [encoder setBuffer:arena offset:0 atIndex:0]; [encoder setBuffer:batch.clearSpans offset:0 atIndex:1];
        [encoder setBytes:&clear_range_count length:sizeof(clear_range_count) atIndex:2]; [encoder setBytes:&clear_total_words length:sizeof(clear_total_words) atIndex:3];
        NSUInteger width = MIN(runtime.clearArenaSpans.maxTotalThreadsPerThreadgroup, runtime.clearArenaSpans.threadExecutionWidth * 8u);
        [encoder dispatchThreads:MTLSizeMake(clear_total_words, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

bool stwo_zig_metal_witness_feed_batch_index_prepared(
    void *runtime_ptr, void *arena_ptr, void *batch_ptr, uint32_t index,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || batch_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigWitnessFeedBatch *batch = (__bridge StwoZigWitnessFeedBatch *)batch_ptr;
        if (index >= batch.plans.count) { write_error(error_message, error_message_len, @"Metal witness feed batch index is out of range"); return false; }
        const uint32_t *column_lengths = batch.columnLengths.bytes;
        StwoZigWitnessFeedPlan *plan = batch.plans[index];
        uint32_t descriptor_count = plan.descriptorCount, column_length = column_lengths[index];
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
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
