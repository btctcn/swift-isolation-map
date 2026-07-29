import CSourceKitD
import Foundation

// MARK: - Swift-side type aliases
//
// `sourcekitd_variant_t` (a 24-byte-by-value struct) and every function that passes/returns it
// are declared in the `CSourceKitD` C target, not here -- Swift's own `@convention(c)` cannot
// express the indirect-struct-passing ABI a type that size requires (confirmed empirically: "not
// representable in Objective-C" trying to declare it directly in pure Swift). `CSourceKitD`'s
// real C declarations get bridged correctly by Swift's ClangImporter instead, the same mechanism
// that makes `CGPoint`/`CGRect` work.

public typealias SourceKitDObject = UnsafeMutableRawPointer
public typealias SourceKitDResponse = UnsafeMutableRawPointer
public typealias SourceKitDUID = OpaquePointer
public typealias SourceKitDVariant = sourcekitd_variant_t

enum SourceKitDVariantType: Int32 {
    case null = 0
    case dictionary = 1
    case array = 2
    case int64 = 3
    case string = 4
    case uid = 5
    case bool = 6
    case double = 7
    case data = 8
}

public enum RawSourceKitDError: Error, Equatable {
    case dlopenFailed(path: String, reason: String)
}

/// Thin Swift wrapper over the `CSourceKitD` C shim -- one `dlopen`/`dlsym` resolution per
/// process (`sourcekitd_shim_load`), then ordinary (ABI-safe, ClangImporter-bridged) C calls for
/// everything else.
final class RawSourceKitD: @unchecked Sendable {
    init(dylibPath: String) throws {
        let result = dylibPath.withCString { sourcekitd_shim_load($0) }
        guard result == 0 else {
            let reason = sourcekitd_shim_last_error().map { String(cString: $0) } ?? "unknown dlopen/dlsym failure"
            throw RawSourceKitDError.dlopenFailed(path: dylibPath, reason: reason)
        }
    }

    func initialize() {
        sourcekitd_shim_initialize()
    }

    func uidGetFromCStr(_ string: String) -> SourceKitDUID? {
        string.withCString { sourcekitd_shim_uid_get_from_cstr($0) }
    }

    func uidGetStringPtr(_ uid: SourceKitDUID?) -> String? {
        sourcekitd_shim_uid_get_string_ptr(uid).map { String(cString: $0) }
    }

    func requestRelease(_ object: SourceKitDObject?) {
        sourcekitd_shim_request_release(object)
    }

    func requestDictionaryCreate() -> SourceKitDObject? {
        sourcekitd_shim_request_dictionary_create(nil, nil, 0)
    }

    func requestDictionarySetValue(_ dict: SourceKitDObject?, _ key: SourceKitDUID?, _ value: SourceKitDObject?) {
        sourcekitd_shim_request_dictionary_set_value(dict, key, value)
    }

    func requestDictionarySetString(_ dict: SourceKitDObject?, _ key: SourceKitDUID?, _ string: String) {
        string.withCString { sourcekitd_shim_request_dictionary_set_string(dict, key, $0) }
    }

    func requestDictionarySetInt64(_ dict: SourceKitDObject?, _ key: SourceKitDUID?, _ value: Int64) {
        sourcekitd_shim_request_dictionary_set_int64(dict, key, value)
    }

    func requestDictionarySetUID(_ dict: SourceKitDObject?, _ key: SourceKitDUID?, _ uid: SourceKitDUID?) {
        sourcekitd_shim_request_dictionary_set_uid(dict, key, uid)
    }

    func requestArrayCreate() -> SourceKitDObject? {
        sourcekitd_shim_request_array_create(nil, 0)
    }

    /// Always appends -- no index parameter exists at all, so no call site can pass the wrong
    /// one (the sequential-index crash this project's research spike hit and fixed).
    func requestArrayAppendString(_ array: SourceKitDObject?, _ string: String) {
        string.withCString { sourcekitd_shim_request_array_append_string(array, $0) }
    }

    func sendRequestSync(_ request: SourceKitDObject?) -> SourceKitDResponse? {
        sourcekitd_shim_send_request_sync(request)
    }

    func responseDispose(_ response: SourceKitDResponse?) {
        sourcekitd_shim_response_dispose(response)
    }

    func responseIsError(_ response: SourceKitDResponse?) -> Bool {
        sourcekitd_shim_response_is_error(response)
    }

    func responseErrorGetDescription(_ response: SourceKitDResponse?) -> String? {
        sourcekitd_shim_response_error_get_description(response).map { String(cString: $0) }
    }

    func responseGetValue(_ response: SourceKitDResponse?) -> SourceKitDVariant {
        sourcekitd_shim_response_get_value(response)
    }

    func variantGetType(_ variant: SourceKitDVariant) -> Int32 {
        sourcekitd_shim_variant_get_type(variant)
    }

    func variantDictionaryGetValue(_ variant: SourceKitDVariant, _ key: SourceKitDUID?) -> SourceKitDVariant {
        sourcekitd_shim_variant_dictionary_get_value(variant, key)
    }

    func variantDictionaryGetString(_ variant: SourceKitDVariant, _ key: SourceKitDUID?) -> String? {
        sourcekitd_shim_variant_dictionary_get_string(variant, key).map { String(cString: $0) }
    }

    func variantDictionaryGetInt64(_ variant: SourceKitDVariant, _ key: SourceKitDUID?) -> Int64 {
        sourcekitd_shim_variant_dictionary_get_int64(variant, key)
    }

    func variantUidGetValue(_ variant: SourceKitDVariant) -> SourceKitDUID? {
        sourcekitd_shim_variant_uid_get_value(variant)
    }

    func variantArrayGetCount(_ variant: SourceKitDVariant) -> Int {
        sourcekitd_shim_variant_array_get_count(variant)
    }

    func variantArrayGetValue(_ variant: SourceKitDVariant, _ index: Int) -> SourceKitDVariant {
        sourcekitd_shim_variant_array_get_value(variant, index)
    }

    /// Diagnostic-only: a full, literal recursive dump of a response variant's shape (every key,
    /// nesting, and value type) via `sourcekitd_variant_dictionary_apply_f` -- for pinning down a
    /// not-yet-understood response shape empirically, not for production parsing.
    func dumpVariant(_ variant: SourceKitDVariant) -> String {
        String(cString: sourcekitd_shim_dump_variant(variant))
    }
}
