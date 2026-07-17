#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void write_error(char *destination, size_t length, NSString *message) {
    if (destination == NULL || length == 0u) return;
    const char *utf8 = message.UTF8String ?: "Metal core library probe failed";
    snprintf(destination, length, "%s", utf8);
}

static NSString *first_name(NSSet<NSString *> *names) {
    return [[names allObjects] sortedArrayUsingSelector:@selector(compare:)].firstObject ?: @"<none>";
}

bool stwo_zig_metal_core_probe(
    const uint8_t *metallib_bytes,
    size_t metallib_len,
    const char *const *expected_names,
    size_t expected_count,
    char *error_message,
    size_t error_message_len
) {
    if (metallib_bytes == NULL || metallib_len == 0u ||
        expected_names == NULL || expected_count == 0u) {
        write_error(error_message, error_message_len, @"Invalid Metal core probe input");
        return false;
    }

    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            write_error(error_message, error_message_len, @"No Metal device available");
            return false;
        }

        void *owned_bytes = malloc(metallib_len);
        if (owned_bytes == NULL) {
            write_error(error_message, error_message_len, @"Failed to copy metallib bytes");
            return false;
        }
        memcpy(owned_bytes, metallib_bytes, metallib_len);
        dispatch_data_t data = dispatch_data_create(
            owned_bytes,
            metallib_len,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
            ^{ free(owned_bytes); }
        );
        if (data == nil) {
            free(owned_bytes);
            write_error(error_message, error_message_len, @"Failed to wrap metallib bytes");
            return false;
        }

        NSError *load_error = nil;
        id<MTLLibrary> library = [device newLibraryWithData:data error:&load_error];
        if (library == nil) {
            write_error(
                error_message,
                error_message_len,
                load_error.localizedDescription ?: @"Failed to load metallib"
            );
            return false;
        }

        NSMutableArray<NSString *> *expected_array =
            [NSMutableArray arrayWithCapacity:expected_count];
        for (size_t index = 0u; index < expected_count; ++index) {
            if (expected_names[index] == NULL) {
                write_error(error_message, error_message_len, @"Null expected Metal function name");
                return false;
            }
            NSString *name = [NSString stringWithUTF8String:expected_names[index]];
            if (name == nil || name.length == 0u) {
                write_error(error_message, error_message_len, @"Invalid expected Metal function name");
                return false;
            }
            [expected_array addObject:name];
        }

        NSSet<NSString *> *expected = [NSSet setWithArray:expected_array];
        NSArray<NSString *> *actual_array = library.functionNames;
        NSSet<NSString *> *actual = [NSSet setWithArray:actual_array];
        if (expected.count != expected_count || actual_array.count != expected_count ||
            actual.count != expected_count || ![actual isEqualToSet:expected]) {
            NSMutableSet<NSString *> *missing = [expected mutableCopy];
            [missing minusSet:actual];
            NSMutableSet<NSString *> *unexpected = [actual mutableCopy];
            [unexpected minusSet:expected];
            write_error(
                error_message,
                error_message_len,
                [NSString stringWithFormat:
                    @"Metal export mismatch: expected=%zu actual=%lu missing=%@ unexpected=%@",
                    expected_count,
                    (unsigned long)actual_array.count,
                    first_name(missing),
                    first_name(unexpected)]
            );
            return false;
        }

        for (NSString *name in expected_array) {
            id<MTLFunction> function = [library newFunctionWithName:name];
            if (function == nil || function.functionType != MTLFunctionTypeKernel) {
                write_error(
                    error_message,
                    error_message_len,
                    [NSString stringWithFormat:@"Invalid Metal kernel export %@", name]
                );
                return false;
            }
            if (function.functionConstantsDictionary.count != 0u) {
                write_error(
                    error_message,
                    error_message_len,
                    [NSString stringWithFormat:@"Unexpected function constants for %@", name]
                );
                return false;
            }
        }
        return true;
    }
}
