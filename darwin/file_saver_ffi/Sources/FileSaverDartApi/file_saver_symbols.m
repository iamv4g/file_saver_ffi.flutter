/*
 * Gives Dart the addresses of the functions of file_saver_ffi.h.
 *
 * Dart can't look them up by name (`DynamicLibrary.process().lookup`) in an
 * app that links the plugin statically, as Swift Package Manager and
 * CocoaPods with static linkage do: archiving it with STRIP_STYLE = all,
 * Xcode's default for apps, strips their names. Dart finds this class through
 * the Objective-C runtime instead, which keeps class names.
 */

#import <Foundation/Foundation.h>
#include <string.h>

// The header is only in the Swift target's folder, which defines its
// functions (`@_cdecl`).
#include "../file_saver_ffi/FFI/file_saver_ffi.h"

typedef struct {
    const char *name;
    void *address;
} FileSaverSymbol;

#define FILE_SAVER_SYMBOL(function) {#function, (void *)&function},
static const FileSaverSymbol kSymbols[] = {FILE_SAVER_FUNCTIONS(FILE_SAVER_SYMBOL)};
#undef FILE_SAVER_SYMBOL

@interface FileSaverFFISymbols : NSObject
@end

@implementation FileSaverFFISymbols

/// The address of the function of file_saver_ffi.h named [name], or NULL.
+ (void *)addressOf:(const char *)name {
    if (name == NULL) {
        return NULL;
    }
    for (size_t i = 0; i < sizeof(kSymbols) / sizeof(kSymbols[0]); i++) {
        if (strcmp(kSymbols[i].name, name) == 0) {
            return kSymbols[i].address;
        }
    }
    return NULL;
}

@end
