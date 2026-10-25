// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The C interface between the unit and its editor inside the extension
// (ticket 41, plugin-012), for dart:ffi: the editor's Dart code and the
// unit share the extension's process, so the messages of the shell
// protocol (aud_audio_plugin's AudShellMessage as JSON text) travel by
// function call instead of a socket or a platform channel. The extension's
// binary exports these functions; Dart finds them with
// DynamicLibrary.process() (lib/src/aud_auv3_shell.dart).
//
// The view controller starts each editor with the argument
// `--aud-auv3-instance=<n>`, the instance of the editor's unit. The editor
// connects with it and a receiver - a NativeCallable.listener, which any
// thread may call -, and sends its messages; the unit sends its own to the
// receiver as text it allocated, which the editor frees with
// aud_auv3_editor_free once it read it.

#ifndef AUD_AUV3_EDITOR_API_H
#define AUD_AUV3_EDITOR_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AUD_AUV3_EXPORT __attribute__((visibility("default"), used))

// .............................................................................
// Receives a message of the unit as NUL-terminated UTF-8 JSON, which the
// receiver frees with aud_auv3_editor_free.
typedef void (*AudAuv3EditorReceiver)(char* json);

// .............................................................................
// [any thread] Connects the editor of `instance` with `receiver`; a later
// connection of the same instance replaces it. 0, or -1 for an instance
// without an editor's view.
AUD_AUV3_EXPORT int32_t aud_auv3_editor_connect(int64_t instance,
                                                AudAuv3EditorReceiver receiver);

// .............................................................................
// [any thread] Hands the unit a message of the editor: NUL-terminated UTF-8
// JSON, which the unit copies. 0, or -1 for an instance not connected.
AUD_AUV3_EXPORT int32_t aud_auv3_editor_send(int64_t instance, const char* json);

// .............................................................................
// [any thread] Disconnects the editor of `instance`; the unit sends it
// nothing after.
AUD_AUV3_EXPORT void aud_auv3_editor_disconnect(int64_t instance);

// .............................................................................
// [any thread] Frees a message the unit sent.
AUD_AUV3_EXPORT void aud_auv3_editor_free(char* json);

#ifdef __cplusplus
}
#endif

#endif  // AUD_AUV3_EDITOR_API_H
