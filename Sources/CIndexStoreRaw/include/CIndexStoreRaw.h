// Minimal C shim over `libIndexStore`'s raw C ABI (types/signatures copied verbatim from the
// real, upstream `indexstore.h`: `swiftlang/llvm-project`'s `clang/include/indexstore/indexstore.h`,
// branch `next`, `INDEXSTORE_VERSION_MINOR 16` -- confirmed present on `stable/20240723`,
// `swift/release/6.1`, `swift/release/6.2`, `apple/main`).
//
// Exists for the same reason `CSourceKitD` exists (`dlopen`'d at runtime, never linked at build
// time, so this project never hard-depends on one specific toolchain's dylib being present at
// link time) -- but *not* for the same ABI reason: `indexstore_string_ref_t` is a plain
// `{const char*, size_t}` struct (16 bytes), well within the direct-register-return threshold, so
// unlike `sourcekitd_variant_t` (24 bytes, needs indirect passing) this API's own signatures are
// already fully `@convention(c)`-representable in Swift. Every `_apply_f` enumerator here takes an
// explicit `void *context` first argument (the C convention this header itself already uses), so
// no struct-marshaling gymnastics are needed here either -- this shim's only job is `dlopen`+
// `dlsym`+forward, one function per real `indexstore_*` symbol this project actually calls (see
// docs/task-raw-indexstore-spike.md for the full needs catalog this mirrors).
//
// Deliberately *not* used: `indexstore_store_start_unit_event_listening`/`OnUnitsChange` (the
// async, event-driven subscription API `IndexStoreDB` itself is built on -- see
// docs/task-indexstore-declaration-completeness.md, issue #51) -- this shim only exposes the
// plain synchronous, one-shot read path: `indexstore_store_create` has no "wait until done"
// concept at all, confirmed directly against the real header.
#ifndef SWIFT_ISOLATION_MAP_CINDEXSTORERAW_H
#define SWIFT_ISOLATION_MAP_CINDEXSTORERAW_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    const char *data;
    size_t length;
} indexstore_string_ref_t;

typedef void *indexstore_error_t;
typedef void *indexstore_t;
typedef void *indexstore_unit_reader_t;
typedef void *indexstore_unit_dependency_t;
typedef void *indexstore_record_reader_t;
typedef void *indexstore_occurrence_t;
typedef void *indexstore_symbol_t;
typedef void *indexstore_symbol_relation_t;

typedef uint64_t indexstore_symbol_role_t;

// `INDEXSTORE_SYMBOL_ROLE_*` bit values, copied verbatim from the real header -- only the 7 this
// project actually needs (matching `IndexStoreQuerying`'s own contract exactly; see
// docs/task-raw-indexstore-spike.md's needs catalog). `static const`, not `#define`: a
// cast-to-typedef macro imports into Swift as "unavailable: structure not supported" --
// confirmed empirically -- while a plain typed constant imports cleanly.
static const indexstore_symbol_role_t INDEXSTORE_SYMBOL_ROLE_DEFINITION = (indexstore_symbol_role_t)1 << 1;
static const indexstore_symbol_role_t INDEXSTORE_SYMBOL_ROLE_CALL = (indexstore_symbol_role_t)1 << 5;
static const indexstore_symbol_role_t INDEXSTORE_SYMBOL_ROLE_REL_BASEOF = (indexstore_symbol_role_t)1 << 10;
static const indexstore_symbol_role_t INDEXSTORE_SYMBOL_ROLE_REL_CALLEDBY = (indexstore_symbol_role_t)1 << 13;
static const indexstore_symbol_role_t INDEXSTORE_SYMBOL_ROLE_REL_EXTENDEDBY = (indexstore_symbol_role_t)1 << 14;
static const indexstore_symbol_role_t INDEXSTORE_SYMBOL_ROLE_REL_ACCESSOROF = (indexstore_symbol_role_t)1 << 15;
static const indexstore_symbol_role_t INDEXSTORE_SYMBOL_ROLE_REL_CHILDOF = (indexstore_symbol_role_t)1 << 9;

typedef enum {
    INDEXSTORE_UNIT_DEPENDENCY_UNIT = 1,
    INDEXSTORE_UNIT_DEPENDENCY_RECORD = 2,
    INDEXSTORE_UNIT_DEPENDENCY_FILE = 3,
} indexstore_unit_dependency_kind_t;

// Resolves `dylibPath` via `dlopen` and every symbol this shim needs via `dlsym`. Returns 0 on
// success; nonzero (with a message available via `indexstore_shim_last_error`) on failure. Must
// be called exactly once, before any other `indexstore_shim_*` function.
int indexstore_shim_load(const char *dylibPath);

// The `dlopen`/`dlsym` failure message from the most recent failed `indexstore_shim_load` call,
// or NULL if the most recent call succeeded.
const char *indexstore_shim_last_error(void);

const char *indexstore_shim_error_get_description(indexstore_error_t error);
void indexstore_shim_error_dispose(indexstore_error_t error);

indexstore_t indexstore_shim_store_create(const char *store_path, indexstore_error_t *error);
void indexstore_shim_store_dispose(indexstore_t store);

typedef bool (*indexstore_shim_unit_name_applier_t)(void *context, indexstore_string_ref_t unit_name);
bool indexstore_shim_store_units_apply_f(indexstore_t store, unsigned sorted, void *context, indexstore_shim_unit_name_applier_t applier);

indexstore_unit_reader_t indexstore_shim_unit_reader_create(indexstore_t store, const char *unit_name, indexstore_error_t *error);
void indexstore_shim_unit_reader_dispose(indexstore_unit_reader_t unit_reader);
indexstore_string_ref_t indexstore_shim_unit_reader_get_main_file(indexstore_unit_reader_t unit_reader);
indexstore_string_ref_t indexstore_shim_unit_reader_get_module_name(indexstore_unit_reader_t unit_reader);
bool indexstore_shim_unit_reader_is_system_unit(indexstore_unit_reader_t unit_reader);

typedef bool (*indexstore_shim_unit_dependency_applier_t)(void *context, indexstore_unit_dependency_t dependency);
bool indexstore_shim_unit_reader_dependencies_apply_f(indexstore_unit_reader_t unit_reader, void *context, indexstore_shim_unit_dependency_applier_t applier);

indexstore_unit_dependency_kind_t indexstore_shim_unit_dependency_get_kind(indexstore_unit_dependency_t dependency);
indexstore_string_ref_t indexstore_shim_unit_dependency_get_filepath(indexstore_unit_dependency_t dependency);
indexstore_string_ref_t indexstore_shim_unit_dependency_get_name(indexstore_unit_dependency_t dependency);

indexstore_record_reader_t indexstore_shim_record_reader_create(indexstore_t store, const char *record_name, indexstore_error_t *error);
void indexstore_shim_record_reader_dispose(indexstore_record_reader_t record_reader);

typedef bool (*indexstore_shim_occurrence_applier_t)(void *context, indexstore_occurrence_t occurrence);
bool indexstore_shim_record_reader_occurrences_apply_f(indexstore_record_reader_t record_reader, void *context, indexstore_shim_occurrence_applier_t applier);

indexstore_symbol_t indexstore_shim_occurrence_get_symbol(indexstore_occurrence_t occurrence);
indexstore_symbol_role_t indexstore_shim_occurrence_get_roles(indexstore_occurrence_t occurrence);
void indexstore_shim_occurrence_get_line_col(indexstore_occurrence_t occurrence, unsigned *line, unsigned *column);

typedef bool (*indexstore_shim_relation_applier_t)(void *context, indexstore_symbol_relation_t relation);
bool indexstore_shim_occurrence_relations_apply_f(indexstore_occurrence_t occurrence, void *context, indexstore_shim_relation_applier_t applier);

indexstore_symbol_role_t indexstore_shim_symbol_relation_get_roles(indexstore_symbol_relation_t relation);
indexstore_symbol_t indexstore_shim_symbol_relation_get_symbol(indexstore_symbol_relation_t relation);

indexstore_string_ref_t indexstore_shim_symbol_get_usr(indexstore_symbol_t symbol);
indexstore_string_ref_t indexstore_shim_symbol_get_name(indexstore_symbol_t symbol);

#endif
