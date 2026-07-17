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
    void *runtime_ptr, void *arena_ptr, uint64_t raw_base, uint32_t raw_count,
    uint32_t log_domain_size, uint64_t unique_base, uint64_t unique_count_base,
    uint32_t tree_count, uint64_t assembly_base, uint32_t assembly_capacity,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||raw_count==0u||log_domain_size==0u||log_domain_size>=31u||tree_count==0u||assembly_capacity<8u+tree_count*16u+raw_count)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t);
        if((NSUInteger)raw_base+raw_count>words||(NSUInteger)unique_base+raw_count>words||unique_count_base>=words||(NSUInteger)assembly_base+assembly_capacity>words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitNormalizeQueriesResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBytes:&raw_base length:8u atIndex:1]; [encoder setBytes:&raw_count length:4u atIndex:2];
        [encoder setBytes:&log_domain_size length:4u atIndex:3]; [encoder setBytes:&unique_base length:8u atIndex:4];
        [encoder setBytes:&unique_count_base length:8u atIndex:5]; [encoder setBytes:&tree_count length:4u atIndex:6];
        [encoder setBytes:&assembly_base length:8u atIndex:7]; [encoder setBytes:&assembly_capacity length:4u atIndex:8];
        [encoder dispatchThreads:MTLSizeMake(1u,1u,1u) threadsPerThreadgroup:MTLSizeMake(1u,1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

static void encode_decommit_prepare_fri_queries(
    StwoZigMetalRuntime *runtime, id<MTLBuffer> arena,
    const StwoZigDecommitFriRoundParams *params,
    id<MTLCommandBuffer> command
) {
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:runtime.decommitPrepareFriQueriesResident];
    [encoder setBuffer:arena offset:0 atIndex:0];
    [encoder setBytes:&params->unique_base length:8u atIndex:1];
    [encoder setBytes:&params->unique_count_base length:8u atIndex:2];
    [encoder setBytes:&params->max_queries length:4u atIndex:3];
    [encoder setBytes:&params->cumulative_fold length:4u atIndex:4];
    [encoder setBytes:&params->fold_step length:4u atIndex:5];
    [encoder setBytes:&params->packed_log length:4u atIndex:6];
    [encoder setBytes:&params->tree_queries_base length:8u atIndex:7];
    [encoder setBytes:&params->tree_count_base length:8u atIndex:8];
    [encoder setBytes:&params->expanded_base length:8u atIndex:9];
    [encoder setBytes:&params->expanded_count_base length:8u atIndex:10];
    [encoder setBytes:&params->walk_base length:8u atIndex:11];
    [encoder setBytes:&params->walk_count_base length:8u atIndex:12];
    [encoder dispatchThreads:MTLSizeMake(1u, 1u, 1u)
          threadsPerThreadgroup:MTLSizeMake(1u, 1u, 1u)];
    [encoder endEncoding];
}

static void encode_decommit_gather_fri_values(
    StwoZigMetalRuntime *runtime, id<MTLBuffer> arena,
    const StwoZigDecommitFriRoundParams *params,
    id<MTLCommandBuffer> command
) {
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:runtime.decommitGatherFriValuesResident];
    [encoder setBuffer:arena offset:0 atIndex:0];
    [encoder setBuffer:arena offset:(NSUInteger)params->coordinate_bases * sizeof(uint32_t) atIndex:1];
    [encoder setBytes:&params->expanded_base length:8u atIndex:2];
    [encoder setBytes:&params->expanded_count_base length:8u atIndex:3];
    [encoder setBytes:&params->max_positions length:4u atIndex:4];
    [encoder setBytes:&params->values_base length:8u atIndex:5];
    [encoder dispatchThreads:MTLSizeMake(params->max_positions, 1u, 1u)
          threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)params->max_positions, 256u), 1u, 1u)];
    [encoder endEncoding];
}

static void encode_decommit_assemble_fri(
    StwoZigMetalRuntime *runtime, id<MTLBuffer> arena,
    const StwoZigDecommitFriRoundParams *params,
    id<MTLCommandBuffer> command
) {
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:runtime.decommitAssembleFriResident];
    [encoder setBuffer:arena offset:0 atIndex:0];
    [encoder setBytes:&params->tree_index length:4u atIndex:1];
    [encoder setBytes:&params->leaf_log length:4u atIndex:2];
    [encoder setBytes:&params->tree_queries_base length:8u atIndex:3];
    [encoder setBytes:&params->tree_count_base length:8u atIndex:4];
    [encoder setBytes:&params->expanded_base length:8u atIndex:5];
    [encoder setBytes:&params->expanded_count_base length:8u atIndex:6];
    [encoder setBytes:&params->values_base length:8u atIndex:7];
    [encoder setBytes:&params->walk_base length:8u atIndex:8];
    [encoder setBytes:&params->walk_scratch_base length:8u atIndex:9];
    [encoder setBytes:&params->walk_count_base length:8u atIndex:10];
    [encoder setBytes:&params->retained_offsets length:8u atIndex:11];
    [encoder setBytes:&params->assembly_base length:8u atIndex:12];
    [encoder setBytes:&params->assembly_capacity length:4u atIndex:13];
    [encoder dispatchThreads:MTLSizeMake(1u, 1u, 1u)
          threadsPerThreadgroup:MTLSizeMake(1u, 1u, 1u)];
    [encoder endEncoding];
}

bool stwo_zig_metal_decommit_prepare_fri_queries(
    void *runtime_ptr, void *arena_ptr, uint64_t unique_base, uint64_t unique_count_base,
    uint32_t max_queries, uint32_t cumulative_fold, uint32_t fold_step, uint32_t packed_log,
    uint64_t tree_queries_base, uint64_t tree_count_base, uint64_t expanded_base,
    uint64_t expanded_count_base, uint64_t walk_base, uint64_t walk_count_base,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||max_queries==0u||fold_step==0u||fold_step>=8u||packed_log>=31u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t), expanded=(NSUInteger)max_queries<<fold_step;
        if((NSUInteger)unique_base+max_queries>words||unique_count_base>=words||(NSUInteger)tree_queries_base+max_queries>words||tree_count_base>=words||(NSUInteger)expanded_base+expanded>words||expanded_count_base>=words||(NSUInteger)walk_base+expanded>words||walk_count_base>=words)return false;
        StwoZigDecommitFriRoundParams params = {
            .unique_base = unique_base, .unique_count_base = unique_count_base,
            .tree_queries_base = tree_queries_base, .tree_count_base = tree_count_base,
            .expanded_base = expanded_base, .expanded_count_base = expanded_count_base,
            .walk_base = walk_base, .walk_count_base = walk_count_base,
            .max_queries = max_queries, .cumulative_fold = cumulative_fold,
            .fold_step = fold_step, .packed_log = packed_log,
        };
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer];
        encode_decommit_prepare_fri_queries(runtime, arena, &params, command);
        [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_prepare_trace_queries(
    void *runtime_ptr, void *arena_ptr, uint64_t unique_base, uint64_t unique_count_base,
    uint32_t max_queries, uint32_t source_log, uint32_t tree_log, uint32_t leaf_log,
    uint32_t unretained, uint64_t mapped_base, uint64_t mapped_count_base,
    uint64_t walk_base, uint64_t walk_count_base, uint64_t leaves_base,
    uint64_t leaf_count_base, double *gpu_milliseconds, char *error_message,
    size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||max_queries==0u||source_log>=31u||tree_log>=31u||leaf_log>=31u||unretained>=8u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t), leaves=(NSUInteger)max_queries<<unretained;
        if((NSUInteger)unique_base+max_queries>words||unique_count_base>=words||(NSUInteger)mapped_base+max_queries>words||mapped_count_base>=words||(NSUInteger)walk_base+max_queries>words||walk_count_base>=words||(NSUInteger)leaves_base+leaves>words||leaf_count_base>=words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitPrepareTraceQueriesResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBytes:&unique_base length:8u atIndex:1]; [encoder setBytes:&unique_count_base length:8u atIndex:2];
        [encoder setBytes:&max_queries length:4u atIndex:3]; [encoder setBytes:&source_log length:4u atIndex:4];
        [encoder setBytes:&tree_log length:4u atIndex:5]; [encoder setBytes:&leaf_log length:4u atIndex:6];
        [encoder setBytes:&unretained length:4u atIndex:7]; [encoder setBytes:&mapped_base length:8u atIndex:8];
        [encoder setBytes:&mapped_count_base length:8u atIndex:9]; [encoder setBytes:&walk_base length:8u atIndex:10];
        [encoder setBytes:&walk_count_base length:8u atIndex:11]; [encoder setBytes:&leaves_base length:8u atIndex:12];
        [encoder setBytes:&leaf_count_base length:8u atIndex:13];
        [encoder dispatchThreads:MTLSizeMake(1u,1u,1u) threadsPerThreadgroup:MTLSizeMake(1u,1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_gather_trace_values(
    void *runtime_ptr, void *arena_ptr, uint64_t column_offsets_base,
    uint64_t column_logs_base, uint32_t column_count, uint32_t lifting_log,
    uint64_t queries_base, uint64_t query_count_base, uint32_t max_queries,
    uint32_t first_column, uint32_t stride, uint64_t output_base,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||column_count==0u||max_queries==0u||stride<max_queries||lifting_log>=31u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t);
        NSUInteger output_end=(NSUInteger)output_base+((NSUInteger)first_column+column_count)*stride;
        if((NSUInteger)column_offsets_base+(NSUInteger)column_count*2u>words||(NSUInteger)column_logs_base+column_count>words||
           (NSUInteger)queries_base+max_queries>words||query_count_base>=words||output_end>words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitGatherTraceValuesResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBytes:&column_offsets_base length:8u atIndex:1]; [encoder setBytes:&column_logs_base length:8u atIndex:2];
        [encoder setBytes:&column_count length:4u atIndex:3]; [encoder setBytes:&lifting_log length:4u atIndex:4];
        [encoder setBytes:&queries_base length:8u atIndex:5]; [encoder setBytes:&query_count_base length:8u atIndex:6];
        [encoder setBytes:&max_queries length:4u atIndex:7]; [encoder setBytes:&first_column length:4u atIndex:8];
        [encoder setBytes:&stride length:4u atIndex:9]; [encoder setBytes:&output_base length:8u atIndex:10];
        MTLSize threads=MTLSizeMake(MIN((NSUInteger)max_queries,32u),MIN((NSUInteger)column_count,8u),1u);
        [encoder dispatchThreads:MTLSizeMake(max_queries,column_count,1u) threadsPerThreadgroup:threads]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_gather_fri_values(
    void *runtime_ptr, void *arena_ptr, uint64_t coordinate_bases,
    uint64_t positions_base, uint64_t count_base, uint32_t max_positions,
    uint64_t values_base, double *gpu_milliseconds, char *error_message,
    size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||max_positions==0u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t);
        if((NSUInteger)coordinate_bases+8u>words||(NSUInteger)positions_base+max_positions>words||
           count_base>=words||(NSUInteger)values_base+(NSUInteger)max_positions*4u>words)return false;
        StwoZigDecommitFriRoundParams params = {
            .expanded_base = positions_base, .expanded_count_base = count_base,
            .coordinate_bases = coordinate_bases, .values_base = values_base,
            .max_positions = max_positions,
        };
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer];
        encode_decommit_gather_fri_values(runtime, arena, &params, command);
        [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_assemble_fri(
    void *runtime_ptr, void *arena_ptr, uint32_t tree_index, uint32_t leaf_log,
    uint64_t tree_queries, uint64_t tree_count_at, uint64_t expanded,
    uint64_t expanded_count_at, uint64_t values, uint64_t walk, uint64_t scratch,
    uint64_t walk_count_at, uint64_t retained_offsets, uint64_t assembly,
    uint32_t capacity, double *gpu_milliseconds, char *error_message,
    size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||leaf_log>=31u||capacity==0u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena_buffer=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena_buffer.length/sizeof(uint32_t);
        if(tree_count_at>=words||expanded_count_at>=words||walk_count_at>=words||
           (NSUInteger)retained_offsets+(NSUInteger)(leaf_log+1u)*2u>words||(NSUInteger)assembly+capacity>words)return false;
        StwoZigDecommitFriRoundParams params = {
            .tree_queries_base = tree_queries, .tree_count_base = tree_count_at,
            .expanded_base = expanded, .expanded_count_base = expanded_count_at,
            .walk_base = walk, .walk_count_base = walk_count_at,
            .values_base = values, .walk_scratch_base = scratch,
            .retained_offsets = retained_offsets, .assembly_base = assembly,
            .tree_index = tree_index, .leaf_log = leaf_log, .assembly_capacity = capacity,
        };
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer];
        encode_decommit_assemble_fri(runtime, arena_buffer, &params, command);
        [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_fri_round(
    void *runtime_ptr, void *arena_ptr, const StwoZigDecommitFriRoundParams *params,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || params == NULL ||
        params->max_queries == 0u || params->fold_step == 0u || params->fold_step >= 8u ||
        params->packed_log >= 31u || params->max_positions == 0u ||
        params->leaf_log >= 31u || params->assembly_capacity == 0u) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words = arena.length / sizeof(uint32_t);
        NSUInteger expanded = (NSUInteger)params->max_queries << params->fold_step;
        if ((NSUInteger)params->unique_base + params->max_queries > words ||
            params->unique_count_base >= words ||
            (NSUInteger)params->tree_queries_base + params->max_queries > words ||
            params->tree_count_base >= words ||
            (NSUInteger)params->expanded_base + expanded > words ||
            params->expanded_count_base >= words ||
            (NSUInteger)params->walk_base + expanded > words ||
            params->walk_count_base >= words ||
            (NSUInteger)params->coordinate_bases + 8u > words ||
            (NSUInteger)params->expanded_base + params->max_positions > words ||
            (NSUInteger)params->values_base + (NSUInteger)params->max_positions * 4u > words ||
            (NSUInteger)params->retained_offsets + (NSUInteger)(params->leaf_log + 1u) * 2u > words ||
            (NSUInteger)params->assembly_base + params->assembly_capacity > words) return false;

        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        encode_decommit_prepare_fri_queries(runtime, arena, params, command);
        encode_decommit_gather_fri_values(runtime, arena, params, command);
        encode_decommit_assemble_fri(runtime, arena, params, command);
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

bool stwo_zig_metal_decommit_sparse_parent(
    void *runtime_ptr, void *arena_ptr, uint64_t child_indices, uint64_t child_hashes,
    uint64_t child_count_at, uint32_t max_child_count, uint64_t parent_indices,
    uint64_t parent_hashes, uint64_t parent_count_at, const uint32_t node_seed[8],
    uint32_t domain_prefix_bytes,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||node_seed==NULL||max_child_count<2u||
       (domain_prefix_bytes!=0u&&domain_prefix_bytes!=64u))return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t), parents=max_child_count/2u;
        if((NSUInteger)child_indices+max_child_count>words||(NSUInteger)child_hashes+(NSUInteger)max_child_count*8u>words||
           child_count_at>=words||(NSUInteger)parent_indices+parents>words||(NSUInteger)parent_hashes+parents*8u>words||parent_count_at>=words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitSparseParentResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBytes:&child_indices length:8u atIndex:1]; [encoder setBytes:&child_hashes length:8u atIndex:2];
        [encoder setBytes:&child_count_at length:8u atIndex:3]; [encoder setBytes:&max_child_count length:4u atIndex:4];
        [encoder setBytes:&parent_indices length:8u atIndex:5]; [encoder setBytes:&parent_hashes length:8u atIndex:6];
        [encoder setBytes:&parent_count_at length:8u atIndex:7]; [encoder setBytes:node_seed length:32u atIndex:8];
        [encoder setBytes:&domain_prefix_bytes length:4u atIndex:9];
        [encoder dispatchThreads:MTLSizeMake(parents,1u,1u) threadsPerThreadgroup:MTLSizeMake(MIN(parents,256u),1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_sparse_leaves(
    void *runtime_ptr, void *arena_ptr, uint64_t column_offsets, uint64_t column_logs,
    uint32_t column_count, uint32_t lifting_log, uint64_t leaf_indices,
    uint64_t leaf_count_at, uint32_t max_leaf_count, uint64_t output_hashes,
    const uint32_t leaf_seed[8], uint32_t domain_prefix_bytes,
    double *gpu_milliseconds, char *error_message,
    size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||leaf_seed==NULL||column_count==0u||lifting_log>=31u||max_leaf_count==0u||
       (domain_prefix_bytes!=0u&&domain_prefix_bytes!=64u))return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t);
        if((NSUInteger)column_offsets+(NSUInteger)column_count*2u>words||(NSUInteger)column_logs+column_count>words||
           (NSUInteger)leaf_indices+max_leaf_count>words||leaf_count_at>=words||(NSUInteger)output_hashes+(NSUInteger)max_leaf_count*8u>words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitSparseLeavesResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBytes:&column_offsets length:8u atIndex:1]; [encoder setBytes:&column_logs length:8u atIndex:2];
        [encoder setBytes:&column_count length:4u atIndex:3]; [encoder setBytes:&lifting_log length:4u atIndex:4];
        [encoder setBytes:&leaf_indices length:8u atIndex:5]; [encoder setBytes:&leaf_count_at length:8u atIndex:6];
        [encoder setBytes:&max_leaf_count length:4u atIndex:7]; [encoder setBytes:&output_hashes length:8u atIndex:8];
        [encoder setBytes:leaf_seed length:32u atIndex:9];
        [encoder setBytes:&domain_prefix_bytes length:4u atIndex:10];
        [encoder dispatchThreads:MTLSizeMake(max_leaf_count,1u,1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)max_leaf_count,256u),1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_sparse_leaf_group(
    void *runtime_ptr, void *arena_ptr, uint64_t column_offsets, uint64_t column_logs,
    uint32_t column_count, uint32_t first_column, uint32_t total_columns,
    uint32_t lifting_log, uint64_t leaf_indices, uint64_t leaf_count_at,
    uint32_t max_leaf_count, uint64_t output_hashes, const uint32_t leaf_seed[8],
    uint32_t domain_prefix_bytes, double *gpu_milliseconds,
    char *error_message, size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||leaf_seed==NULL||column_count==0u||column_count>16u||
       total_columns==0u||first_column>=total_columns||column_count>total_columns-first_column||
       (first_column&15u)!=0u||(first_column+column_count<total_columns&&(column_count&15u)!=0u)||
       lifting_log>=31u||max_leaf_count==0u||
       (domain_prefix_bytes!=0u&&domain_prefix_bytes!=64u))return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t);
        if((NSUInteger)column_offsets+(NSUInteger)column_count*2u>words||(NSUInteger)column_logs+column_count>words||
           (NSUInteger)leaf_indices+max_leaf_count>words||leaf_count_at>=words||
           (NSUInteger)output_hashes+(NSUInteger)max_leaf_count*8u>words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitSparseLeafGroupResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBytes:&column_offsets length:8u atIndex:1]; [encoder setBytes:&column_logs length:8u atIndex:2];
        [encoder setBytes:&column_count length:4u atIndex:3]; [encoder setBytes:&first_column length:4u atIndex:4];
        [encoder setBytes:&total_columns length:4u atIndex:5]; [encoder setBytes:&lifting_log length:4u atIndex:6];
        [encoder setBytes:&leaf_indices length:8u atIndex:7]; [encoder setBytes:&leaf_count_at length:8u atIndex:8];
        [encoder setBytes:&max_leaf_count length:4u atIndex:9]; [encoder setBytes:&output_hashes length:8u atIndex:10];
        [encoder setBytes:leaf_seed length:32u atIndex:11];
        [encoder setBytes:&domain_prefix_bytes length:4u atIndex:12];
        [encoder dispatchThreads:MTLSizeMake(max_leaf_count,1u,1u) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)max_leaf_count,256u),1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}

bool stwo_zig_metal_decommit_trace_group(
    void *runtime_ptr, void *arena_ptr, const StwoZigDecommitTraceGroupParams *params,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||params==NULL||params->column_count==0u||
       params->column_count>16u||params->max_queries==0u||params->stride<params->max_queries||
       (params->domain_prefix_bytes!=0u&&params->domain_prefix_bytes!=64u)||
       params->lifting_log>=31u||params->total_columns==0u||params->first_column>=params->total_columns||
       params->column_count>params->total_columns-params->first_column||(params->first_column&15u)!=0u||
       (params->first_column+params->column_count<params->total_columns&&(params->column_count&15u)!=0u)||
       params->max_leaf_count==0u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t);
        NSUInteger output_end=(NSUInteger)params->values+
            ((NSUInteger)params->first_column+params->column_count)*params->stride;
        if((NSUInteger)params->column_offsets+(NSUInteger)params->column_count*2u>words||
           (NSUInteger)params->column_logs+params->column_count>words||
           (NSUInteger)params->queries+params->max_queries>words||params->query_count_at>=words||
           output_end>words||(NSUInteger)params->leaf_indices+params->max_leaf_count>words||
           params->leaf_count_at>=words||
           (NSUInteger)params->output_hashes+(NSUInteger)params->max_leaf_count*8u>words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> gather=[command computeCommandEncoder];
        [gather setComputePipelineState:runtime.decommitGatherTraceValuesResident]; [gather setBuffer:arena offset:0 atIndex:0];
        [gather setBytes:&params->column_offsets length:8u atIndex:1]; [gather setBytes:&params->column_logs length:8u atIndex:2];
        [gather setBytes:&params->column_count length:4u atIndex:3]; [gather setBytes:&params->lifting_log length:4u atIndex:4];
        [gather setBytes:&params->queries length:8u atIndex:5]; [gather setBytes:&params->query_count_at length:8u atIndex:6];
        [gather setBytes:&params->max_queries length:4u atIndex:7]; [gather setBytes:&params->first_column length:4u atIndex:8];
        [gather setBytes:&params->stride length:4u atIndex:9]; [gather setBytes:&params->values length:8u atIndex:10];
        MTLSize gather_threads=MTLSizeMake(MIN((NSUInteger)params->max_queries,32u),MIN((NSUInteger)params->column_count,8u),1u);
        [gather dispatchThreads:MTLSizeMake(params->max_queries,params->column_count,1u) threadsPerThreadgroup:gather_threads];
        [gather endEncoding];
        id<MTLComputeCommandEncoder> leaves=[command computeCommandEncoder];
        [leaves setComputePipelineState:runtime.decommitSparseLeafGroupResident]; [leaves setBuffer:arena offset:0 atIndex:0];
        [leaves setBytes:&params->column_offsets length:8u atIndex:1]; [leaves setBytes:&params->column_logs length:8u atIndex:2];
        [leaves setBytes:&params->column_count length:4u atIndex:3]; [leaves setBytes:&params->first_column length:4u atIndex:4];
        [leaves setBytes:&params->total_columns length:4u atIndex:5]; [leaves setBytes:&params->lifting_log length:4u atIndex:6];
        [leaves setBytes:&params->leaf_indices length:8u atIndex:7]; [leaves setBytes:&params->leaf_count_at length:8u atIndex:8];
        [leaves setBytes:&params->max_leaf_count length:4u atIndex:9]; [leaves setBytes:&params->output_hashes length:8u atIndex:10];
        [leaves setBytes:params->leaf_seed length:32u atIndex:11];
        [leaves setBytes:&params->domain_prefix_bytes length:4u atIndex:12];
        [leaves dispatchThreads:MTLSizeMake(params->max_leaf_count,1u,1u)
             threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)params->max_leaf_count,256u),1u,1u)];
        [leaves endEncoding];
        [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0;
        return true;
    }
}

bool stwo_zig_metal_decommit_assemble_trace(
    void *runtime_ptr, void *arena_ptr, uint32_t tree_index, uint32_t role,
    uint32_t leaf_log, uint32_t first_retained_log, uint32_t column_count,
    uint64_t mapped, uint64_t mapped_count_at, uint32_t max_queries,
    uint64_t walk, uint64_t scratch, uint64_t walk_count_at, uint64_t values,
    uint64_t retained_offsets, uint64_t sparse_indices, uint64_t sparse_hashes,
    uint64_t sparse_offsets, uint64_t sparse_counts, uint32_t sparse_level_count,
    uint64_t assembly, uint32_t capacity, double *gpu_milliseconds,
    char *error_message, size_t error_message_len
) {
    if(runtime_ptr==NULL||arena_ptr==NULL||leaf_log>=31u||column_count==0u||max_queries==0u||capacity==0u)return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime=(__bridge StwoZigMetalRuntime *)runtime_ptr; id<MTLBuffer> arena=(__bridge id<MTLBuffer>)arena_ptr;
        NSUInteger words=arena.length/sizeof(uint32_t);
        if(mapped_count_at>=words||walk_count_at>=words||(NSUInteger)retained_offsets+(NSUInteger)(first_retained_log+1u)*2u>words||
           (NSUInteger)sparse_offsets+sparse_level_count>words||(NSUInteger)sparse_counts+sparse_level_count>words||(NSUInteger)assembly+capacity>words)return false;
        id<MTLCommandBuffer> command=[runtime.queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:runtime.decommitAssembleTraceResident]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBytes:&tree_index length:4u atIndex:1]; [encoder setBytes:&role length:4u atIndex:2];
        [encoder setBytes:&leaf_log length:4u atIndex:3]; [encoder setBytes:&first_retained_log length:4u atIndex:4];
        [encoder setBytes:&column_count length:4u atIndex:5]; [encoder setBytes:&mapped length:8u atIndex:6];
        [encoder setBytes:&mapped_count_at length:8u atIndex:7]; [encoder setBytes:&max_queries length:4u atIndex:8];
        [encoder setBytes:&walk length:8u atIndex:9]; [encoder setBytes:&scratch length:8u atIndex:10];
        [encoder setBytes:&walk_count_at length:8u atIndex:11]; [encoder setBytes:&values length:8u atIndex:12];
        [encoder setBytes:&retained_offsets length:8u atIndex:13]; [encoder setBytes:&sparse_indices length:8u atIndex:14];
        [encoder setBytes:&sparse_hashes length:8u atIndex:15]; [encoder setBytes:&sparse_offsets length:8u atIndex:16];
        [encoder setBytes:&sparse_counts length:8u atIndex:17]; [encoder setBytes:&sparse_level_count length:4u atIndex:18];
        [encoder setBytes:&assembly length:8u atIndex:19]; [encoder setBytes:&capacity length:4u atIndex:20];
        [encoder dispatchThreads:MTLSizeMake(1u,1u,1u) threadsPerThreadgroup:MTLSizeMake(1u,1u,1u)]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if(command.status==MTLCommandBufferStatusError){write_error(error_message,error_message_len,command.error.localizedDescription);return false;}
        if(gpu_milliseconds)*gpu_milliseconds=(command.GPUEndTime-command.GPUStartTime)*1000.0; return true;
    }
}
