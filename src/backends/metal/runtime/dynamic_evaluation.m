void *stwo_zig_metal_eval_prepare(
    void *runtime_ptr, const char *source_bytes, size_t source_len,
    const char *name_bytes, size_t name_len, const uint32_t *arguments,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || source_bytes == NULL || source_len == 0u ||
        name_bytes == NULL || name_len == 0u || arguments == NULL || arguments[10] == 0u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        NSString *source = [[NSString alloc] initWithBytes:source_bytes length:source_len encoding:NSUTF8StringEncoding];
        NSString *name = [[NSString alloc] initWithBytes:name_bytes length:name_len encoding:NSUTF8StringEncoding];
        if (source == nil || name == nil) {
            write_error(error_message, error_message_len, @"Invalid Metal evaluation source encoding"); return NULL;
        }
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.mathMode = MTLMathModeSafe;
        NSError *error = nil;
        id<MTLLibrary> library = [runtime.device newLibraryWithSource:source options:options error:&error];
        if (library == nil) {
            write_error(error_message, error_message_len,
                        error.localizedDescription ?: @"Failed to compile Metal evaluation program");
            return NULL;
        }
        id<MTLComputePipelineState> pipeline = make_pipeline(runtime.device, library, name, error_message, error_message_len);
        if (pipeline == nil) return NULL;
        StwoZigEvalPlan *plan = [StwoZigEvalPlan new];
        plan.pipeline = pipeline;
        plan.arguments = [runtime.device newBufferWithBytes:arguments length:14u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.rowCount = arguments[10];
        if (plan.arguments == nil) {
            write_error(error_message, error_message_len, @"Metal evaluation argument allocation failed"); return NULL;
        }
        return (__bridge_retained void *)plan;
    }
}

static NSString *eval_source_sha256_hex(const char *bytes, size_t length) {
    CC_SHA256_CTX context;
    if (CC_SHA256_Init(&context) != 1) return nil;
    size_t consumed = 0u;
    while (consumed < length) {
        size_t remaining = length - consumed;
        CC_LONG chunk = (CC_LONG)MIN(remaining, (size_t)UINT32_MAX);
        if (CC_SHA256_Update(&context, bytes + consumed, chunk) != 1) return nil;
        consumed += chunk;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (CC_SHA256_Final(digest, &context) != 1) return nil;
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2u];
    for (size_t i = 0u; i < CC_SHA256_DIGEST_LENGTH; ++i) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSString *eval_metallib_archive_path(NSString *digest, size_t length) {
    NSString *archiveName = [NSString stringWithFormat:
        @"stwo-zig-eval-metallib-sha256-%@-%zu.binarchive", digest, length];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:archiveName];
}

static bool serialize_eval_archive(StwoZigEvalLibrary *library, NSError **error, bool *didSerialize) {
    if (didSerialize != NULL) *didSerialize = false;
    @synchronized(library) {
        if (library.archive == nil || library.archiveURL == nil) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:@"StwoZigMetalRuntime" code:1
                    userInfo:@{NSLocalizedDescriptionKey: @"Metal library has no binary archive"}];
            }
            return false;
        }
        if (!library.archiveDirty) return true;
        if (![library.archive serializeToURL:library.archiveURL error:error]) return false;
        library.archiveDirty = false;
        if (didSerialize != NULL) *didSerialize = true;
        return true;
    }
}

static id<MTLComputePipelineState> resolve_eval_pipeline(
    StwoZigMetalRuntime *runtime, StwoZigEvalLibrary *library, NSString *name,
    char *error_message, size_t error_message_len
) {
    @synchronized(runtime) {
        CFAbsoluteTime prepareStart = CFAbsoluteTimeGetCurrent();
        @try {
            NSString *pipelineKey = nil;
            if (library.cacheKey != nil) {
                pipelineKey = [NSString stringWithFormat:@"%lu:%@%@",
                    (unsigned long)library.cacheKey.length, library.cacheKey, name];
                id<MTLComputePipelineState> cached = runtime.evalPipelines[pipelineKey];
                if (cached != nil) {
                    runtime.evalPipelineCacheHits += 1u;
                    return cached;
                }
            }

            id<MTLFunction> function = [library.library newFunctionWithName:name];
            if (function == nil) {
                write_error(error_message, error_message_len,
                            [NSString stringWithFormat:@"Missing Metal function %@", name]);
                return nil;
            }

            NSError *error = nil;
            id<MTLComputePipelineState> pipeline = nil;
            if (library.archive == nil) {
                runtime.evalDirectCompiles += 1u;
                pipeline = [runtime.device newComputePipelineStateWithFunction:function error:&error];
            } else {
                @synchronized(library) {
                    MTLComputePipelineDescriptor *descriptor = [MTLComputePipelineDescriptor new];
                    descriptor.computeFunction = function;
                    descriptor.binaryArchives = @[library.archive];

                    if (library.archiveLoaded) {
                        pipeline = [runtime.device newComputePipelineStateWithDescriptor:descriptor
                            options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&error];
                        if (pipeline != nil) runtime.evalBinaryArchiveHits += 1u;
                    }

                    if (pipeline == nil) {
                        NSError *archiveLookupError = error;
                        error = nil;
                        runtime.evalDirectCompiles += 1u;
                        pipeline = [runtime.device newComputePipelineStateWithFunction:function error:&error];
                        if (pipeline == nil) {
                            write_error(error_message, error_message_len,
                                error.localizedDescription ?: archiveLookupError.localizedDescription ?:
                                @"Failed to compile Metal evaluation pipeline");
                            return nil;
                        }

                        // A direct compile succeeding distinguishes an archive miss from a real pipeline error.
                        runtime.evalBinaryArchiveMisses += 1u;
                        NSError *archiveError = nil;
                        if (![library.archive addComputePipelineFunctionsWithDescriptor:descriptor error:&archiveError]) {
                            write_error(error_message, error_message_len,
                                archiveError.localizedDescription ?: @"Failed to add Metal pipeline to binary archive");
                            return nil;
                        }
                        runtime.evalArchivePopulations += 1u;
                        library.archiveLoaded = true;
                        library.archiveDirty = true;
                    }
                }
            }

            if (pipeline == nil) {
                write_error(error_message, error_message_len,
                            error.localizedDescription ?: @"Failed to resolve Metal evaluation pipeline");
                return nil;
            }
            stwo_zig_metal_profile_name_pipeline(pipeline, name);
            if (pipelineKey != nil) runtime.evalPipelines[pipelineKey] = pipeline;
            return pipeline;
        } @finally {
            runtime.evalPipelinePreparationSeconds += CFAbsoluteTimeGetCurrent() - prepareStart;
        }
    }
}

void *stwo_zig_metal_eval_library_load(
    void *runtime_ptr, const char *path_bytes, size_t path_len,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || path_bytes == NULL || path_len == 0u) return NULL;
    @autoreleasepool {
        CFAbsoluteTime prepareStart = CFAbsoluteTimeGetCurrent();
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        NSString *path = [[NSString alloc] initWithBytes:path_bytes length:path_len encoding:NSUTF8StringEncoding];
        if (path == nil) { write_error(error_message, error_message_len, @"Invalid metallib path encoding"); return NULL; }
        NSString *canonicalPath = [[path stringByStandardizingPath] stringByResolvingSymlinksInPath];
        NSError *error = nil;
        NSData *libraryData = [NSData dataWithContentsOfFile:canonicalPath
            options:NSDataReadingMappedIfSafe error:&error];
        if (libraryData == nil || libraryData.length == 0u) {
            write_error(error_message, error_message_len,
                        error.localizedDescription ?: @"Failed to read Metal evaluation library");
            return NULL;
        }
        NSString *libraryDigest = eval_source_sha256_hex(libraryData.bytes, libraryData.length);
        if (libraryDigest == nil || libraryDigest.length != CC_SHA256_DIGEST_LENGTH * 2u) {
            write_error(error_message, error_message_len, @"Failed to identify Metal evaluation library");
            return NULL;
        }
        NSString *cacheKey = [NSString stringWithFormat:@"metallib:sha256:%@:%zu",
                                                       libraryDigest, libraryData.length];
        @synchronized(runtime) {
            StwoZigEvalLibrary *cached = runtime.evalLibraries[cacheKey];
            if (cached != nil) {
                runtime.evalLibraryCacheHits += 1u;
                return (__bridge_retained void *)cached;
            }
            runtime.evalLibraryCacheMisses += 1u;
            @try {
                id<MTLLibrary> metalLibrary =
                    [runtime.device newLibraryWithURL:[NSURL fileURLWithPath:canonicalPath] error:&error];
                if (metalLibrary == nil) {
                    write_error(error_message, error_message_len,
                                error.localizedDescription ?: @"Failed to load Metal evaluation library");
                    return NULL;
                }
                StwoZigEvalLibrary *result = [StwoZigEvalLibrary new];
                result.library = metalLibrary;
                result.cacheKey = cacheKey;
                result.runtimeOwner = runtime;
                NSString *archivePath = eval_metallib_archive_path(libraryDigest, libraryData.length);
                result.archiveURL = [NSURL fileURLWithPath:archivePath];
                result.archiveLoaded = [[NSFileManager defaultManager] fileExistsAtPath:archivePath];
                MTLBinaryArchiveDescriptor *archiveDescriptor = [MTLBinaryArchiveDescriptor new];
                if (result.archiveLoaded) archiveDescriptor.url = result.archiveURL;
                result.archive = [runtime.device newBinaryArchiveWithDescriptor:archiveDescriptor error:&error];
                if (result.archive == nil) {
                    write_error(error_message, error_message_len,
                                error.localizedDescription ?: @"Failed to load Metal binary archive");
                    return NULL;
                }
                runtime.evalLibraries[cacheKey] = result;
                return (__bridge_retained void *)result;
            } @finally {
                runtime.evalLibraryPreparationSeconds += CFAbsoluteTimeGetCurrent() - prepareStart;
            }
        }
    }
}

void *stwo_zig_metal_eval_library_compile(
    void *runtime_ptr, const char *source_bytes, size_t source_len,
    char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || source_bytes == NULL || source_len == 0u) return NULL;
    @autoreleasepool {
        CFAbsoluteTime prepareStart = CFAbsoluteTimeGetCurrent();
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        NSString *source = [[NSString alloc] initWithBytes:source_bytes length:source_len encoding:NSUTF8StringEncoding];
        if (source == nil) {
            write_error(error_message, error_message_len, @"Invalid Metal source library encoding");
            return NULL;
        }
        NSString *sourceDigest = eval_source_sha256_hex(source_bytes, source_len);
        NSData *sourceData = [NSData dataWithBytes:source_bytes length:source_len];
        if (sourceDigest == nil || sourceDigest.length != CC_SHA256_DIGEST_LENGTH * 2u || sourceData == nil) {
            write_error(error_message, error_message_len, @"Failed to identify Metal source library");
            return NULL;
        }
        NSString *cacheKey = [NSString stringWithFormat:@"source:sha256:%@:%zu", sourceDigest, source_len];
        @synchronized(runtime) {
            StwoZigEvalLibrary *cached = runtime.evalLibraries[cacheKey];
            if (cached != nil) {
                if (cached.sourceBytes == nil || ![cached.sourceBytes isEqualToData:sourceData]) {
                    write_error(error_message, error_message_len, @"Metal source cache identity collision");
                    return NULL;
                }
                runtime.evalLibraryCacheHits += 1u;
                return (__bridge_retained void *)cached;
            }
            runtime.evalLibraryCacheMisses += 1u;
            @try {
                MTLCompileOptions *options = [MTLCompileOptions new];
                options.mathMode = MTLMathModeSafe;
                NSError *error = nil;
                id<MTLLibrary> library = [runtime.device newLibraryWithSource:source options:options error:&error];
                if (library == nil) {
                    write_error(error_message, error_message_len,
                                error.localizedDescription ?: @"Failed to compile Metal source library");
                    return NULL;
                }
                StwoZigEvalLibrary *result = [StwoZigEvalLibrary new];
                result.library = library;
                result.cacheKey = cacheKey;
                result.sourceBytes = sourceData;
                result.runtimeOwner = runtime;
                NSString *archiveName = [NSString stringWithFormat:@"stwo-zig-eval-sha256-%@-%zu.binarchive",
                    sourceDigest, source_len];
                NSString *archivePath = [NSTemporaryDirectory() stringByAppendingPathComponent:archiveName];
                result.archiveURL = [NSURL fileURLWithPath:archivePath];
                result.archiveLoaded = [[NSFileManager defaultManager] fileExistsAtPath:archivePath];
                MTLBinaryArchiveDescriptor *archiveDescriptor = [MTLBinaryArchiveDescriptor new];
                if (result.archiveLoaded) archiveDescriptor.url = result.archiveURL;
                result.archive = [runtime.device newBinaryArchiveWithDescriptor:archiveDescriptor error:&error];
                if (result.archive == nil) {
                    write_error(error_message, error_message_len,
                                error.localizedDescription ?: @"Failed to load Metal source binary archive");
                    return NULL;
                }
                runtime.evalLibraries[cacheKey] = result;
                return (__bridge_retained void *)result;
            } @finally {
                runtime.evalLibraryPreparationSeconds += CFAbsoluteTimeGetCurrent() - prepareStart;
            }
        }
    }
}

void stwo_zig_metal_eval_library_destroy(void *library_ptr) {
    if (library_ptr != NULL) CFRelease(library_ptr);
}

void *stwo_zig_metal_witness_prepare_library(
    void *runtime_ptr, void *library_ptr, const char *name_bytes, size_t name_len,
    const uint32_t *arguments, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || library_ptr == NULL || name_bytes == NULL || name_len == 0u ||
        arguments == NULL || arguments[7] == 0u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigEvalLibrary *library = (__bridge StwoZigEvalLibrary *)library_ptr;
        NSString *name = [[NSString alloc] initWithBytes:name_bytes length:name_len encoding:NSUTF8StringEncoding];
        if (name == nil) { write_error(error_message, error_message_len, @"Invalid Metal witness function encoding"); return NULL; }
        id<MTLComputePipelineState> pipeline =
            resolve_eval_pipeline(runtime, library, name, error_message, error_message_len);
        if (pipeline == nil) return NULL;
        StwoZigWitnessPlan *plan = [StwoZigWitnessPlan new];
        plan.pipeline = pipeline;
        plan.arguments = [runtime.device newBufferWithBytes:arguments length:11u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.rowCount = arguments[7];
        if (plan.arguments == nil) { write_error(error_message, error_message_len, @"Metal witness argument allocation failed"); return NULL; }
        return (__bridge_retained void *)plan;
    }
}

void stwo_zig_metal_witness_plan_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

bool stwo_zig_metal_witness_prepared(
    void *runtime_ptr, void *arena_ptr, void *plan_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || plan_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigWitnessPlan *plan = (__bridge StwoZigWitnessPlan *)plan_ptr;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:plan.pipeline]; [encoder setBuffer:arena offset:0 atIndex:0];
        [encoder setBuffer:plan.arguments offset:0 atIndex:1];
        NSUInteger width = MIN((NSUInteger)256u, MIN((NSUInteger)plan.rowCount, plan.pipeline.maxTotalThreadsPerThreadgroup));
        [encoder dispatchThreads:MTLSizeMake(plan.rowCount, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { write_error(error_message, error_message_len, command.error.localizedDescription); return false; }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}

void *stwo_zig_metal_eval_prepare_library(
    void *runtime_ptr, void *library_ptr, const char *name_bytes, size_t name_len,
    const uint32_t *arguments, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || library_ptr == NULL || name_bytes == NULL || name_len == 0u ||
        arguments == NULL || arguments[10] == 0u) return NULL;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        StwoZigEvalLibrary *library = (__bridge StwoZigEvalLibrary *)library_ptr;
        NSString *name = [[NSString alloc] initWithBytes:name_bytes length:name_len encoding:NSUTF8StringEncoding];
        if (name == nil) { write_error(error_message, error_message_len, @"Invalid Metal function encoding"); return NULL; }
        id<MTLComputePipelineState> pipeline =
            resolve_eval_pipeline(runtime, library, name, error_message, error_message_len);
        if (pipeline == nil) return NULL;
        StwoZigEvalPlan *plan = [StwoZigEvalPlan new];
        plan.pipeline = pipeline;
        plan.arguments = [runtime.device newBufferWithBytes:arguments length:14u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        plan.rowCount = arguments[10];
        if (plan.arguments == nil) { write_error(error_message, error_message_len, @"Metal evaluation argument allocation failed"); return NULL; }
        return (__bridge_retained void *)plan;
    }
}

bool stwo_zig_metal_eval_library_serialize(
    void *library_ptr, char *error_message, size_t error_message_len
) {
    if (library_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigEvalLibrary *library = (__bridge StwoZigEvalLibrary *)library_ptr;
        NSError *error = nil;
        bool didSerialize = false;
        if (!serialize_eval_archive(library, &error, &didSerialize)) {
            write_error(error_message, error_message_len, error.localizedDescription ?: @"Failed to serialize Metal binary archive");
            return false;
        }
        StwoZigMetalRuntime *runtimeOwner = library.runtimeOwner;
        if (didSerialize && runtimeOwner != nil) {
            @synchronized(runtimeOwner) {
                runtimeOwner.evalArchiveSerializations += 1u;
            }
        }
        return true;
    }
}

void stwo_zig_metal_eval_destroy(void *plan_ptr) {
    if (plan_ptr != NULL) CFRelease(plan_ptr);
}

void *stwo_zig_metal_eval_batch_prepare(
    const void *const *plan_ptrs, uint32_t plan_count,
    char *error_message, size_t error_message_len
) {
    if (plan_ptrs == NULL || plan_count == 0u) return NULL;
    @autoreleasepool {
        NSMutableArray<StwoZigEvalPlan *> *plans = [NSMutableArray arrayWithCapacity:plan_count];
        for (uint32_t i = 0; i < plan_count; ++i) {
            if (plan_ptrs[i] == NULL) {
                write_error(error_message, error_message_len, @"Null Metal evaluation plan in batch"); return NULL;
            }
            [plans addObject:(__bridge StwoZigEvalPlan *)plan_ptrs[i]];
        }
        StwoZigEvalBatch *batch = [StwoZigEvalBatch new];
        batch.plans = plans;
        return (__bridge_retained void *)batch;
    }
}

void stwo_zig_metal_eval_batch_destroy(void *batch_ptr) {
    if (batch_ptr != NULL) CFRelease(batch_ptr);
}

bool stwo_zig_metal_eval_batch_prepared(
    void *runtime_ptr, void *arena_ptr, void *batch_ptr,
    double *gpu_milliseconds, char *error_message, size_t error_message_len
) {
    if (runtime_ptr == NULL || arena_ptr == NULL || batch_ptr == NULL) return false;
    @autoreleasepool {
        StwoZigMetalRuntime *runtime = (__bridge StwoZigMetalRuntime *)runtime_ptr;
        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)arena_ptr;
        StwoZigEvalBatch *batch = (__bridge StwoZigEvalBatch *)batch_ptr;
        id<MTLCommandBuffer> command = [runtime.queue commandBuffer];
        for (StwoZigEvalPlan *plan in batch.plans) {
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:plan.pipeline];
            [encoder setBuffer:arena offset:0 atIndex:0];
            [encoder setBuffer:plan.arguments offset:0 atIndex:1];
            NSUInteger width = MIN((NSUInteger)256u, MIN((NSUInteger)plan.rowCount, plan.pipeline.maxTotalThreadsPerThreadgroup));
            [encoder dispatchThreads:MTLSizeMake(plan.rowCount, 1u, 1u) threadsPerThreadgroup:MTLSizeMake(width, 1u, 1u)];
            [encoder endEncoding];
        }
        [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) {
            write_error(error_message, error_message_len, command.error.localizedDescription); return false;
        }
        if (gpu_milliseconds) *gpu_milliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
        return true;
    }
}
