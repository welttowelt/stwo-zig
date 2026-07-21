void stwo_zig_metal_runtime_destroy(void *runtime_ptr) {
    if (runtime_ptr == NULL) return;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge_transfer StwoZigMetalRuntime *)runtime_ptr;
        NSArray<StwoZigEvalLibraryKey *> *keys = nil;
        @synchronized(runtime) {
            keys = [runtime.evalLibraries.allKeys sortedArrayUsingSelector:@selector(compare:)];
        }
        for (StwoZigEvalLibraryKey *key in keys) {
            StwoZigEvalLibrary *library = runtime.evalLibraries[key];
            if (!library.archiveDirty) continue;
            NSError *error = nil;
            bool didSerialize = false;
            if (!serialize_eval_archive(library, &error, &didSerialize)) {
                fprintf(stderr, "Failed to serialize Metal binary archive during shutdown: %s\n",
                        error.localizedDescription.UTF8String ?: "unknown Metal error");
            } else if (didSerialize) {
                @synchronized(runtime) { runtime.evalArchiveSerializations += 1u; }
            }
        }
    }
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
    uint32_t domain_prefix_bytes,
    char *error_message,
    size_t error_message_len
) {
    @autoreleasepool {
        if (runtime_ptr == NULL || columns == NULL || column_lengths == NULL || column_count == 0 ||
            lifting_log_size >= 31u ||
            (domain_prefix_bytes != 0u && domain_prefix_bytes != 64u)) {
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
        if (staging == nil || offsets == nil || log_sizes == nil ||
            leaf_seed_buffer == nil) {
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
        uint32_t layer_word_offsets[31] = { 0u };
        uint32_t layer_word_lengths[31] = { 0u };
        uint32_t layer_count = leaf_count;
        uint64_t arena_words = 0u;
        for (uint32_t level = 0; level <= lifting_log_size; ++level) {
            arena_words = (arena_words + 63u) & ~UINT64_C(63);
            uint64_t length_words = (uint64_t)layer_count * 8u;
            if (arena_words > UINT32_MAX || length_words > UINT32_MAX ||
                arena_words + length_words > UINT32_MAX) {
                write_error(error_message, error_message_len, @"Metal Merkle arena exceeds word offsets");
                return NULL;
            }
            layer_word_offsets[level] = (uint32_t)arena_words;
            layer_word_lengths[level] = (uint32_t)length_words;
            arena_words += length_words;
            layer_count >>= 1u;
        }
        id<MTLBuffer> hash_arena = [runtime.device newBufferWithLength:
            (NSUInteger)arena_words * sizeof(uint32_t)
            options:runtime.device.hasUnifiedMemory
                ? MTLResourceStorageModeShared : MTLResourceStorageModePrivate];
        id<MTLBuffer> root_readback = runtime.device.hasUnifiedMemory ? hash_arena
            : [runtime.device newBufferWithLength:32u options:MTLResourceStorageModeShared];
        NSData *layer_word_offsets_data = [NSData dataWithBytes:layer_word_offsets
            length:(NSUInteger)(lifting_log_size + 1u) * sizeof(uint32_t)];
        NSData *layer_word_lengths_data = [NSData dataWithBytes:layer_word_lengths
            length:(NSUInteger)(lifting_log_size + 1u) * sizeof(uint32_t)];
        if (hash_arena == nil || root_readback == nil || layer_word_offsets_data == nil ||
            layer_word_lengths_data == nil) {
            write_error(error_message, error_message_len, @"Metal Merkle arena allocation failed");
            return NULL;
        }
        for (uint32_t level = 0u; level <= lifting_log_size; ++level)
            [layers addObject:hash_arena];

        StwoZigMerkleParentChain *parent_plan = nil;
        if (lifting_log_size != 0u) {
            uint32_t child_offsets[30] = { 0u };
            uint32_t destination_offsets[30] = { 0u };
            uint32_t parent_counts[30] = { 0u };
            for (uint32_t level = 0u; level < lifting_log_size; ++level) {
                child_offsets[level] = layer_word_offsets[level];
                destination_offsets[level] = layer_word_offsets[level + 1u];
                parent_counts[level] = leaf_count >> (level + 1u);
            }
            void *parent_plan_ptr = stwo_zig_metal_merkle_parent_chain_prepare(
                runtime_ptr, child_offsets, destination_offsets, parent_counts,
                lifting_log_size, node_seed, domain_prefix_bytes,
                error_message, error_message_len);
            if (parent_plan_ptr != NULL)
                parent_plan = (__bridge_transfer StwoZigMerkleParentChain *)parent_plan_ptr;
        }
        if (lifting_log_size != 0u && parent_plan == nil) {
            write_error(error_message, error_message_len, @"Metal Merkle parent-chain allocation failed");
            return NULL;
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
        [leaf_encoder setBuffer:hash_arena
                         offset:(NSUInteger)layer_word_offsets[0] * sizeof(uint32_t) atIndex:3];
        [leaf_encoder setBytes:&column_count length:sizeof(column_count) atIndex:4];
        [leaf_encoder setBytes:&lifting_log_size length:sizeof(lifting_log_size) atIndex:5];
        [leaf_encoder setBuffer:leaf_seed_buffer offset:0 atIndex:6];
        [leaf_encoder setBytes:&domain_prefix_bytes length:sizeof(domain_prefix_bytes) atIndex:7];
        NSUInteger leaf_width = MIN(runtime.leaves.maxTotalThreadsPerThreadgroup,
                                    runtime.leaves.threadExecutionWidth * 8u);
        [leaf_encoder dispatchThreads:MTLSizeMake(leaf_count, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(leaf_width, 1, 1)];
        [leaf_encoder endEncoding];

        if (parent_plan != nil) {
            uint64_t parent_encoders = 0u, parent_dispatches = 0u;
            if (!encode_merkle_parent_chain_prepared(runtime, hash_arena, parent_plan, command,
                                                      &parent_encoders, &parent_dispatches)) {
                write_error(error_message, error_message_len, @"Metal Merkle parent-chain encoding failed");
                return NULL;
            }
        }
        if (!runtime.device.hasUnifiedMemory) {
            id<MTLBlitCommandEncoder> root_copy = [command blitCommandEncoder];
            if (root_copy == nil) {
                write_error(error_message, error_message_len, @"Metal Merkle root encoder allocation failed");
                return NULL;
            }
            [root_copy copyFromBuffer:hash_arena
                         sourceOffset:(NSUInteger)layer_word_offsets[lifting_log_size] * sizeof(uint32_t)
                             toBuffer:root_readback destinationOffset:0u size:32u];
            [root_copy endEncoding];
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
        tree.layerWordOffsets = layer_word_offsets_data;
        tree.layerWordLengths = layer_word_lengths_data;
        tree.rootReadback = root_readback;
        tree.rootReadbackWordOffset = runtime.device.hasUnifiedMemory
            ? layer_word_offsets[lifting_log_size] : 0u;
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
        const uint8_t *root_bytes = (const uint8_t *)tree.rootReadback.contents +
            (NSUInteger)tree.rootReadbackWordOffset * sizeof(uint32_t);
        memcpy(root, root_bytes, 32u);
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
            NSUInteger layer_index = (NSUInteger)level;
            id<MTLBuffer> layer = tree.layers[layer_index];
            NSUInteger source_offset = (NSUInteger)tree_layer_word_offset(tree, layer_index) * sizeof(uint32_t);
            NSUInteger layer_length = (NSUInteger)tree_layer_word_length(tree, layer_index) * sizeof(uint32_t);
            [blit copyFromBuffer:layer sourceOffset:source_offset toBuffer:readback
               destinationOffset:offset size:layer_length];
            offset += layer_length;
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

        NSUInteger layer_index = (NSUInteger)(tree.logSize - layer_log_size);
        id<MTLBuffer> source = tree.layers[layer_index];
        NSUInteger layer_offset = (NSUInteger)tree_layer_word_offset(tree, layer_index) * sizeof(uint32_t);
        if (source.storageMode == MTLStorageModeShared) {
            const uint8_t *source_bytes = source.contents;
            if (source_bytes == NULL) {
                write_error(error_message, error_message_len, @"Metal shared hash layer is not CPU-visible");
                return false;
            }
            source_bytes += layer_offset;
            for (uint32_t i = 0; i < index_count; ++i) {
                memcpy(destination + (NSUInteger)i * 32u,
                       source_bytes + (NSUInteger)indices[i] * 32u, 32u);
            }
            return true;
        }
        id<MTLBuffer> readback = [runtime.device newBufferWithLength:(NSUInteger)index_count * 32u
                                                            options:MTLResourceStorageModeShared];
        if (readback == nil) {
            write_error(error_message, error_message_len, @"Metal selective readback allocation failed");
            return false;
        }
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        for (uint32_t i = 0; i < index_count; ++i) {
            [blit copyFromBuffer:source sourceOffset:layer_offset + (NSUInteger)indices[i] * 32u
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

bool stwo_zig_metal_tree_copy_hashes_batch(
    void *runtime_ptr,
    void *tree_ptr,
    const uint32_t *layer_log_sizes,
    const uint32_t *const *indices,
    const uint32_t *index_counts,
    uint8_t *const *destinations,
    uint32_t request_count,
    char *error_message,
    size_t error_message_len
) {
    if (runtime_ptr == NULL || tree_ptr == NULL || layer_log_sizes == NULL ||
        indices == NULL || index_counts == NULL || destinations == NULL || request_count == 0u)
        return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigMetalTree *tree = (__bridge StwoZigMetalTree *)tree_ptr;
        size_t total_hashes = 0u;
        for (uint32_t request = 0u; request < request_count; ++request) {
            uint32_t layer_log_size = layer_log_sizes[request];
            uint32_t index_count = index_counts[request];
            if (layer_log_size >= 31u || layer_log_size > tree.logSize ||
                (index_count != 0u && (indices[request] == NULL || destinations[request] == NULL))) {
                write_error(error_message, error_message_len, @"Invalid Metal hash-read batch");
                return false;
            }
            uint32_t layer_count = 1u << layer_log_size;
            for (uint32_t index = 0u; index < index_count; ++index) {
                if (indices[request][index] >= layer_count) {
                    write_error(error_message, error_message_len, @"Invalid Metal batched hash index");
                    return false;
                }
            }
            if ((size_t)index_count > SIZE_MAX - total_hashes) {
                write_error(error_message, error_message_len, @"Metal hash-read batch exceeds address space");
                return false;
            }
            total_hashes += (size_t)index_count;
        }
        if (total_hashes == 0u) return true;
        if (total_hashes > SIZE_MAX / 32u) {
            write_error(error_message, error_message_len, @"Metal hash-read batch exceeds address space");
            return false;
        }

        // Tree-producing entry points wait for successful command completion
        // before publishing the immutable tree.  Shared layers are therefore
        // coherent for direct CPU point queries here; no additional GPU epoch
        // or synchronization boundary is required.
        bool all_layers_shared = true;
        for (uint32_t request = 0u; request < request_count; ++request) {
            NSUInteger layer_index = (NSUInteger)(tree.logSize - layer_log_sizes[request]);
            id<MTLBuffer> source = tree.layers[layer_index];
            if (source.storageMode != MTLStorageModeShared || source.contents == NULL) {
                all_layers_shared = false;
                break;
            }
        }
        if (all_layers_shared) {
            for (uint32_t request = 0u; request < request_count; ++request) {
                NSUInteger layer_index = (NSUInteger)(tree.logSize - layer_log_sizes[request]);
                id<MTLBuffer> source = tree.layers[layer_index];
                const uint8_t *source_bytes = (const uint8_t *)source.contents +
                    (NSUInteger)tree_layer_word_offset(tree, layer_index) * sizeof(uint32_t);
                for (uint32_t index = 0u; index < index_counts[request]; ++index) {
                    memcpy(destinations[request] + (NSUInteger)index * 32u,
                           source_bytes + (NSUInteger)indices[request][index] * 32u, 32u);
                }
            }
            return true;
        }

        id<MTLBuffer> readback = [runtime.device newBufferWithLength:(NSUInteger)total_hashes * 32u
                                                             options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        if (readback == nil || command == nil || blit == nil) {
            write_error(error_message, error_message_len, @"Metal batched hash-read allocation failed");
            return false;
        }

        size_t destination_hash = 0u;
        for (uint32_t request = 0u; request < request_count; ++request) {
            NSUInteger layer_index = (NSUInteger)(tree.logSize - layer_log_sizes[request]);
            id<MTLBuffer> source = tree.layers[layer_index];
            NSUInteger layer_offset = (NSUInteger)tree_layer_word_offset(tree, layer_index) * sizeof(uint32_t);
            for (uint32_t index = 0u; index < index_counts[request]; ++index) {
                [blit copyFromBuffer:source sourceOffset:layer_offset + (NSUInteger)indices[request][index] * 32u
                           toBuffer:readback destinationOffset:(NSUInteger)destination_hash * 32u size:32u];
                destination_hash += 1u;
            }
        }
        [blit endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len,
                        command.error.localizedDescription ?: @"Metal batched hash readback failed");
            return false;
        }

        const uint8_t *source_bytes = readback.contents;
        size_t source_hash = 0u;
        for (uint32_t request = 0u; request < request_count; ++request) {
            size_t byte_count = (size_t)index_counts[request] * 32u;
            if (byte_count != 0u) memcpy(destinations[request], source_bytes + source_hash * 32u, byte_count);
            source_hash += (size_t)index_counts[request];
        }
        return true;
    }
}
