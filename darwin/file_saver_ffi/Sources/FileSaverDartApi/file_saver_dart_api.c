/*
 * Dart API Dynamic Linking Implementation
 *
 * Provides FileSaver_PostCObject_DL for sending messages to Dart via NativePort.
 * Based on Dart SDK dart_api_dl.c
 */

#include "file_saver_dart_api.h"
#include <string.h>

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

    // Find Dart_PostCObject in the function table
    // Note: Dart SDK exposes "Dart_PostCObject"; we wrap it as FileSaver_PostCObject_DL
    DartApiEntry* entry = api->functions;
    while (entry->name != NULL) {
        if (strcmp(entry->name, "Dart_PostCObject") == 0) {
            FileSaver_PostCObject_DL_ = (Dart_PostCObject_Type)entry->function;
            break;
        }
        entry++;
    }

    return FileSaver_PostCObject_DL_ != NULL ? 0 : -1;
}

bool FileSaver_PostCObject_DL(Dart_Port port_id, Dart_CObject* message) {
    if (FileSaver_PostCObject_DL_ == NULL) {
        return false;
    }
    return FileSaver_PostCObject_DL_(port_id, message);
}
