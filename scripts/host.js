// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Builds the example's container app with its AUv3 (scripts/build-plugin.js
// --appex), registers the extension with the system and runs the test host
// test/host/aud_auv3_host.swift on it (ticket 41): the host loads the unit
// out of process as Logic Pro does. With --validate it runs Apple's
// auval as well, with --play it plays live for that many seconds. macOS
// only.
//
//   node scripts/host.js [--sign <identity>] [--presets n] [--validate]
//     [--editor seconds] [--play seconds] [--skip-build]

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const { root, core, buildDir, readConfig, build, parseArgs } = require('./build-plugin.js');

const lsregister =
  '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';

function option(argv, name, fallback) {
  const at = argv.indexOf(name);
  return at >= 0 && at + 1 < argv.length ? argv[at + 1] : fallback;
}

// The container: the example's Flutter app, built once.
function exampleApp() {
  const built = path.join(root, 'example', 'build', 'macos', 'Build', 'Products', 'Release', 'aud_audio_auv3_example.app');
  if (!fs.existsSync(built)) {
    const result = spawnSync('flutter', ['build', 'macos', '--release'], {
      cwd: path.join(root, 'example'),
      stdio: 'inherit',
    });
    if (result.status !== 0) throw new Error('flutter build macos failed');
  }
  return built;
}

async function main() {
  const argv = process.argv.slice(2);
  const sign = option(argv, '--sign', '-');
  const config = readConfig(path.join(root, 'example', 'plugin', 'plugin.json'));
  const app = path.join(root, 'build', 'auv3', 'example', 'aud_audio_auv3_example.app');
  if (!argv.includes('--skip-build')) {
    core.removePath(app);
    fs.mkdirSync(path.dirname(app), { recursive: true });
    core.run('ditto', [exampleApp(), app]);
    await build(parseArgs(['--appex', '--app', app, '--sign', sign]));
  }
  // The system knows an extension once its app is registered.
  const appex = fs
    .readdirSync(path.join(app, 'Contents', 'PlugIns'))
    .map((name) => path.join(app, 'Contents', 'PlugIns', name))[0];
  core.run(lsregister, ['-f', app]);
  core.run('pluginkit', ['-a', appex]);

  const host = path.join(buildDir, 'aud_auv3_host');
  const source = path.join(root, 'test', 'host', 'aud_auv3_host.swift');
  if (!fs.existsSync(host) || fs.statSync(host).mtimeMs < fs.statSync(source).mtimeMs) {
    fs.mkdirSync(buildDir, { recursive: true });
    core.run('swiftc', ['-O', '-o', host, source]);
  }
  const { type, subtype, manufacturer } = config.auv3;
  const started = new Date(Date.now() - 1000);
  const args = [type, subtype, manufacturer, '--presets', option(argv, '--presets', '1000'), '--editor', option(argv, '--editor', '1')];
  if (option(argv, '--play')) args.push('--play', option(argv, '--play'));
  const result = spawnSync(host, args, { stdio: 'inherit' });
  let failed = result.status !== 0;
  // The editor said hello: its Dart code ran inside the extension and
  // reached the unit through dart:ffi; the unit logs it (info level).
  if (config.auv3.editorEntrypoint) {
    // log takes the local time.
    const two = (n) => String(n).padStart(2, '0');
    const stamp =
      `${started.getFullYear()}-${two(started.getMonth() + 1)}-${two(started.getDate())} ` +
      `${two(started.getHours())}:${two(started.getMinutes())}:${two(started.getSeconds())}`;
    const log = spawnSync(
      '/usr/bin/log',
      ['show', '--info', '--style', 'compact', '--start', stamp, '--predicate', `subsystem == "${config.bundleId}"`],
      { encoding: 'utf8' },
    );
    const hello = log.stdout.split('\n').find((line) => /said hello after/.test(line));
    console.log(JSON.stringify({ check: 'editorHello', ok: Boolean(hello), line: hello?.replace(/^.*\] /, '') ?? '' }));
    if (!hello) failed = true;
  }
  if (argv.includes('--validate')) {
    const auval = spawnSync('auval', ['-strict', '-v', type, subtype, manufacturer], { encoding: 'utf8' });
    const passed = /AU VALIDATION SUCCEEDED/.test(auval.stdout);
    console.log(JSON.stringify({ check: 'auval', ok: passed }));
    if (!passed) {
      console.log(auval.stdout.split('\n').filter((line) => /FAIL|ERROR|WARNING/i.test(line)).join('\n'));
      failed = true;
    }
  }
  if (failed) process.exit(1);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
