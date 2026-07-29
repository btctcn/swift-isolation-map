// Minimal C shim over `sourcekitd`'s C ABI (types copied verbatim from `swiftlang/swift`'s real
// `tools/SourceKit/tools/sourcekitd/include/sourcekitd/sourcekitd.h`).
//
// Exists because `sourcekitd_variant_t` (a 24-byte-by-value struct) is passed/returned indirectly
// per the platform ABI once it exceeds 16 bytes -- Swift's `@convention(c)` function types cannot
// express that indirection for a plain Swift-native struct ("not representable in Objective-C",
// confirmed empirically while building this target directly in pure Swift first). Real C code has
// no such restriction and Swift's own ClangImporter already knows how to bridge real C structs
// correctly (the same mechanism that makes `CGPoint`/`CGRect` work) -- so this shim resolves every
// symbol via `dlopen`/`dlsym` in C, once, and exposes ordinary C functions Swift imports normally.
#ifndef SWIFT_ISOLATION_MAP_CSOURCEKITD_H
#define SWIFT_ISOLATION_MAP_CSOURCEKITD_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct sourcekitd_uid_s *sourcekitd_uid_t;
typedef void *sourcekitd_object_t;
typedef void *sourcekitd_response_t;

typedef struct {
    uint64_t data[3];
} sourcekitd_variant_t;

// Resolves `dylibPath` via `dlopen` and every symbol this shim needs via `dlsym`. Returns 0 on
// success; nonzero (with a message available via `sourcekitd_shim_last_error`) on failure. Must be
// called exactly once, before any other `sourcekitd_shim_*` function.
int sourcekitd_shim_load(const char *dylibPath);

// The `dlopen`/`dlsym` failure message from the most recent failed `sourcekitd_shim_load` call, or
// NULL if the most recent call succeeded.
const char *sourcekitd_shim_last_error(void);

void sourcekitd_shim_initialize(void);

sourcekitd_uid_t sourcekitd_shim_uid_get_from_cstr(const char *string);
const char *sourcekitd_shim_uid_get_string_ptr(sourcekitd_uid_t uid);

void sourcekitd_shim_request_release(sourcekitd_object_t object);
sourcekitd_object_t sourcekitd_shim_request_dictionary_create(
    const sourcekitd_uid_t *keys, const sourcekitd_object_t *values, size_t count);
void sourcekitd_shim_request_dictionary_set_value(sourcekitd_object_t dict, sourcekitd_uid_t key, sourcekitd_object_t value);
void sourcekitd_shim_request_dictionary_set_string(sourcekitd_object_t dict, sourcekitd_uid_t key, const char *string);
void sourcekitd_shim_request_dictionary_set_int64(sourcekitd_object_t dict, sourcekitd_uid_t key, int64_t val);
void sourcekitd_shim_request_dictionary_set_uid(sourcekitd_object_t dict, sourcekitd_uid_t key, sourcekitd_uid_t uid);

sourcekitd_object_t sourcekitd_shim_request_array_create(const sourcekitd_object_t *objects, size_t count);
// Always appends at `SOURCEKITD_ARRAY_APPEND` (`(size_t)(-1)`) -- there is no index parameter, so
// no caller can pass the wrong one. Sequential indices into a still-empty array crash the process
// (`_xpc_api_misuse`) -- found the hard way during this project's research spike.
void sourcekitd_shim_request_array_append_string(sourcekitd_object_t array, const char *string);

sourcekitd_response_t sourcekitd_shim_send_request_sync(sourcekitd_object_t req);
void sourcekitd_shim_response_dispose(sourcekitd_response_t obj);
bool sourcekitd_shim_response_is_error(sourcekitd_response_t obj);
const char *sourcekitd_shim_response_error_get_description(sourcekitd_response_t err);
sourcekitd_variant_t sourcekitd_shim_response_get_value(sourcekitd_response_t resp);

int32_t sourcekitd_shim_variant_get_type(sourcekitd_variant_t obj);
sourcekitd_variant_t sourcekitd_shim_variant_dictionary_get_value(sourcekitd_variant_t dict, sourcekitd_uid_t key);
const char *sourcekitd_shim_variant_dictionary_get_string(sourcekitd_variant_t dict, sourcekitd_uid_t key);
int64_t sourcekitd_shim_variant_dictionary_get_int64(sourcekitd_variant_t dict, sourcekitd_uid_t key);
size_t sourcekitd_shim_variant_array_get_count(sourcekitd_variant_t array);
sourcekitd_variant_t sourcekitd_shim_variant_array_get_value(sourcekitd_variant_t array, size_t index);
const char *sourcekitd_shim_variant_string_get_ptr(sourcekitd_variant_t obj);
sourcekitd_uid_t sourcekitd_shim_variant_uid_get_value(sourcekitd_variant_t obj);

// Diagnostic-only: recursively dumps an arbitrary, not-yet-understood response variant (any
// dictionary/array/scalar shape) as indented "key: value" text into a static, non-thread-safe
// internal buffer, valid until the next call. Exists to pin down a real response's actual shape
// (e.g. `source.request.statistics`) empirically, by literal enumeration via
// `sourcekitd_variant_dictionary_apply_f`, rather than guessing key names from binary strings --
// not meant for concurrent or production use.
const char *sourcekitd_shim_dump_variant(sourcekitd_variant_t variant);

#endif
