/*
 * Dart API Dynamic Linking Implementation
 *
 * Provides FileSaver_PostCObject_DL for sending messages to Dart via NativePort.
 * Based on Dart SDK dart_api_dl.c
 */

#include "file_saver_dart_api.h"
#include <string.h>

// DART_API_DL_MAJOR_VERSION of the Dart SDK (include/dart_version.h). A VM
// with another major version lays out Dart_CObject differently.
#define FILE_SAVER_DART_API_DL_MAJOR_VERSION 2

// Function pointer storage
static Dart_PostCObject_Type FileSaver_PostCObject_DL_ = NULL;

// DartApi struct layout from Dart SDK
// The data passed to FileSaver_InitializeApiDL contains function entries
typedef struct {
    const char* name;
    void* function;
} DartApiEntry;

typedef struct {
    int major;
    int minor;
    DartApiEntry* functions;
} DartApi;

intptr_t FileSaver_InitializeApiDL(void* data) {
    if (data == NULL) {
        return -1;
    }

    DartApi* api = (DartApi*)data;
    if (api->major != FILE_SAVER_DART_API_DL_MAJOR_VERSION) {
        return -1;
    }

    // Find Dart_PostCObject in the function table
    // Note: Dart SDK exposes "Dart_PostCObject"; we wrap it as FileSaver_PostCObject_DL
    Dart_PostCObject_Type post = NULL;
    for (DartApiEntry* entry = api->functions; entry->name != NULL; entry++) {
        if (strcmp(entry->name, "Dart_PostCObject") == 0) {
            post = (Dart_PostCObject_Type)entry->function;
            break;
        }
    }
    if (post == NULL) {
        return -1;
    }

    FileSaver_PostCObject_DL_ = post;
    return 0;
}

bool FileSaver_PostCObject_DL(Dart_Port port_id, Dart_CObject* message) {
    if (FileSaver_PostCObject_DL_ == NULL) {
        return false;
    }
    return FileSaver_PostCObject_DL_(port_id, message);
}
