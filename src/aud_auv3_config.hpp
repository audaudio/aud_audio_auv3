// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// What scripts/build-plugin.js sets per build (ticket 64); the defaults
// below serve the native tests.
//
// - AUD_AUV3_CACHE_BUDGET_MB: the sample cache budget of the extension
//   process in megabytes, from plugin.json `auv3.cacheBudgetMB` for the
//   platform; every instance of a host shares it

#ifndef AUD_AUV3_CONFIG_HPP
#define AUD_AUV3_CONFIG_HPP

#include "aud_plugin_config.hpp"

#ifndef AUD_AUV3_CACHE_BUDGET_MB
#define AUD_AUV3_CACHE_BUDGET_MB 256
#endif

#endif  // AUD_AUV3_CONFIG_HPP
