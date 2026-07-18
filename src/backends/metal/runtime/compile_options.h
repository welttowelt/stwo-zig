#ifndef STWO_ZIG_METAL_COMPILE_OPTIONS_H
#define STWO_ZIG_METAL_COMPILE_OPTIONS_H

#import <Availability.h>
#import <Metal/Metal.h>

static inline void stwo_zig_configure_safe_metal_compile_options(
    MTLCompileOptions *options
) {
#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 150000
    if (@available(macOS 15.0, *)) {
        options.mathMode = MTLMathModeSafe;
    } else {
        options.fastMathEnabled = NO;
    }
#else
    options.fastMathEnabled = NO;
#endif
    options.languageVersion = MTLLanguageVersion3_1;
}

#endif
