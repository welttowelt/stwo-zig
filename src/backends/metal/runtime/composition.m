void *stwo_zig_metal_composition_lde_prepare(
    void *runtime_ptr, const uint64_t *source_offsets, const uint32_t *source_logs,
    const uint32_t *destination_offsets, uint32_t column_count, uint32_t extended_log,
    uint32_t twiddle_offset_words, bool use_radix4,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || source_offsets == NULL || source_logs == NULL || destination_offsets == NULL ||
        column_count == 0u || extended_log < 3u || extended_log >= 31u) return NULL;
    for (uint32_t i = 0; i < column_count; ++i) if (source_logs[i] < 3u || source_logs[i] > extended_log) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigCompositionLdePlan *plan = [StwoZigCompositionLdePlan new];
        plan.sourceOffsets = [runtime.device newBufferWithBytes:source_offsets length:column_count * sizeof(uint64_t) options:MTLResourceStorageModeShared];
        plan.sourceLogs = [runtime.device newBufferWithBytes:source_logs length:column_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.destinationOffsets = [runtime.device newBufferWithBytes:destination_offsets length:column_count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.columnCount = column_count; plan.extendedLog = extended_log;
        plan.twiddleByteOffset = (NSUInteger)twiddle_offset_words * sizeof(uint32_t);
        plan.useRadix4 = use_radix4;
        if (plan.sourceOffsets == nil || plan.sourceLogs == nil || plan.destinationOffsets == nil) {
            write_error(error_message, error_message_len, @"Metal composition LDE plan allocation failed"); return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_composition_lde_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

static bool encode_composition_lde_counted(
    StwoZigMetalRuntime *runtime, id<MTLBuffer> arena,
    StwoZigCompositionLdePlan *plan, id<MTLCommandBuffer> command,
    uint64_t *compute_encoders, uint64_t *dispatches
) {
    if (runtime == nil || arena == nil || plan == nil || command == nil) return false;
    uint32_t log_size = plan.extendedLog, columns = plan.columnCount;
    uint32_t rows = 1u << log_size, pairs = rows >> 1u;
    id<MTLComputeCommandEncoder> expand = [command computeCommandEncoder];
    if (expand == nil) return false;
    [expand setComputePipelineState:runtime.compositionExpand]; [expand setBuffer:arena offset:0 atIndex:0];
    [expand setBuffer:plan.sourceOffsets offset:0 atIndex:1]; [expand setBuffer:plan.sourceLogs offset:0 atIndex:2];
    [expand setBuffer:plan.destinationOffsets offset:0 atIndex:3]; [expand setBytes:&log_size length:sizeof(log_size) atIndex:4];
    [expand setBytes:&columns length:sizeof(columns) atIndex:5];
    [expand dispatchThreads:MTLSizeMake(rows, columns, 1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.compositionExpand.maxTotalThreadsPerThreadgroup), 1u, 1u)];
    [expand endEncoding];
    *compute_encoders += 1u; *dispatches += 1u;
    MTLSize grid = MTLSizeMake(pairs, columns, 1u);
    uint32_t forward_stop_layer = log_size >= 11u ? 10u : 0u;
    uint32_t layer = log_size - 1u;
    while (layer > forward_stop_layer) {
        if (plan.useRadix4 && layer >= 12u) {
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            if (encoder == nil) return false;
            [encoder setComputePipelineState:runtime.circleRfftRadix4Sparse]; [encoder setBuffer:arena offset:0 atIndex:0];
            [encoder setBuffer:plan.destinationOffsets offset:0 atIndex:1]; [encoder setBuffer:arena offset:plan.twiddleByteOffset atIndex:2];
            [encoder setBytes:&log_size length:sizeof(log_size) atIndex:3]; [encoder setBytes:&layer length:sizeof(layer) atIndex:4];
            [encoder setBytes:&columns length:sizeof(columns) atIndex:5];
            NSUInteger width = MIN((NSUInteger)256u, runtime.circleRfftRadix4Sparse.maxTotalThreadsPerThreadgroup);
            [encoder dispatchThreads:MTLSizeMake(rows >> 2u, columns, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
            [encoder endEncoding];
            *compute_encoders += 1u; *dispatches += 1u;
            layer -= 2u;
            continue;
        }
        uint32_t twiddle_offset = pairs - (1u << (log_size - layer));
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        if (encoder == nil) return false;
        [encoder setComputePipelineState:runtime.circleRfftLayerSparse]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBuffer:plan.destinationOffsets offset:0 atIndex:1]; [encoder setBuffer:arena offset:plan.twiddleByteOffset atIndex:2];
        [encoder setBytes:&log_size length:sizeof(log_size) atIndex:3]; [encoder setBytes:&layer length:sizeof(layer) atIndex:4];
        [encoder setBytes:&twiddle_offset length:sizeof(twiddle_offset) atIndex:5]; [encoder setBytes:&columns length:sizeof(columns) atIndex:6];
        [encoder dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleRfftLayerSparse.maxTotalThreadsPerThreadgroup), 1u, 1u)];
        [encoder endEncoding];
        *compute_encoders += 1u; *dispatches += 1u;
        --layer;
    }
    if (log_size >= 11u) {
        id<MTLComputeCommandEncoder> fused = [command computeCommandEncoder];
        if (fused == nil) return false;
        [fused setComputePipelineState:runtime.circleRfftFusedSparse]; [fused setBuffer:arena offset:0 atIndex:0];
        [fused setBuffer:plan.destinationOffsets offset:0 atIndex:1]; [fused setBuffer:arena offset:plan.twiddleByteOffset atIndex:2];
        [fused setBytes:&log_size length:sizeof(log_size) atIndex:3]; [fused setBytes:&columns length:sizeof(columns) atIndex:4];
        [fused dispatchThreadgroups:MTLSizeMake(rows >> 11u, columns, 1u)
                 threadsPerThreadgroup:MTLSizeMake(256u, 1u, 1u)];
        [fused endEncoding];
        *compute_encoders += 1u; *dispatches += 1u;
    } else {
        id<MTLComputeCommandEncoder> last = [command computeCommandEncoder];
        if (last == nil) return false;
        [last setComputePipelineState:runtime.circleRfftLastSparse]; [last setBuffer:arena offset:0 atIndex:0];
        [last setBuffer:plan.destinationOffsets offset:0 atIndex:1]; [last setBuffer:arena offset:plan.twiddleByteOffset atIndex:2];
        [last setBytes:&log_size length:sizeof(log_size) atIndex:3]; [last setBytes:&columns length:sizeof(columns) atIndex:4];
        [last dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleRfftLastSparse.maxTotalThreadsPerThreadgroup), 1u, 1u)];
        [last endEncoding];
        *compute_encoders += 1u; *dispatches += 1u;
    }
    return true;
}

static bool encode_composition_lde(
    StwoZigMetalRuntime *runtime, id<MTLBuffer> arena,
    StwoZigCompositionLdePlan *plan, id<MTLCommandBuffer> command
) {
    uint64_t compute_encoders = 0u, dispatches = 0u;
    return encode_composition_lde_counted(
        runtime, arena, plan, command, &compute_encoders, &dispatches
    );
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
        if (!encode_composition_lde(runtime,arena,plan,command)) {
            write_error(error_message,error_message_len,@"Metal composition LDE encoding failed"); return false;
        }
        [command commit]; [command waitUntilCompleted];
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

static uint64_t composition_fnv_m31_words(const uint32_t *words, NSUInteger count) {
    uint64_t digest = UINT64_C(0xcbf29ce484222325);
    for (NSUInteger index = 0; index < count; ++index) {
        uint32_t value = words[index] % UINT32_C(0x7fffffff);
        for (uint32_t byte = 0; byte < 4u; ++byte) {
            digest ^= (value >> (byte * 8u)) & 0xffu;
            digest *= UINT64_C(0x100000001b3);
        }
    }
    return digest;
}

static void encode_composition_front_production(
    StwoZigMetalRuntime *runtime, id<MTLBuffer> arena,
    StwoZigCompositionFrontPlan *plan, id<MTLCommandBuffer> command
) {
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
        bool log_digests = getenv("STWO_ZIG_SN2_LOG_COMPOSITION_DIGESTS") != NULL;
        const char *part_component_text = getenv("STWO_ZIG_SN2_LOG_COMPOSITION_PART_COMPONENT");
        NSInteger part_component = part_component_text == NULL ? -1 : (NSInteger)strtol(part_component_text, NULL, 10);
        log_digests = log_digests || part_component >= 0;
        if (!log_digests) {
            id<MTLCommandBuffer> production_command = [runtime.queue commandBuffer];
            encode_composition_front_production(runtime, arena, plan, production_command);
            [production_command commit]; [production_command waitUntilCompleted];
            if (production_command.status == MTLCommandBufferStatusError) {
                write_error(error_message, error_message_len, production_command.error.localizedDescription); return false;
            }
            if (gpu_milliseconds) *gpu_milliseconds =
                (production_command.GPUEndTime - production_command.GPUStartTime) * 1000.0;
            return true;
        }
        double total_gpu_milliseconds = 0.0;
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
        if (log_digests) {
            [command commit]; [command waitUntilCompleted];
            if (command.status == MTLCommandBufferStatusError) {
                write_error(error_message, error_message_len, command.error.localizedDescription); return false;
            }
            total_gpu_milliseconds += (command.GPUEndTime-command.GPUStartTime)*1000.0;
            const uint32_t *arena_words = arena.contents;
            uint64_t powers_digest = composition_fnv_m31_words(arena_words + powers_offset, (NSUInteger)power_count * 4u);
            fprintf(stderr,
                    "composition_random_powers_digest words=%u first=%u last=%u fnv64=%016llx\n",
                    power_count * 4u, arena_words[powers_offset], arena_words[powers_offset + power_count * 4u - 1u],
                    (unsigned long long)powers_digest);
            if (inputs.descriptorCount != 0u) {
                const uint32_t *descriptors = inputs.descriptors.contents;
                uint64_t ext_digest = UINT64_C(0xcbf29ce484222325);
                uint32_t ext_first = 0u, ext_last = 0u;
                for (uint32_t descriptor = 0; descriptor < inputs.descriptorCount; ++descriptor) {
                    uint32_t destination = descriptors[descriptor * 8u];
                    if (descriptor == 0u) ext_first = arena_words[destination];
                    ext_last = arena_words[destination + 3u];
                    const uint32_t *value = arena_words + destination;
                    for (uint32_t coordinate = 0; coordinate < 4u; ++coordinate) {
                        uint32_t canonical = value[coordinate] % UINT32_C(0x7fffffff);
                        for (uint32_t byte = 0; byte < 4u; ++byte) {
                            ext_digest ^= (canonical >> (byte * 8u)) & 0xffu;
                            ext_digest *= UINT64_C(0x100000001b3);
                        }
                    }
                }
                fprintf(stderr,
                        "composition_ext_params_digest values=%u first=%u last=%u fnv64=%016llx\n",
                        inputs.descriptorCount, ext_first, ext_last, (unsigned long long)ext_digest);
            }
        }
        for (NSUInteger component = 0; component < plan.ldePlans.count; ++component) {
            if (log_digests) command = [runtime.queue commandBuffer];
            StwoZigEvalBatch *batch = plan.evalBatches[component];
            bool log_parts = (NSInteger)component == part_component;
            StwoZigCompositionLdePlan *lde = plan.ldePlans[component];
            if (log_parts && getenv("STWO_ZIG_SN2_ZERO_COMPOSITION_PART_ACCUMULATOR") != NULL) {
                StwoZigEvalPlan *first_eval = batch.plans.firstObject;
                const uint32_t *arguments = first_eval.arguments.contents;
                NSUInteger accumulator_bytes = (NSUInteger)arguments[10] * sizeof(uint32_t);
                id<MTLBlitCommandEncoder> zero_accumulator = [command blitCommandEncoder];
                for (uint32_t coordinate = 0; coordinate < 4u; ++coordinate) {
                    [zero_accumulator fillBuffer:arena
                                           range:NSMakeRange((NSUInteger)arguments[6u + coordinate] * sizeof(uint32_t), accumulator_bytes)
                                           value:0u];
                }
                [zero_accumulator endEncoding];
            }
            if (log_parts) {
                const uint32_t *arena_words = arena.contents;
                const uint64_t *source_offsets = lde.sourceOffsets.contents;
                const uint32_t *source_logs = lde.sourceLogs.contents;
                for (uint32_t column = 0; column < lde.columnCount; ++column) {
                    uint32_t source_words = 1u << source_logs[column];
                    const uint32_t *values = arena_words + source_offsets[column];
                    uint64_t digest = composition_fnv_m31_words(values, source_words);
                    fprintf(stderr,
                            "composition_coefficient_source_digest component_index=%lu local_index=%u log_size=%u words=%u first=%u last=%u fnv64=%016llx\n",
                            (unsigned long)component, column, source_logs[column], source_words,
                            values[0], values[source_words - 1u], (unsigned long long)digest);
                }
            }
            encode_composition_lde(runtime, arena, lde, command);
            if (log_parts) {
                [command commit]; [command waitUntilCompleted];
                if (command.status == MTLCommandBufferStatusError) {
                    write_error(error_message, error_message_len, command.error.localizedDescription); return false;
                }
                total_gpu_milliseconds += (command.GPUEndTime-command.GPUStartTime)*1000.0;

                StwoZigEvalPlan *first_eval = batch.plans.firstObject;
                const uint32_t *arguments = first_eval.arguments.contents;
                const uint32_t *arena_words = arena.contents;
                const uint32_t *lde_destinations = lde.destinationOffsets.contents;
                uint32_t lde_rows = 1u << lde.extendedLog;
                for (uint32_t column = 0; column < lde.columnCount; ++column) {
                    const uint32_t *values = arena_words + lde_destinations[column];
                    uint64_t digest = composition_fnv_m31_words(values, lde_rows);
                    fprintf(stderr,
                            "composition_lde_source_digest component_index=%lu local_index=%u log_size=%u words=%u first=%u last=%u fnv64=%016llx\n",
                            (unsigned long)component, column, lde.extendedLog, lde_rows,
                            values[0], values[lde_rows - 1u], (unsigned long long)digest);
                }
                const uint32_t *descriptors = inputs.descriptors.contents;
                uint32_t expected_destination = arguments[3], ext_count = 0u;
                uint64_t ext_digest = UINT64_C(0xcbf29ce484222325);
                bool found_ext = false;
                for (uint32_t descriptor = 0; descriptor < inputs.descriptorCount; ++descriptor) {
                    const uint32_t *ext = descriptors + descriptor * 8u;
                    if (ext[0] != expected_destination) {
                        if (found_ext) break;
                        continue;
                    }
                    found_ext = true;
                    const uint32_t *value = arena_words + ext[0];
                    fprintf(stderr,
                            "composition_ext_param component_index=%lu slot=%u destination=%u kind=%u source=%u scale=%u value=%u,%u,%u,%u\n",
                            (unsigned long)component, ext_count, ext[0], ext[1], ext[2], ext[3],
                            value[0], value[1], value[2], value[3]);
                    for (uint32_t coordinate = 0; coordinate < 4u; ++coordinate) {
                        uint32_t canonical = value[coordinate] % UINT32_C(0x7fffffff);
                        for (uint32_t byte = 0; byte < 4u; ++byte) {
                            ext_digest ^= (canonical >> (byte * 8u)) & 0xffu;
                            ext_digest *= UINT64_C(0x100000001b3);
                        }
                    }
                    ++ext_count;
                    expected_destination += 4u;
                }
                fprintf(stderr,
                        "composition_ext_component_digest component_index=%lu values=%u fnv64=%016llx\n",
                        (unsigned long)component, ext_count * 4u, (unsigned long long)ext_digest);
            }
            NSUInteger part_index = 0u;
            for (StwoZigEvalPlan *eval in batch.plans) {
                if (log_parts) command = [runtime.queue commandBuffer];
                id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
                [encoder setComputePipelineState:eval.pipeline]; [encoder setBuffer:arena offset:0 atIndex:0];
                [encoder setBuffer:eval.arguments offset:0 atIndex:1];
                NSUInteger width = MIN((NSUInteger)256u, MIN((NSUInteger)eval.rowCount, eval.pipeline.maxTotalThreadsPerThreadgroup));
                [encoder dispatchThreads:MTLSizeMake(eval.rowCount, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
                [encoder endEncoding];
                if (log_parts) {
                    [command commit]; [command waitUntilCompleted];
                    if (command.status == MTLCommandBufferStatusError) {
                        write_error(error_message, error_message_len, command.error.localizedDescription); return false;
                    }
                    total_gpu_milliseconds += (command.GPUEndTime-command.GPUStartTime)*1000.0;
                    const uint32_t *arguments = eval.arguments.contents;
                    uint32_t rows = arguments[10], log_size = 31u - __builtin_clz(rows);
                    const uint32_t *arena_words = arena.contents;
                    for (uint32_t coordinate = 0; coordinate < 4u; ++coordinate) {
                        const uint32_t *values = arena_words + arguments[6u + coordinate];
                        uint64_t digest = composition_fnv_m31_words(values, rows);
                        fprintf(stderr,
                                "composition_accumulator_part_digest component_index=%lu part_index=%lu rc_base=%u log_size=%u coordinate=%u words=%u first=%u last=%u fnv64=%016llx\n",
                                (unsigned long)component, (unsigned long)part_index, arguments[13], log_size, coordinate,
                                rows, values[0], values[rows - 1u], (unsigned long long)digest);
                    }
                }
                ++part_index;
            }
            if (log_digests && !log_parts) {
                [command commit]; [command waitUntilCompleted];
                if (command.status == MTLCommandBufferStatusError) {
                    write_error(error_message, error_message_len, command.error.localizedDescription); return false;
                }
                total_gpu_milliseconds += (command.GPUEndTime-command.GPUStartTime)*1000.0;
                StwoZigEvalPlan *first_eval = batch.plans.firstObject;
                const uint32_t *arguments = first_eval.arguments.contents;
                uint32_t rows = arguments[10], log_size = 31u - __builtin_clz(rows);
                const uint32_t *arena_words = arena.contents;
                for (uint32_t coordinate = 0; coordinate < 4u; ++coordinate) {
                    const uint32_t *values = arena_words + arguments[6u + coordinate];
                    uint64_t digest = composition_fnv_m31_words(values, rows);
                    fprintf(stderr,
                            "composition_accumulator_digest component_index=%lu log_size=%u coordinate=%u words=%u first=%u last=%u fnv64=%016llx\n",
                            (unsigned long)component, log_size, coordinate, rows, values[0], values[rows - 1u],
                            (unsigned long long)digest);
                }
            }
        }
        if (!log_digests) {
            [command commit]; [command waitUntilCompleted];
            if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
            total_gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        }
        if (gpu_milliseconds) *gpu_milliseconds = total_gpu_milliseconds;
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
        uint64_t coordinates[4] = { final_offset, final_offset + final_rows, final_offset + 2u * final_rows, final_offset + 3u * final_rows };
        plan.coordinateOffsets = [runtime.device newBufferWithBytes:coordinates length:sizeof(coordinates) options:MTLResourceStorageModeShared];
        plan.outputOffsets = [runtime.device newBufferWithBytes:output_offsets length:8u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.accumulatorCount = accumulator_count;
        plan.inverseTwiddleByteOffset = (NSUInteger)inverse_twiddle_offset_words * sizeof(uint32_t);
        if (plan.coordinateOffsets == nil || plan.outputOffsets == nil) {
            write_error(error_message, error_message_len, @"Metal composition-finalize plan allocation failed"); return NULL;
        }
        plan.scaleFactor = scale_factor;
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_composition_finalize_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

static void encode_composition_finalize_production(
    StwoZigMetalRuntime *runtime, id<MTLBuffer> arena,
    StwoZigCompositionFinalizePlan *plan, id<MTLCommandBuffer> command
) {
    const uint32_t *offsets = plan.accumulatorOffsets.bytes, *logs = plan.accumulatorLogs.bytes;
    id<MTLComputeCommandEncoder> lift = [command computeCommandEncoder];
    for (uint32_t i = 1u; i < plan.accumulatorCount; ++i) {
        uint32_t previous_offset = offsets[i - 1u], previous_log = logs[i - 1u];
        uint32_t current_offset = offsets[i], current_log = logs[i], current_rows = 1u << current_log;
        [lift setComputePipelineState:runtime.compositionLift]; [lift setBuffer:arena offset:0 atIndex:0];
        [lift setBytes:&previous_offset length:sizeof(previous_offset) atIndex:1];
        [lift setBytes:&previous_log length:sizeof(previous_log) atIndex:2];
        [lift setBytes:&current_offset length:sizeof(current_offset) atIndex:3];
        [lift setBytes:&current_log length:sizeof(current_log) atIndex:4];
        NSUInteger width = MIN((NSUInteger)256u, runtime.compositionLift.maxTotalThreadsPerThreadgroup);
        [lift dispatchThreads:MTLSizeMake(current_rows, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [lift memoryBarrierWithScope:MTLBarrierScopeBuffers];
    }
    [lift endEncoding];
    uint32_t log_size = logs[plan.accumulatorCount - 1u], rows = 1u << log_size, pairs = rows >> 1u;
    uint32_t column_count = 4u;
    MTLSize grid = MTLSizeMake(pairs, column_count, 1u);
    id<MTLComputeCommandEncoder> transform = [command computeCommandEncoder];
    [transform setComputePipelineState:runtime.circleIfftFirstSparse]; [transform setBuffer:arena offset:0 atIndex:0];
    [transform setBuffer:plan.coordinateOffsets offset:0 atIndex:1]; [transform setBuffer:arena offset:plan.inverseTwiddleByteOffset atIndex:2];
    [transform setBytes:&log_size length:sizeof(log_size) atIndex:3]; [transform setBytes:&column_count length:sizeof(column_count) atIndex:4];
    [transform dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleIfftFirstSparse.maxTotalThreadsPerThreadgroup), 1u, 1u)];
    [transform endEncoding];
    for (uint32_t layer = 1u; layer < log_size; ++layer) {
        transform = [command computeCommandEncoder];
        uint32_t twiddle_offset = pairs - (1u << (log_size - layer));
        [transform setComputePipelineState:runtime.circleIfftLayerSparse]; [transform setBuffer:arena offset:0 atIndex:0];
        [transform setBuffer:plan.coordinateOffsets offset:0 atIndex:1]; [transform setBuffer:arena offset:plan.inverseTwiddleByteOffset atIndex:2];
        [transform setBytes:&log_size length:sizeof(log_size) atIndex:3]; [transform setBytes:&layer length:sizeof(layer) atIndex:4];
        [transform setBytes:&twiddle_offset length:sizeof(twiddle_offset) atIndex:5]; [transform setBytes:&column_count length:sizeof(column_count) atIndex:6];
        [transform dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleIfftLayerSparse.maxTotalThreadsPerThreadgroup), 1u, 1u)];
        [transform endEncoding];
    }
    transform = [command computeCommandEncoder];
    uint32_t factor = plan.scaleFactor;
    [transform setComputePipelineState:runtime.circleRescaleSparse]; [transform setBuffer:arena offset:0 atIndex:0];
    [transform setBuffer:plan.coordinateOffsets offset:0 atIndex:1]; [transform setBytes:&log_size length:sizeof(log_size) atIndex:2];
    [transform setBytes:&column_count length:sizeof(column_count) atIndex:3]; [transform setBytes:&factor length:sizeof(factor) atIndex:4];
    [transform dispatchThreads:MTLSizeMake(rows, column_count, 1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleRescaleSparse.maxTotalThreadsPerThreadgroup), 1u, 1u)];
    [transform endEncoding];
    transform = [command computeCommandEncoder];
    uint32_t source_offset = offsets[plan.accumulatorCount - 1u];
    [transform setComputePipelineState:runtime.compositionSplit]; [transform setBuffer:arena offset:0 atIndex:0];
    [transform setBuffer:plan.outputOffsets offset:0 atIndex:1]; [transform setBytes:&source_offset length:sizeof(source_offset) atIndex:2];
    [transform setBytes:&log_size length:sizeof(log_size) atIndex:3];
    NSUInteger split_width = MIN((NSUInteger)256u, runtime.compositionSplit.maxTotalThreadsPerThreadgroup);
    [transform dispatchThreads:MTLSizeMake((rows >> 1u) * 8u, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(split_width, 1u, 1u)];
    [transform endEncoding];
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
        bool log_digests = getenv("STWO_ZIG_SN2_LOG_COMPOSITION_DIGESTS") != NULL;
        if (!log_digests) {
            id<MTLCommandBuffer> production_command = [runtime.queue commandBuffer];
            encode_composition_finalize_production(runtime, arena, plan, production_command);
            [production_command commit]; [production_command waitUntilCompleted];
            if (production_command.status == MTLCommandBufferStatusError) {
                write_error(error_message, error_message_len, production_command.error.localizedDescription); return false;
            }
            if (gpu_milliseconds) *gpu_milliseconds =
                (production_command.GPUEndTime - production_command.GPUStartTime) * 1000.0;
            return true;
        }
        double total_gpu_milliseconds = 0.0;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> lift = [command computeCommandEncoder];
        for (uint32_t i = 1u; i < plan.accumulatorCount; ++i) {
            uint32_t previous_offset = offsets[i - 1u], previous_log = logs[i - 1u];
            uint32_t current_offset = offsets[i], current_log = logs[i], current_rows = 1u << current_log;
            [lift setComputePipelineState:runtime.compositionLift]; [lift setBuffer:arena offset:0 atIndex:0];
            [lift setBytes:&previous_offset length:sizeof(previous_offset) atIndex:1];
            [lift setBytes:&previous_log length:sizeof(previous_log) atIndex:2];
            [lift setBytes:&current_offset length:sizeof(current_offset) atIndex:3];
            [lift setBytes:&current_log length:sizeof(current_log) atIndex:4];
            NSUInteger width = MIN((NSUInteger)256u, runtime.compositionLift.maxTotalThreadsPerThreadgroup);
            [lift dispatchThreads:MTLSizeMake(current_rows, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
            [lift memoryBarrierWithScope:MTLBarrierScopeBuffers];
        }
        [lift endEncoding];
        uint32_t log_size = logs[plan.accumulatorCount - 1u], rows = 1u << log_size, pairs = rows >> 1u;
        if (log_digests) {
            [command commit]; [command waitUntilCompleted];
            if (command.status == MTLCommandBufferStatusError) {
                write_error(error_message, error_message_len, command.error.localizedDescription); return false;
            }
            total_gpu_milliseconds += (command.GPUEndTime - command.GPUStartTime) * 1000.0;
            const uint32_t *arena_words = arena.contents;
            uint32_t final_offset = offsets[plan.accumulatorCount - 1u];
            const uint32_t *output_offsets = plan.outputOffsets.contents;
            const uint32_t *inverse_twiddles = arena_words + plan.inverseTwiddleByteOffset / sizeof(uint32_t);
            uint64_t twiddle_digest = composition_fnv_m31_words(inverse_twiddles, pairs);
            fprintf(stderr,
                    "composition_finalize_twiddle_digest words=%u first=%u last=%u fnv64=%016llx\n",
                    pairs, inverse_twiddles[0], inverse_twiddles[pairs - 1u],
                    (unsigned long long)twiddle_digest);
            uint64_t source_begin = final_offset;
            uint64_t source_end = source_begin + (uint64_t)4u * rows;
            for (uint32_t output = 0; output < 8u; ++output) {
                uint64_t output_begin = output_offsets[output];
                uint64_t output_end = output_begin + (rows >> 1u);
                fprintf(stderr,
                        "composition_finalize_layout output=%u source_begin=%llu source_end=%llu output_begin=%llu output_end=%llu overlaps_source=%u\n",
                        output, (unsigned long long)source_begin, (unsigned long long)source_end,
                        (unsigned long long)output_begin, (unsigned long long)output_end,
                        output_begin < source_end && source_begin < output_end);
            }
            for (uint32_t coordinate = 0; coordinate < 4u; ++coordinate) {
                const uint32_t *values = arena_words + final_offset + coordinate * rows;
                uint64_t digest = composition_fnv_m31_words(values, rows);
                fprintf(stderr,
                        "composition_lifted_accumulator_digest coordinate=%u log_size=%u words=%u first=%u last=%u fnv64=%016llx\n",
                        coordinate, log_size, rows, values[0], values[rows - 1u],
                        (unsigned long long)digest);
            }
            command = [runtime.queue commandBuffer];
        }
        uint32_t column_count = 4u;
        MTLSize grid = MTLSizeMake(pairs, column_count, 1u);
        id<MTLComputeCommandEncoder> transform = [command computeCommandEncoder];
        [transform setComputePipelineState:runtime.circleIfftFirstSparse]; [transform setBuffer:arena offset:0 atIndex:0];
        [transform setBuffer:plan.coordinateOffsets offset:0 atIndex:1]; [transform setBuffer:arena offset:plan.inverseTwiddleByteOffset atIndex:2];
        [transform setBytes:&log_size length:sizeof(log_size) atIndex:3]; [transform setBytes:&column_count length:sizeof(column_count) atIndex:4];
        [transform dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleIfftFirstSparse.maxTotalThreadsPerThreadgroup), 1u, 1u)];
        [transform endEncoding];
        for (uint32_t layer = 1u; layer < log_size; ++layer) {
            transform = [command computeCommandEncoder];
            uint32_t twiddle_offset = pairs - (1u << (log_size - layer));
            [transform setComputePipelineState:runtime.circleIfftLayerSparse]; [transform setBuffer:arena offset:0 atIndex:0];
            [transform setBuffer:plan.coordinateOffsets offset:0 atIndex:1]; [transform setBuffer:arena offset:plan.inverseTwiddleByteOffset atIndex:2];
            [transform setBytes:&log_size length:sizeof(log_size) atIndex:3]; [transform setBytes:&layer length:sizeof(layer) atIndex:4];
            [transform setBytes:&twiddle_offset length:sizeof(twiddle_offset) atIndex:5]; [transform setBytes:&column_count length:sizeof(column_count) atIndex:6];
            [transform dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleIfftLayerSparse.maxTotalThreadsPerThreadgroup), 1u, 1u)];
            [transform endEncoding];
        }
        transform = [command computeCommandEncoder];
        uint32_t factor = plan.scaleFactor;
        [transform setComputePipelineState:runtime.circleRescaleSparse]; [transform setBuffer:arena offset:0 atIndex:0];
        [transform setBuffer:plan.coordinateOffsets offset:0 atIndex:1]; [transform setBytes:&log_size length:sizeof(log_size) atIndex:2];
        [transform setBytes:&column_count length:sizeof(column_count) atIndex:3]; [transform setBytes:&factor length:sizeof(factor) atIndex:4];
        [transform dispatchThreads:MTLSizeMake(rows, column_count, 1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)256u, runtime.circleRescaleSparse.maxTotalThreadsPerThreadgroup), 1u, 1u)];
        [transform endEncoding];
        transform = [command computeCommandEncoder];
        uint32_t source_offset = offsets[plan.accumulatorCount - 1u];
        [transform setComputePipelineState:runtime.compositionSplit]; [transform setBuffer:arena offset:0 atIndex:0];
        [transform setBuffer:plan.outputOffsets offset:0 atIndex:1]; [transform setBytes:&source_offset length:sizeof(source_offset) atIndex:2];
        [transform setBytes:&log_size length:sizeof(log_size) atIndex:3];
        NSUInteger split_width = MIN((NSUInteger)256u, runtime.compositionSplit.maxTotalThreadsPerThreadgroup);
        [transform dispatchThreads:MTLSizeMake((rows >> 1u) * 8u, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(split_width, 1u, 1u)];
        [transform endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        total_gpu_milliseconds += (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        if (log_digests) {
            const uint32_t *output_offsets = plan.outputOffsets.contents;
            const uint32_t *arena_words = arena.contents;
            uint32_t output_rows = rows >> 1u;
            for (uint32_t output = 0; output < 8u; ++output) {
                const uint32_t *values = arena_words + output_offsets[output];
                uint64_t digest = composition_fnv_m31_words(values, output_rows);
                fprintf(stderr,
                        "composition_coefficient_digest index=%u log_size=%u words=%u first=%u last=%u fnv64=%016llx\n",
                        output, log_size - 1u, output_rows, values[0], values[output_rows - 1u],
                        (unsigned long long)digest);
            }
        }
        if (gpu_milliseconds) *gpu_milliseconds = total_gpu_milliseconds;
        return true;
    }
}

bool stwo_zig_metal_composition_prepared(
    void *runtime_ptr, void *arena_ptr, void *front_ptr, void *finalize_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || front_ptr == NULL || finalize_ptr == NULL) return false;
    const char *part_component_text = getenv("STWO_ZIG_SN2_LOG_COMPOSITION_PART_COMPONENT");
    bool diagnostics = getenv("STWO_ZIG_SN2_LOG_COMPOSITION_DIGESTS") != NULL ||
        (part_component_text != NULL && strtol(part_component_text, NULL, 10) >= 0);
    if (diagnostics) {
        double front_gpu_milliseconds = 0.0, finalize_gpu_milliseconds = 0.0;
        if (!stwo_zig_metal_composition_front_prepared(
                runtime_ptr, arena_ptr, front_ptr, &front_gpu_milliseconds, error_message, error_message_len) ||
            !stwo_zig_metal_composition_finalize_prepared(
                runtime_ptr, arena_ptr, finalize_ptr, &finalize_gpu_milliseconds, error_message, error_message_len))
            return false;
        if (gpu_milliseconds) *gpu_milliseconds = front_gpu_milliseconds + finalize_gpu_milliseconds;
        return true;
    }
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigCompositionFrontPlan *front = (__bridge StwoZigCompositionFrontPlan *)front_ptr;
        StwoZigCompositionFinalizePlan *finalize = (__bridge StwoZigCompositionFinalizePlan *)finalize_ptr;
        if ((NSUInteger)front.accumulatorOffset * 4u + (NSUInteger)front.accumulatorWords * 4u > arena.length)
            return false;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        encode_composition_front_production(runtime, arena, front, command);
        encode_composition_finalize_production(runtime, arena, finalize, command);
        [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len, command.error.localizedDescription); return false;
        }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

bool stwo_zig_metal_recurrence_composition(
    void *runtime_ptr,
    const uint32_t *trace_first,
    uint32_t row_count,
    uint32_t column_count,
    uint32_t column_stride,
    const uint32_t *power_words,
    uint32_t power_word_count,
    const uint32_t *denominator_inverses,
    uint32_t *output_words,
    size_t output_word_count,
    double *gpu_milliseconds,
    char *error_message,
    size_t error_message_len
) {
    if (runtime_ptr == NULL || trace_first == NULL || power_words == NULL ||
        denominator_inverses == NULL || output_words == NULL || row_count == 0u ||
        column_count < 3u || column_stride < row_count ||
        power_word_count != (column_count - 2u) * 4u ||
        output_word_count != (size_t)row_count * 4u) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        size_t trace_word_count = (size_t)(column_count - 1u) * column_stride + row_count;
        if (trace_word_count > SIZE_MAX / sizeof(uint32_t) ||
            output_word_count > SIZE_MAX / sizeof(uint32_t)) return false;
        uintptr_t trace_address = (uintptr_t)trace_first;
        size_t trace_bytes = trace_word_count * sizeof(uint32_t);
        if (trace_address > UINTPTR_MAX - trace_bytes) return false;

        id<MTLBuffer> trace_buffer = nil;
        NSUInteger trace_offset = 0u;
        @synchronized(runtime) {
            uintptr_t cache_begin = runtime.compositionTraceHostBegin;
            size_t cache_bytes = runtime.compositionTraceWordCount * sizeof(uint32_t);
            if (runtime.compositionTraceBuffer != nil && cache_begin <= trace_address &&
                cache_begin <= UINTPTR_MAX - cache_bytes &&
                trace_address + trace_bytes <= cache_begin + cache_bytes) {
                trace_buffer = runtime.compositionTraceBuffer;
                trace_offset = (NSUInteger)(trace_address - cache_begin);
            }
        }
        if (trace_buffer == nil) {
            write_error(error_message, error_message_len, @"Metal composition trace is not resident");
            return false;
        }

        size_t output_bytes = output_word_count * sizeof(uint32_t);
        size_t page_size = (size_t)getpagesize();
        bool direct_output = ((uintptr_t)output_words % page_size) == 0u &&
            (output_bytes % page_size) == 0u;
        id<MTLBuffer> output = direct_output
            ? [runtime.device newBufferWithBytesNoCopy:output_words
                                                length:output_bytes
                                               options:MTLResourceStorageModeShared
                                           deallocator:nil]
            : [runtime.device newBufferWithLength:output_bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> powers = [runtime.device newBufferWithBytes:power_words
                                                         length:(NSUInteger)power_word_count * sizeof(uint32_t)
                                                        options:MTLResourceStorageModeShared];
        if (output == nil || powers == nil) {
            write_error(error_message, error_message_len, @"Metal composition allocation failed");
            return false;
        }

        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.recurrenceComposition];
        [encoder setBuffer:trace_buffer offset:trace_offset atIndex:0];
        [encoder setBuffer:powers offset:0 atIndex:1];
        [encoder setBuffer:output offset:0 atIndex:2];
        [encoder setBytes:&row_count length:sizeof(row_count) atIndex:3];
        [encoder setBytes:&column_count length:sizeof(column_count) atIndex:4];
        [encoder setBytes:&column_stride length:sizeof(column_stride) atIndex:5];
        [encoder setBytes:denominator_inverses length:2u * sizeof(uint32_t) atIndex:6];
        NSUInteger width = MIN((NSUInteger)256u, runtime.recurrenceComposition.maxTotalThreadsPerThreadgroup);
        [encoder dispatchThreads:MTLSizeMake(row_count, 1u, 1u)
             threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len,
                        command.error.localizedDescription ?: @"Metal composition evaluation failed");
            return false;
        }
        if (!direct_output) memcpy(output_words, output.contents, output_bytes);
        if (gpu_milliseconds != NULL)
            *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}
