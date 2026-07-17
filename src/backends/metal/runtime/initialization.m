void *stwo_zig_metal_runtime_create(
    const char *source_utf8,
    char *error_message,
    size_t error_message_len
) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            write_error(error_message, error_message_len, @"No Metal device available");
            return NULL;
        }
        NSString *source = [NSString stringWithUTF8String:source_utf8];
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.mathMode = MTLMathModeSafe;
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
        if (library == nil) {
            write_error(error_message, error_message_len,
                        error.localizedDescription ?: @"Failed to compile Metal library");
            return NULL;
        }
        StwoZigMetalRuntime *runtime = create_runtime_from_library(
            device, library, error_message, error_message_len
        );
        return runtime == nil ? NULL : (__bridge_retained void *)runtime;
    }
}

void *stwo_zig_metal_runtime_create_from_metallib(
    const char *path_bytes,
    size_t path_len,
    char *error_message,
    size_t error_message_len
) {
    if (path_bytes == NULL || path_len == 0u) {
        write_error(error_message, error_message_len, @"Metal library path is empty");
        return NULL;
    }
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            write_error(error_message, error_message_len, @"No Metal device available");
            return NULL;
        }
        NSString *path = [[NSString alloc] initWithBytes:path_bytes
                                                  length:path_len
                                                encoding:NSUTF8StringEncoding];
        if (path == nil) {
            write_error(error_message, error_message_len, @"Invalid Metal library path encoding");
            return NULL;
        }
        NSString *canonical_path = [[path stringByStandardizingPath] stringByResolvingSymlinksInPath];
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:canonical_path]
                                                    error:&error];
        if (library == nil) {
            write_error(error_message, error_message_len,
                        error.localizedDescription ?: @"Failed to load Metal library");
            return NULL;
        }
        StwoZigMetalRuntime *runtime = create_runtime_from_library(
            device, library, error_message, error_message_len
        );
        return runtime == nil ? NULL : (__bridge_retained void *)runtime;
    }
}
