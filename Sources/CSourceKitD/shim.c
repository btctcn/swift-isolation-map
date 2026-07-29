#include "CSourceKitD.h"
#include <dlfcn.h>
#include <string.h>
#include <pthread.h>
#include <stdio.h>
#include <stdarg.h>

#define SOURCEKITD_ARRAY_APPEND ((size_t)(-1))

typedef void (*initialize_fn)(void);
typedef sourcekitd_uid_t (*uid_get_from_cstr_fn)(const char *);
typedef const char *(*uid_get_string_ptr_fn)(sourcekitd_uid_t);
typedef void (*request_release_fn)(sourcekitd_object_t);
typedef sourcekitd_object_t (*request_dictionary_create_fn)(const sourcekitd_uid_t *, const sourcekitd_object_t *, size_t);
typedef void (*request_dictionary_set_value_fn)(sourcekitd_object_t, sourcekitd_uid_t, sourcekitd_object_t);
typedef void (*request_dictionary_set_string_fn)(sourcekitd_object_t, sourcekitd_uid_t, const char *);
typedef void (*request_dictionary_set_int64_fn)(sourcekitd_object_t, sourcekitd_uid_t, int64_t);
typedef void (*request_dictionary_set_uid_fn)(sourcekitd_object_t, sourcekitd_uid_t, sourcekitd_uid_t);
typedef sourcekitd_object_t (*request_array_create_fn)(const sourcekitd_object_t *, size_t);
typedef void (*request_array_set_string_fn)(sourcekitd_object_t, size_t, const char *);
typedef sourcekitd_response_t (*send_request_sync_fn)(sourcekitd_object_t);
typedef void (*response_dispose_fn)(sourcekitd_response_t);
typedef bool (*response_is_error_fn)(sourcekitd_response_t);
typedef const char *(*response_error_get_description_fn)(sourcekitd_response_t);
typedef sourcekitd_variant_t (*response_get_value_fn)(sourcekitd_response_t);
typedef int32_t (*variant_get_type_fn)(sourcekitd_variant_t);
typedef sourcekitd_variant_t (*variant_dictionary_get_value_fn)(sourcekitd_variant_t, sourcekitd_uid_t);
typedef const char *(*variant_dictionary_get_string_fn)(sourcekitd_variant_t, sourcekitd_uid_t);
typedef int64_t (*variant_dictionary_get_int64_fn)(sourcekitd_variant_t, sourcekitd_uid_t);
typedef size_t (*variant_array_get_count_fn)(sourcekitd_variant_t);
typedef sourcekitd_variant_t (*variant_array_get_value_fn)(sourcekitd_variant_t, size_t);
typedef const char *(*variant_string_get_ptr_fn)(sourcekitd_variant_t);
typedef int64_t (*variant_int64_get_value_fn)(sourcekitd_variant_t);
typedef sourcekitd_uid_t (*variant_uid_get_value_fn)(sourcekitd_variant_t);
typedef bool (*variant_dictionary_applier_f_t)(sourcekitd_uid_t, sourcekitd_variant_t, void *);
typedef bool (*variant_dictionary_apply_f_fn)(sourcekitd_variant_t, variant_dictionary_applier_f_t, void *);

static void *sHandle = NULL;
static const char *sLastError = NULL;

static initialize_fn sInitialize;
static uid_get_from_cstr_fn sUidGetFromCStr;
static uid_get_string_ptr_fn sUidGetStringPtr;
static request_release_fn sRequestRelease;
static request_dictionary_create_fn sRequestDictionaryCreate;
static request_dictionary_set_value_fn sRequestDictionarySetValue;
static request_dictionary_set_string_fn sRequestDictionarySetString;
static request_dictionary_set_int64_fn sRequestDictionarySetInt64;
static request_dictionary_set_uid_fn sRequestDictionarySetUid;
static request_array_create_fn sRequestArrayCreate;
static request_array_set_string_fn sRequestArraySetString;
static send_request_sync_fn sSendRequestSync;
static response_dispose_fn sResponseDispose;
static response_is_error_fn sResponseIsError;
static response_error_get_description_fn sResponseErrorGetDescription;
static response_get_value_fn sResponseGetValue;
static variant_get_type_fn sVariantGetType;
static variant_dictionary_get_value_fn sVariantDictionaryGetValue;
static variant_dictionary_get_string_fn sVariantDictionaryGetString;
static variant_dictionary_get_int64_fn sVariantDictionaryGetInt64;
static variant_array_get_count_fn sVariantArrayGetCount;
static variant_array_get_value_fn sVariantArrayGetValue;
static variant_string_get_ptr_fn sVariantStringGetPtr;
static variant_int64_get_value_fn sVariantInt64GetValue;
static variant_uid_get_value_fn sVariantUidGetValue;
static variant_dictionary_apply_f_fn sVariantDictionaryApplyF;

static void *resolve(const char *name, int *failed) {
    void *symbol = dlsym(sHandle, name);
    if (!symbol) {
        *failed = 1;
    }
    return symbol;
}

// `sourcekitd_shim_load` writes into process-wide static state (the resolved function pointers
// above) with no synchronization of its own -- fine for this project's real, intended usage ("one
// in-process session per analysis run", per docs/priority-3-phase-b-sourcekitd-client.md), but a
// real, empirically-hit data race (SIGSEGV, confirmed via two live `SourceKitDClient` tests
// crashing only when Swift Testing ran them in parallel, never individually) once more than one
// `SourceKitDClient` gets constructed concurrently -- exactly what a parallel test run does. Guard
// the whole load with a mutex, and make it idempotent (a second caller after a successful load is
// a fast no-op) rather than assuming single-caller usage holds in every context this code runs in.
static pthread_mutex_t sLoadMutex = PTHREAD_MUTEX_INITIALIZER;
static int sLoaded = 0;

int sourcekitd_shim_load(const char *dylibPath) {
    pthread_mutex_lock(&sLoadMutex);
    if (sLoaded) {
        pthread_mutex_unlock(&sLoadMutex);
        return 0;
    }

    sHandle = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL);
    if (!sHandle) {
        sLastError = dlerror();
        pthread_mutex_unlock(&sLoadMutex);
        return 1;
    }

    int failed = 0;
    sInitialize = (initialize_fn)resolve("sourcekitd_initialize", &failed);
    sUidGetFromCStr = (uid_get_from_cstr_fn)resolve("sourcekitd_uid_get_from_cstr", &failed);
    sUidGetStringPtr = (uid_get_string_ptr_fn)resolve("sourcekitd_uid_get_string_ptr", &failed);
    sRequestRelease = (request_release_fn)resolve("sourcekitd_request_release", &failed);
    sRequestDictionaryCreate = (request_dictionary_create_fn)resolve("sourcekitd_request_dictionary_create", &failed);
    sRequestDictionarySetValue = (request_dictionary_set_value_fn)resolve("sourcekitd_request_dictionary_set_value", &failed);
    sRequestDictionarySetString = (request_dictionary_set_string_fn)resolve("sourcekitd_request_dictionary_set_string", &failed);
    sRequestDictionarySetInt64 = (request_dictionary_set_int64_fn)resolve("sourcekitd_request_dictionary_set_int64", &failed);
    sRequestDictionarySetUid = (request_dictionary_set_uid_fn)resolve("sourcekitd_request_dictionary_set_uid", &failed);
    sRequestArrayCreate = (request_array_create_fn)resolve("sourcekitd_request_array_create", &failed);
    sRequestArraySetString = (request_array_set_string_fn)resolve("sourcekitd_request_array_set_string", &failed);
    sSendRequestSync = (send_request_sync_fn)resolve("sourcekitd_send_request_sync", &failed);
    sResponseDispose = (response_dispose_fn)resolve("sourcekitd_response_dispose", &failed);
    sResponseIsError = (response_is_error_fn)resolve("sourcekitd_response_is_error", &failed);
    sResponseErrorGetDescription = (response_error_get_description_fn)resolve("sourcekitd_response_error_get_description", &failed);
    sResponseGetValue = (response_get_value_fn)resolve("sourcekitd_response_get_value", &failed);
    sVariantGetType = (variant_get_type_fn)resolve("sourcekitd_variant_get_type", &failed);
    sVariantDictionaryGetValue = (variant_dictionary_get_value_fn)resolve("sourcekitd_variant_dictionary_get_value", &failed);
    sVariantDictionaryGetString = (variant_dictionary_get_string_fn)resolve("sourcekitd_variant_dictionary_get_string", &failed);
    sVariantDictionaryGetInt64 = (variant_dictionary_get_int64_fn)resolve("sourcekitd_variant_dictionary_get_int64", &failed);
    sVariantArrayGetCount = (variant_array_get_count_fn)resolve("sourcekitd_variant_array_get_count", &failed);
    sVariantArrayGetValue = (variant_array_get_value_fn)resolve("sourcekitd_variant_array_get_value", &failed);
    sVariantStringGetPtr = (variant_string_get_ptr_fn)resolve("sourcekitd_variant_string_get_ptr", &failed);
    sVariantInt64GetValue = (variant_int64_get_value_fn)resolve("sourcekitd_variant_int64_get_value", &failed);
    sVariantUidGetValue = (variant_uid_get_value_fn)resolve("sourcekitd_variant_uid_get_value", &failed);
    sVariantDictionaryApplyF = (variant_dictionary_apply_f_fn)resolve("sourcekitd_variant_dictionary_apply_f", &failed);

    if (failed) {
        sLastError = "one or more required sourcekitd symbols were not found";
        pthread_mutex_unlock(&sLoadMutex);
        return 1;
    }
    sLastError = NULL;
    sLoaded = 1;
    pthread_mutex_unlock(&sLoadMutex);
    return 0;
}

const char *sourcekitd_shim_last_error(void) {
    return sLastError;
}

void sourcekitd_shim_initialize(void) {
    sInitialize();
}

sourcekitd_uid_t sourcekitd_shim_uid_get_from_cstr(const char *string) {
    return sUidGetFromCStr(string);
}

const char *sourcekitd_shim_uid_get_string_ptr(sourcekitd_uid_t uid) {
    return sUidGetStringPtr(uid);
}

void sourcekitd_shim_request_release(sourcekitd_object_t object) {
    sRequestRelease(object);
}

sourcekitd_object_t sourcekitd_shim_request_dictionary_create(
    const sourcekitd_uid_t *keys, const sourcekitd_object_t *values, size_t count
) {
    return sRequestDictionaryCreate(keys, values, count);
}

void sourcekitd_shim_request_dictionary_set_value(sourcekitd_object_t dict, sourcekitd_uid_t key, sourcekitd_object_t value) {
    sRequestDictionarySetValue(dict, key, value);
}

void sourcekitd_shim_request_dictionary_set_string(sourcekitd_object_t dict, sourcekitd_uid_t key, const char *string) {
    sRequestDictionarySetString(dict, key, string);
}

void sourcekitd_shim_request_dictionary_set_int64(sourcekitd_object_t dict, sourcekitd_uid_t key, int64_t val) {
    sRequestDictionarySetInt64(dict, key, val);
}

void sourcekitd_shim_request_dictionary_set_uid(sourcekitd_object_t dict, sourcekitd_uid_t key, sourcekitd_uid_t uid) {
    sRequestDictionarySetUid(dict, key, uid);
}

sourcekitd_object_t sourcekitd_shim_request_array_create(const sourcekitd_object_t *objects, size_t count) {
    return sRequestArrayCreate(objects, count);
}

void sourcekitd_shim_request_array_append_string(sourcekitd_object_t array, const char *string) {
    sRequestArraySetString(array, SOURCEKITD_ARRAY_APPEND, string);
}

sourcekitd_response_t sourcekitd_shim_send_request_sync(sourcekitd_object_t req) {
    return sSendRequestSync(req);
}

void sourcekitd_shim_response_dispose(sourcekitd_response_t obj) {
    sResponseDispose(obj);
}

bool sourcekitd_shim_response_is_error(sourcekitd_response_t obj) {
    return sResponseIsError(obj);
}

const char *sourcekitd_shim_response_error_get_description(sourcekitd_response_t err) {
    return sResponseErrorGetDescription(err);
}

sourcekitd_variant_t sourcekitd_shim_response_get_value(sourcekitd_response_t resp) {
    return sResponseGetValue(resp);
}

int32_t sourcekitd_shim_variant_get_type(sourcekitd_variant_t obj) {
    return sVariantGetType(obj);
}

sourcekitd_variant_t sourcekitd_shim_variant_dictionary_get_value(sourcekitd_variant_t dict, sourcekitd_uid_t key) {
    return sVariantDictionaryGetValue(dict, key);
}

const char *sourcekitd_shim_variant_dictionary_get_string(sourcekitd_variant_t dict, sourcekitd_uid_t key) {
    return sVariantDictionaryGetString(dict, key);
}

int64_t sourcekitd_shim_variant_dictionary_get_int64(sourcekitd_variant_t dict, sourcekitd_uid_t key) {
    return sVariantDictionaryGetInt64(dict, key);
}

size_t sourcekitd_shim_variant_array_get_count(sourcekitd_variant_t array) {
    return sVariantArrayGetCount(array);
}

sourcekitd_variant_t sourcekitd_shim_variant_array_get_value(sourcekitd_variant_t array, size_t index) {
    return sVariantArrayGetValue(array, index);
}

const char *sourcekitd_shim_variant_string_get_ptr(sourcekitd_variant_t obj) {
    return sVariantStringGetPtr(obj);
}

sourcekitd_uid_t sourcekitd_shim_variant_uid_get_value(sourcekitd_variant_t obj) {
    return sVariantUidGetValue(obj);
}

// `SOURCEKITD_VARIANT_TYPE_*` from sourcekitd.h, copied verbatim (not exposed via CSourceKitD.h --
// diagnostic-only code, not part of the project's real production ABI surface).
enum {
    kVariantTypeNull = 0,
    kVariantTypeDictionary = 1,
    kVariantTypeArray = 2,
    kVariantTypeInt64 = 3,
    kVariantTypeString = 4,
    kVariantTypeUID = 5,
    kVariantTypeBool = 6,
    kVariantTypeDouble = 7,
    kVariantTypeData = 8
};

static char sDumpBuffer[65536];
static size_t sDumpOffset;

static void dumpAppend(const char *fmt, ...) {
    if (sDumpOffset >= sizeof(sDumpBuffer) - 1) {
        return;
    }
    va_list args;
    va_start(args, fmt);
    int written = vsnprintf(sDumpBuffer + sDumpOffset, sizeof(sDumpBuffer) - sDumpOffset, fmt, args);
    va_end(args);
    if (written > 0) {
        sDumpOffset += (size_t)written;
    }
}

static void dumpIndent(int depth) {
    for (int i = 0; i < depth; i++) {
        dumpAppend("  ");
    }
}

static void dumpVariant(sourcekitd_variant_t value, int depth);

static bool dumpDictionaryEntry(sourcekitd_uid_t key, sourcekitd_variant_t value, void *context) {
    int depth = *(int *)context;
    const char *keyName = sUidGetStringPtr(key);
    dumpIndent(depth);
    dumpAppend("%s: ", keyName ? keyName : "<unnamed key>");
    dumpVariant(value, depth);
    return true;
}

static void dumpVariant(sourcekitd_variant_t value, int depth) {
    int32_t type = sVariantGetType(value);
    switch (type) {
        case kVariantTypeDictionary: {
            dumpAppend("{\n");
            int childDepth = depth + 1;
            sVariantDictionaryApplyF(value, dumpDictionaryEntry, &childDepth);
            dumpIndent(depth);
            dumpAppend("}\n");
            break;
        }
        case kVariantTypeArray: {
            dumpAppend("[\n");
            size_t count = sVariantArrayGetCount(value);
            for (size_t i = 0; i < count; i++) {
                dumpIndent(depth + 1);
                dumpAppend("- ");
                dumpVariant(sVariantArrayGetValue(value, i), depth + 1);
            }
            dumpIndent(depth);
            dumpAppend("]\n");
            break;
        }
        case kVariantTypeInt64:
            dumpAppend("%lld (int64)\n", (long long)sVariantInt64GetValue(value));
            break;
        case kVariantTypeString: {
            const char *string = sVariantStringGetPtr(value);
            dumpAppend("\"%s\" (string)\n", string ? string : "");
            break;
        }
        case kVariantTypeBool:
            dumpAppend("<bool>\n");
            break;
        case kVariantTypeDouble:
            dumpAppend("<double>\n");
            break;
        case kVariantTypeUID: {
            sourcekitd_uid_t uid = sVariantUidGetValue(value);
            const char *uidName = uid ? sUidGetStringPtr(uid) : NULL;
            dumpAppend("%s (uid)\n", uidName ? uidName : "<unnamed uid>");
            break;
        }
        case kVariantTypeNull:
            dumpAppend("<null>\n");
            break;
        default:
            dumpAppend("<unknown type %d>\n", type);
            break;
    }
}

const char *sourcekitd_shim_dump_variant(sourcekitd_variant_t variant) {
    sDumpOffset = 0;
    sDumpBuffer[0] = '\0';
    dumpVariant(variant, 0);
    return sDumpBuffer;
}
