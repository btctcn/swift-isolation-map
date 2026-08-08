#include "CIndexStoreRaw.h"
#include <dlfcn.h>
#include <pthread.h>

typedef indexstore_t (*store_create_fn)(const char *, indexstore_error_t *);
typedef void (*store_dispose_fn)(indexstore_t);
typedef bool (*store_units_apply_f_fn)(indexstore_t, unsigned, void *, indexstore_shim_unit_name_applier_t);
typedef indexstore_unit_reader_t (*unit_reader_create_fn)(indexstore_t, const char *, indexstore_error_t *);
typedef void (*unit_reader_dispose_fn)(indexstore_unit_reader_t);
typedef indexstore_string_ref_t (*unit_reader_get_main_file_fn)(indexstore_unit_reader_t);
typedef bool (*unit_reader_dependencies_apply_f_fn)(indexstore_unit_reader_t, void *, indexstore_shim_unit_dependency_applier_t);
typedef indexstore_unit_dependency_kind_t (*unit_dependency_get_kind_fn)(indexstore_unit_dependency_t);
typedef indexstore_string_ref_t (*unit_dependency_get_filepath_fn)(indexstore_unit_dependency_t);
typedef indexstore_string_ref_t (*unit_dependency_get_name_fn)(indexstore_unit_dependency_t);
typedef indexstore_record_reader_t (*record_reader_create_fn)(indexstore_t, const char *, indexstore_error_t *);
typedef void (*record_reader_dispose_fn)(indexstore_record_reader_t);
typedef bool (*record_reader_occurrences_apply_f_fn)(indexstore_record_reader_t, void *, indexstore_shim_occurrence_applier_t);
typedef indexstore_symbol_t (*occurrence_get_symbol_fn)(indexstore_occurrence_t);
typedef indexstore_symbol_role_t (*occurrence_get_roles_fn)(indexstore_occurrence_t);
typedef void (*occurrence_get_line_col_fn)(indexstore_occurrence_t, unsigned *, unsigned *);
typedef bool (*occurrence_relations_apply_f_fn)(indexstore_occurrence_t, void *, indexstore_shim_relation_applier_t);
typedef indexstore_symbol_role_t (*symbol_relation_get_roles_fn)(indexstore_symbol_relation_t);
typedef indexstore_symbol_t (*symbol_relation_get_symbol_fn)(indexstore_symbol_relation_t);
typedef indexstore_string_ref_t (*symbol_get_usr_fn)(indexstore_symbol_t);
typedef indexstore_string_ref_t (*symbol_get_name_fn)(indexstore_symbol_t);
typedef const char *(*error_get_description_fn)(indexstore_error_t);
typedef void (*error_dispose_fn)(indexstore_error_t);

static void *sHandle = NULL;
static const char *sLastError = NULL;

static store_create_fn sStoreCreate;
static store_dispose_fn sStoreDispose;
static store_units_apply_f_fn sStoreUnitsApplyF;
static unit_reader_create_fn sUnitReaderCreate;
static unit_reader_dispose_fn sUnitReaderDispose;
static unit_reader_get_main_file_fn sUnitReaderGetMainFile;
static unit_reader_dependencies_apply_f_fn sUnitReaderDependenciesApplyF;
static unit_dependency_get_kind_fn sUnitDependencyGetKind;
static unit_dependency_get_filepath_fn sUnitDependencyGetFilepath;
static unit_dependency_get_name_fn sUnitDependencyGetName;
static record_reader_create_fn sRecordReaderCreate;
static record_reader_dispose_fn sRecordReaderDispose;
static record_reader_occurrences_apply_f_fn sRecordReaderOccurrencesApplyF;
static occurrence_get_symbol_fn sOccurrenceGetSymbol;
static occurrence_get_roles_fn sOccurrenceGetRoles;
static occurrence_get_line_col_fn sOccurrenceGetLineCol;
static occurrence_relations_apply_f_fn sOccurrenceRelationsApplyF;
static symbol_relation_get_roles_fn sSymbolRelationGetRoles;
static symbol_relation_get_symbol_fn sSymbolRelationGetSymbol;
static symbol_get_usr_fn sSymbolGetUsr;
static symbol_get_name_fn sSymbolGetName;
static error_get_description_fn sErrorGetDescription;
static error_dispose_fn sErrorDispose;

static void *resolve(const char *name, int *failed) {
    void *symbol = dlsym(sHandle, name);
    if (!symbol) {
        *failed = 1;
    }
    return symbol;
}

// Same idempotent, mutex-guarded load pattern as `CSourceKitD`'s own shim (see its own comment for
// why: a real, empirically-hit data race across concurrently-constructed clients in this project's
// own test suite).
static pthread_mutex_t sLoadMutex = PTHREAD_MUTEX_INITIALIZER;
static int sLoaded = 0;

int indexstore_shim_load(const char *dylibPath) {
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
    sStoreCreate = (store_create_fn)resolve("indexstore_store_create", &failed);
    sStoreDispose = (store_dispose_fn)resolve("indexstore_store_dispose", &failed);
    sStoreUnitsApplyF = (store_units_apply_f_fn)resolve("indexstore_store_units_apply_f", &failed);
    sUnitReaderCreate = (unit_reader_create_fn)resolve("indexstore_unit_reader_create", &failed);
    sUnitReaderDispose = (unit_reader_dispose_fn)resolve("indexstore_unit_reader_dispose", &failed);
    sUnitReaderGetMainFile = (unit_reader_get_main_file_fn)resolve("indexstore_unit_reader_get_main_file", &failed);
    sUnitReaderDependenciesApplyF = (unit_reader_dependencies_apply_f_fn)resolve("indexstore_unit_reader_dependencies_apply_f", &failed);
    sUnitDependencyGetKind = (unit_dependency_get_kind_fn)resolve("indexstore_unit_dependency_get_kind", &failed);
    sUnitDependencyGetFilepath = (unit_dependency_get_filepath_fn)resolve("indexstore_unit_dependency_get_filepath", &failed);
    sUnitDependencyGetName = (unit_dependency_get_name_fn)resolve("indexstore_unit_dependency_get_name", &failed);
    sRecordReaderCreate = (record_reader_create_fn)resolve("indexstore_record_reader_create", &failed);
    sRecordReaderDispose = (record_reader_dispose_fn)resolve("indexstore_record_reader_dispose", &failed);
    sRecordReaderOccurrencesApplyF = (record_reader_occurrences_apply_f_fn)resolve("indexstore_record_reader_occurrences_apply_f", &failed);
    sOccurrenceGetSymbol = (occurrence_get_symbol_fn)resolve("indexstore_occurrence_get_symbol", &failed);
    sOccurrenceGetRoles = (occurrence_get_roles_fn)resolve("indexstore_occurrence_get_roles", &failed);
    sOccurrenceGetLineCol = (occurrence_get_line_col_fn)resolve("indexstore_occurrence_get_line_col", &failed);
    sOccurrenceRelationsApplyF = (occurrence_relations_apply_f_fn)resolve("indexstore_occurrence_relations_apply_f", &failed);
    sSymbolRelationGetRoles = (symbol_relation_get_roles_fn)resolve("indexstore_symbol_relation_get_roles", &failed);
    sSymbolRelationGetSymbol = (symbol_relation_get_symbol_fn)resolve("indexstore_symbol_relation_get_symbol", &failed);
    sSymbolGetUsr = (symbol_get_usr_fn)resolve("indexstore_symbol_get_usr", &failed);
    sSymbolGetName = (symbol_get_name_fn)resolve("indexstore_symbol_get_name", &failed);
    sErrorGetDescription = (error_get_description_fn)resolve("indexstore_error_get_description", &failed);
    sErrorDispose = (error_dispose_fn)resolve("indexstore_error_dispose", &failed);

    if (failed) {
        sLastError = "one or more required libIndexStore symbols were not found";
        pthread_mutex_unlock(&sLoadMutex);
        return 1;
    }
    sLastError = NULL;
    sLoaded = 1;
    pthread_mutex_unlock(&sLoadMutex);
    return 0;
}

const char *indexstore_shim_last_error(void) {
    return sLastError;
}

const char *indexstore_shim_error_get_description(indexstore_error_t error) {
    return sErrorGetDescription(error);
}

void indexstore_shim_error_dispose(indexstore_error_t error) {
    sErrorDispose(error);
}

indexstore_t indexstore_shim_store_create(const char *store_path, indexstore_error_t *error) {
    return sStoreCreate(store_path, error);
}

void indexstore_shim_store_dispose(indexstore_t store) {
    sStoreDispose(store);
}

bool indexstore_shim_store_units_apply_f(indexstore_t store, unsigned sorted, void *context, indexstore_shim_unit_name_applier_t applier) {
    return sStoreUnitsApplyF(store, sorted, context, applier);
}

indexstore_unit_reader_t indexstore_shim_unit_reader_create(indexstore_t store, const char *unit_name, indexstore_error_t *error) {
    return sUnitReaderCreate(store, unit_name, error);
}

void indexstore_shim_unit_reader_dispose(indexstore_unit_reader_t unit_reader) {
    sUnitReaderDispose(unit_reader);
}

indexstore_string_ref_t indexstore_shim_unit_reader_get_main_file(indexstore_unit_reader_t unit_reader) {
    return sUnitReaderGetMainFile(unit_reader);
}

bool indexstore_shim_unit_reader_dependencies_apply_f(indexstore_unit_reader_t unit_reader, void *context, indexstore_shim_unit_dependency_applier_t applier) {
    return sUnitReaderDependenciesApplyF(unit_reader, context, applier);
}

indexstore_unit_dependency_kind_t indexstore_shim_unit_dependency_get_kind(indexstore_unit_dependency_t dependency) {
    return sUnitDependencyGetKind(dependency);
}

indexstore_string_ref_t indexstore_shim_unit_dependency_get_filepath(indexstore_unit_dependency_t dependency) {
    return sUnitDependencyGetFilepath(dependency);
}

indexstore_string_ref_t indexstore_shim_unit_dependency_get_name(indexstore_unit_dependency_t dependency) {
    return sUnitDependencyGetName(dependency);
}

indexstore_record_reader_t indexstore_shim_record_reader_create(indexstore_t store, const char *record_name, indexstore_error_t *error) {
    return sRecordReaderCreate(store, record_name, error);
}

void indexstore_shim_record_reader_dispose(indexstore_record_reader_t record_reader) {
    sRecordReaderDispose(record_reader);
}

bool indexstore_shim_record_reader_occurrences_apply_f(indexstore_record_reader_t record_reader, void *context, indexstore_shim_occurrence_applier_t applier) {
    return sRecordReaderOccurrencesApplyF(record_reader, context, applier);
}

indexstore_symbol_t indexstore_shim_occurrence_get_symbol(indexstore_occurrence_t occurrence) {
    return sOccurrenceGetSymbol(occurrence);
}

indexstore_symbol_role_t indexstore_shim_occurrence_get_roles(indexstore_occurrence_t occurrence) {
    return sOccurrenceGetRoles(occurrence);
}

void indexstore_shim_occurrence_get_line_col(indexstore_occurrence_t occurrence, unsigned *line, unsigned *column) {
    sOccurrenceGetLineCol(occurrence, line, column);
}

bool indexstore_shim_occurrence_relations_apply_f(indexstore_occurrence_t occurrence, void *context, indexstore_shim_relation_applier_t applier) {
    return sOccurrenceRelationsApplyF(occurrence, context, applier);
}

indexstore_symbol_role_t indexstore_shim_symbol_relation_get_roles(indexstore_symbol_relation_t relation) {
    return sSymbolRelationGetRoles(relation);
}

indexstore_symbol_t indexstore_shim_symbol_relation_get_symbol(indexstore_symbol_relation_t relation) {
    return sSymbolRelationGetSymbol(relation);
}

indexstore_string_ref_t indexstore_shim_symbol_get_usr(indexstore_symbol_t symbol) {
    return sSymbolGetUsr(symbol);
}

indexstore_string_ref_t indexstore_shim_symbol_get_name(indexstore_symbol_t symbol) {
    return sSymbolGetName(symbol);
}
