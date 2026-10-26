// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The C interface of src/aud_auv3_editor_api.h without a unit, for the
// tests of AudAuv3Shell: instance 7 connects, every message comes back as
// it went, a message with "index":99 brings a reply that is no object.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef void (*Receiver)(char* json);

static Receiver receiver = 0;
static int64_t connected = -1;

int32_t aud_auv3_editor_connect(int64_t instance, Receiver r) {
  if (instance != 7) return -1;
  receiver = r;
  connected = instance;
  return 0;
}

int32_t aud_auv3_editor_send(int64_t instance, const char* json) {
  if (instance != connected || receiver == 0) return -1;
  receiver(strdup(strstr(json, "\"index\":99") != 0 ? "[]" : json));
  return 0;
}

void aud_auv3_editor_disconnect(int64_t instance) {
  if (instance == connected) receiver = 0;
}

void aud_auv3_editor_free(char* json) { free(json); }
