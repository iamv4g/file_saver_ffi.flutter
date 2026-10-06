/*
 * Dart API Dynamic Linking Header
 *
 * This header provides the necessary types and function declarations
 * for sending messages to Dart via NativePort (FileSaver_PostCObject_DL).
 *
 * Based on Dart SDK file_saver_dart_api.h
 */

#ifndef FILE_SAVER_DART_API_H_
#define FILE_SAVER_DART_API_H_

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int64_t Dart_Port;

#define ILLEGAL_PORT ((Dart_Port)0)

typedef enum {
    Dart_CObject_kNull = 0,
    Dart_CObject_kBool,
    Dart_CObject_kInt32,
    Dart_CObject_kInt64,
    Dart_CObject_kDouble,
    Dart_CObject_kString,
    Dart_CObject_kArray,
    Dart_CObject_kTypedData,
    Dart_CObject_kExternalTypedData,
    Dart_CObject_kSendPort,
    Dart_CObject_kCapability,
    Dart_CObject_kNativePointer,
    Dart_CObject_kUnsupported,
    Dart_CObject_kNumberOfTypes
} Dart_CObject_Type;

typedef enum {
    Dart_TypedData_kByteData = 0,
    Dart_TypedData_kInt8,
    Dart_TypedData_kUint8,
    Dart_TypedData_kUint8Clamped,
    Dart_TypedData_kInt16,
    Dart_TypedData_kUint16,
    Dart_TypedData_kInt32,
    Dart_TypedData_kUint32,
    Dart_TypedData_kInt64,
    Dart_TypedData_kUint64,
    Dart_TypedData_kFloat32,
    Dart_TypedData_kFloat64,
    Dart_TypedData_kInt32x4,
    Dart_TypedData_kFloat32x4,
    Dart_TypedData_kFloat64x2,
    Dart_TypedData_kInvalid
} Dart_TypedData_Type;

typedef struct _Dart_CObject Dart_CObject;

typedef struct {
    Dart_Port id;
    Dart_Port origin_id;
} Dart_CObject_SendPort;

typedef struct {
    intptr_t ptr;
    intptr_t size;
    void* callback;
} Dart_CObject_NativePointer;

struct _Dart_CObject {
    Dart_CObject_Type type;
    union {
        bool as_bool;
        int32_t as_int32;
        int64_t as_int64;
        double as_double;
        const char* as_string;
        Dart_CObject_SendPort as_send_port;
        int64_t as_capability_id;
        Dart_CObject_NativePointer as_native_pointer;
        struct {
            Dart_TypedData_Type type;
            intptr_t length;
            const uint8_t* values;
        } as_typed_data;
        struct {
            Dart_TypedData_Type type;
            intptr_t length;
            uint8_t* data;
            void* peer;
            void* callback;
        } as_external_typed_data;
        struct {
            intptr_t length;
            Dart_CObject** values;
        } as_array;
    } value;
};

typedef bool (*Dart_PostCObject_Type)(Dart_Port port_id, Dart_CObject* message);

/**
 * Initialize Dart API DL with the given data pointer.
 * Must be called before using FileSaver_PostCObject_DL.
 *
 * @param data Pointer from NativeApi.initializeApiDLData
 * @return 0 on success, -1 on failure
 */
intptr_t FileSaver_InitializeApiDL(void* data);

/**
 * Posts a message to a Dart NativePort.
 *
 * @param port_id The port to send the message to
 * @param message The message to send
 * @return true if the message was posted successfully
 */
bool FileSaver_PostCObject_DL(Dart_Port port_id, Dart_CObject* message);

#ifdef __cplusplus
}
#endif

#endif /* FILE_SAVER_DART_API_H_ */
