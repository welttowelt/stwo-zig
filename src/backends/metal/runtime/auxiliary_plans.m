void *stwo_zig_metal_ec_op_prepare(
    void *runtime_ptr, const uint32_t *execution_offsets, const uint32_t *trace_offsets,
    const uint32_t *partial_offsets, const uint32_t *multiplicity_offsets,
    uint32_t lookup_offset, uint32_t segment_offset, uint32_t scratch_offset, uint32_t row_count,
    bool write_base,
    bool write_lookup,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || execution_offsets == NULL || trace_offsets == NULL || partial_offsets == NULL ||
        multiplicity_offsets == NULL || (!write_base && !write_lookup) || row_count < 16u ||
        (row_count & (row_count - 1u)) != 0u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigEcOpPlan *plan = [StwoZigEcOpPlan new];
        uint32_t params[6] = {
            lookup_offset, segment_offset, scratch_offset, row_count,
            write_lookup ? 1u : 0u, write_base ? 1u : 0u,
        };
        plan.executionOffsets = [runtime.device newBufferWithBytes:execution_offsets length:37u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.traceOffsets = [runtime.device newBufferWithBytes:trace_offsets length:273u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.partialOffsets = [runtime.device newBufferWithBytes:partial_offsets length:127u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.multiplicityOffsets = [runtime.device newBufferWithBytes:multiplicity_offsets length:4u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.params = [runtime.device newBufferWithBytes:params length:sizeof(params) options:MTLResourceStorageModeShared];
        plan.pipeline = write_base ? runtime.ecOpWitness : runtime.ecOpLookup;
        plan.rowCount = row_count;
        plan.threadgroupWidth = write_base ? 256u : 128u;
        plan.writeBase = write_base;
        if (plan.executionOffsets == nil || plan.traceOffsets == nil || plan.partialOffsets == nil ||
            plan.multiplicityOffsets == nil || plan.params == nil || plan.pipeline == nil) {
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
