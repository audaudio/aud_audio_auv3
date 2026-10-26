// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Builds and runs the native unit tests of test/native (ticket 64) with the
// compile settings of aud_audio_plugin's scripts/plugin-build.js: every
// test is linked with the sources it covers into an executable under
// .dart_tool/auv3-build/test, which runs its tests and reports the
// failures. Exits with 1 when a test fails or does not build. macOS only.
//
//   node scripts/test-native.js           every test
//   node scripts/test-native.js events    the tests whose file name holds it

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const { root, core, buildDir, platforms } = require('./build-plugin.js');

const testDir = path.join(root, 'test', 'native');
const objDir = path.join(buildDir, 'test');

// The tests and the sources each covers.
const tests = [
  {
    file: 'aud_auv3_events_test.cpp',
    sources: [
      path.join(root, 'src', 'aud_auv3_events.cpp'),
      path.join(core.pluginSrc, 'aud_plugin_midi.cpp'),
    ],
  },
];

async function buildTest(test) {
  const options = { rtsan: false, watchdog: false };
  const packageSrc = core.packageSrcOf(path.join(root, '.dart_tool', 'package_config.json'));
  const dirs = { graph: packageSrc('aud_audio_graph'), core: packageSrc('aud_audio_core') };
  const target = platforms.macos();
  const flags = [...core.coreFlags(options, dirs, target), '-I', path.join(root, 'src')];
  const headers = core.headersHash([dirs.graph, dirs.core, core.pluginSrc, path.join(root, 'src'), testDir]);
  const objects = await core.compileAll(
    'clang++',
    flags,
    [path.join(testDir, test.file), ...test.sources],
    objDir,
    headers,
  );
  const binary = path.join(objDir, `${path.basename(test.file, '.cpp')}-${core.hashOf(objects)}`);
  if (!fs.existsSync(binary)) core.run('clang++', [...target, '-o', binary, ...objects]);
  return binary;
}

async function main() {
  const filter = process.argv[2] ?? '';
  const selected = tests.filter((test) => test.file.includes(filter));
  if (selected.length === 0) throw new Error(`No native test matches ${filter}`);
  const failed = [];
  for (const test of selected) {
    const name = path.basename(test.file, '.cpp');
    console.log(`${name}:`);
    const result = spawnSync(await buildTest(test), [], { stdio: 'inherit' });
    if (result.status !== 0) failed.push(name);
  }
  if (failed.length > 0) throw new Error(`Failed: ${failed.join(', ')}`);
  console.log('All native tests passed');
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
