// FRI fold-to-next-tree transaction. Included after the runtime and tree
// Objective-C owners are declared in the parent translation unit.

void *stwo_zig_metal_fri_fold_line_and_commit(
    void *runtime_ptr, void *source_ptr, uint32_t source_count,
    const uint32_t *inverse_x, uint32_t inverse_x_count,
    const uint32_t *alphas, uint32_t fold_count, void *destination_ptr,
    void *coordinates_ptr,
    const uint32_t *leaf_seed, const uint32_t *node_seed,
    uint32_t domain_prefix_bytes, StwoZigCommandEpochStats *stats,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || source_ptr == NULL || destination_ptr == NULL || coordinates_ptr == NULL ||
        inverse_x == NULL || alphas == NULL || leaf_seed == NULL || node_seed == NULL ||
        stats == NULL || source_count < 2u || (source_count & (source_count - 1u)) != 0u ||
        fold_count == 0u || fold_count >= 31u ||
        (domain_prefix_bytes != 0u && domain_prefix_bytes != 64u)) {
        write_error(error_message, error_message_len, @"Invalid Metal FRI fold + commitment arguments");
        return NULL;
    }
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> source = (__bridge id<MTLBuffer>)source_ptr;
        id<MTLBuffer> destination = (__bridge id<MTLBuffer>)destination_ptr;
        id<MTLBuffer> coordinates = (__bridge id<MTLBuffer>)coordinates_ptr;
        uint32_t final_count = source_count >> fold_count;
        if (final_count == 0u || source.length < (NSUInteger)source_count * 16u ||
            destination.length < (NSUInteger)final_count * 16u ||
            coordinates.length < (NSUInteger)final_count * 16u) {
            write_error(error_message, error_message_len, @"Metal FRI resident buffers have invalid lengths");
            return NULL;
        }

        uint64_t expected_inverse_count = 0u;
        uint32_t stage_count = source_count;
        for (uint32_t step = 0u; step < fold_count; ++step) {
            stage_count >>= 1u;
            expected_inverse_count += stage_count;
        }
        if (expected_inverse_count != inverse_x_count) {
            write_error(error_message, error_message_len, @"Metal FRI inverse-coordinate shape mismatch");
            return NULL;
        }

        id<MTLBuffer> inverse_buffer = [runtime.device newBufferWithBytes:inverse_x
            length:(NSUInteger)inverse_x_count * sizeof(uint32_t)
            options:MTLResourceStorageModeShared];
        id<MTLBuffer> alpha_buffer = [runtime.device newBufferWithBytes:alphas
            length:(NSUInteger)fold_count * 4u * sizeof(uint32_t)
            options:MTLResourceStorageModeShared];
        id<MTLBuffer> leaf_seed_buffer = [runtime.device newBufferWithBytes:leaf_seed
            length:8u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        id<MTLBuffer> node_seed_buffer = [runtime.device newBufferWithBytes:node_seed
            length:8u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        if (inverse_buffer == nil || alpha_buffer == nil ||
            leaf_seed_buffer == nil || node_seed_buffer == nil) {
            write_error(error_message, error_message_len, @"Metal FRI fold + commitment allocation failed");
            return NULL;
        }

        uint32_t tree_log_size = 0u;
        for (uint32_t count = final_count; count > 1u; count >>= 1u) tree_log_size += 1u;
        NSMutableArray<id<MTLBuffer>> *layers = [NSMutableArray arrayWithCapacity:tree_log_size + 1u];
        uint32_t layer_count = final_count;
        for (uint32_t level = 0u; level <= tree_log_size; ++level) {
            MTLResourceOptions storage = level == tree_log_size || runtime.device.hasUnifiedMemory
                ? MTLResourceStorageModeShared
                : MTLResourceStorageModePrivate;
            id<MTLBuffer> layer = [runtime.device newBufferWithLength:(NSUInteger)layer_count * 32u
                options:storage];
            if (layer == nil) {
                write_error(error_message, error_message_len, @"Metal FRI tree layer allocation failed");
                return NULL;
            }
            [layers addObject:layer];
            layer_count >>= 1u;
        }

        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        if (command == nil) {
            write_error(error_message, error_message_len, @"Metal FRI command allocation failed");
            return NULL;
        }
        NSMutableArray<id<MTLBuffer>> *intermediates = [NSMutableArray arrayWithCapacity:fold_count - 1u];
        id<MTLBuffer> fold_source = source;
        uint32_t input_count = source_count;
        NSUInteger inverse_byte_offset = 0u;
        uint64_t compute_encoders = 0u, dispatches = 0u;
        for (uint32_t step = 0u; step < fold_count; ++step) {
            uint32_t output_count = input_count >> 1u;
            id<MTLBuffer> fold_destination = destination;
            if (step + 1u != fold_count) {
                fold_destination = [runtime.device newBufferWithLength:(NSUInteger)output_count * 16u
                    options:MTLResourceStorageModePrivate];
                if (fold_destination == nil) {
                    write_error(error_message, error_message_len, @"Metal FRI intermediate allocation failed");
                    return NULL;
                }
                [intermediates addObject:fold_destination];
            }
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            if (encoder == nil) {
                write_error(error_message, error_message_len, @"Metal FRI fold encoder allocation failed");
                return NULL;
            }
            [encoder setComputePipelineState:runtime.friFoldLine];
            [encoder setBuffer:fold_source offset:0u atIndex:0];
            [encoder setBuffer:inverse_buffer offset:inverse_byte_offset atIndex:1];
            [encoder setBuffer:alpha_buffer offset:(NSUInteger)step * 16u atIndex:2];
            [encoder setBuffer:fold_destination offset:0u atIndex:3];
            [encoder setBytes:&output_count length:sizeof(output_count) atIndex:4];
            NSUInteger width = MIN(runtime.friFoldLine.maxTotalThreadsPerThreadgroup,
                                   runtime.friFoldLine.threadExecutionWidth * 8u);
            [encoder dispatchThreads:MTLSizeMake(output_count, 1u, 1u)
                threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
            [encoder endEncoding];
            compute_encoders += 1u;
            dispatches += 1u;
            inverse_byte_offset += (NSUInteger)output_count * sizeof(uint32_t);
            fold_source = fold_destination;
            input_count = output_count;
        }

        id<MTLComputeCommandEncoder> conversion = [command computeCommandEncoder];
        if (conversion == nil) {
            write_error(error_message, error_message_len, @"Metal FRI coordinate encoder allocation failed");
            return NULL;
        }
        [conversion setComputePipelineState:runtime.qm31ToCoordinates];
        [conversion setBuffer:destination offset:0u atIndex:0];
        [conversion setBuffer:coordinates offset:0u atIndex:1];
        [conversion setBytes:&final_count length:sizeof(final_count) atIndex:2];
        NSUInteger conversion_width = MIN(runtime.qm31ToCoordinates.maxTotalThreadsPerThreadgroup,
                                          runtime.qm31ToCoordinates.threadExecutionWidth * 8u);
        [conversion dispatchThreads:MTLSizeMake(final_count, 1u, 1u)
             threadsPerThreadgroup:MTLSizeMake(conversion_width, 1u, 1u)];
        [conversion endEncoding];
        compute_encoders += 1u;
        dispatches += 1u;

        uint32_t column_offsets[4] = { 0u, final_count, 2u * final_count, 3u * final_count };
        uint32_t column_logs[4] = { tree_log_size, tree_log_size, tree_log_size, tree_log_size };
        uint32_t column_count = 4u;
        id<MTLComputeCommandEncoder> leaves = [command computeCommandEncoder];
        if (leaves == nil) {
            write_error(error_message, error_message_len, @"Metal FRI leaf encoder allocation failed");
            return NULL;
        }
        [leaves setComputePipelineState:runtime.leaves];
        [leaves setBuffer:coordinates offset:0u atIndex:0];
        [leaves setBytes:column_offsets length:sizeof(column_offsets) atIndex:1];
        [leaves setBytes:column_logs length:sizeof(column_logs) atIndex:2];
        [leaves setBuffer:layers[0] offset:0u atIndex:3];
        [leaves setBytes:&column_count length:sizeof(column_count) atIndex:4];
        [leaves setBytes:&tree_log_size length:sizeof(tree_log_size) atIndex:5];
        [leaves setBuffer:leaf_seed_buffer offset:0u atIndex:6];
        [leaves setBytes:&domain_prefix_bytes length:sizeof(domain_prefix_bytes) atIndex:7];
        NSUInteger leaf_width = MIN(runtime.leaves.maxTotalThreadsPerThreadgroup,
                                    runtime.leaves.threadExecutionWidth * 8u);
        [leaves dispatchThreads:MTLSizeMake(final_count, 1u, 1u)
             threadsPerThreadgroup:MTLSizeMake(leaf_width, 1u, 1u)];
        [leaves endEncoding];
        compute_encoders += 1u;
        dispatches += 1u;

        uint32_t parent_count = final_count >> 1u;
        for (uint32_t level = 1u; level <= tree_log_size; ++level) {
            id<MTLComputeCommandEncoder> parent = [command computeCommandEncoder];
            if (parent == nil) {
                write_error(error_message, error_message_len, @"Metal FRI parent encoder allocation failed");
                return NULL;
            }
            [parent setComputePipelineState:runtime.parents];
            [parent setBuffer:layers[level - 1u] offset:0u atIndex:0];
            [parent setBuffer:layers[level] offset:0u atIndex:1];
            [parent setBytes:&parent_count length:sizeof(parent_count) atIndex:2];
            [parent setBuffer:node_seed_buffer offset:0u atIndex:3];
            [parent setBytes:&domain_prefix_bytes length:sizeof(domain_prefix_bytes) atIndex:4];
            NSUInteger width = MIN(runtime.parents.maxTotalThreadsPerThreadgroup,
                                   runtime.parents.threadExecutionWidth * 8u);
            [parent dispatchThreads:MTLSizeMake(parent_count, 1u, 1u)
                 threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
            [parent endEncoding];
            compute_encoders += 1u;
            dispatches += 1u;
            parent_count >>= 1u;
        }

        [command commit];
        [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len,
                        command.error.localizedDescription ?: @"Metal FRI fold + commitment failed");
            return NULL;
        }
        double gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        *stats = (StwoZigCommandEpochStats){
            .command_buffers = 1u,
            .wait_count = 1u,
            .intermediate_wait_count = 0u,
            .compute_encoders = compute_encoders,
            .blit_encoders = 0u,
            .dispatches = dispatches,
            .gpu_milliseconds = gpu_milliseconds,
        };
        StwoZigMetalTree *tree = [StwoZigMetalTree new];
        tree.layers = layers;
        tree.rootReadback = layers.lastObject;
        tree.logSize = tree_log_size;
        tree.gpuMilliseconds = gpu_milliseconds;
        return (__bridge_retained void *)tree;
    }
}
