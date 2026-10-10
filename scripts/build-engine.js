// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Builds the engine of the spike's Audio Unit (ticket 24) as a static
// library for iOS: the graph engine of aud_audio_graph, resolved through the
// package config as its build hook does (build-001), and
// src/aud_auv3_engine.cpp. The extension target of the example's Xcode
// project links build/ios/<platform>/libaud_auv3_engine.a and includes
// src/aud_auv3_engine.h.
//
//   node scripts/build-engine.js                 iphoneos and iphonesimulator
//   node scripts/build-engine.js iphoneos        one platform

'use strict';

const { createHash } = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');

// The simulator library is universal: Flutter builds the simulator app for
// arm64 and x86_64.
const platforms = {
  iphoneos: { targets: ['arm64-apple-ios15.0'] },
  iphonesimulator: {
    targets: ['arm64-apple-ios15.0-simulator', 'x86_64-apple-ios15.0-simulator'],
  },
};

function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(`${path.basename(command)} failed:\n${result.stdout}${result.stderr}`);
  }
  return result.stdout.trim();
}

// The `src` directory of a package, resolved through the package config.
function packageSrc(name) {
  const configPath = path.join(root, '.dart_tool', 'package_config.json');
  if (!fs.existsSync(configPath)) {
    throw new Error(`Run dart pub get first: ${configPath} is missing`);
  }
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const entry = config.packages.find((p) => p.name === name);
  if (!entry) throw new Error(`Package ${name} is not in the package config`);
  const rootUri = new URL(entry.rootUri, `file://${configPath}`);
  return path.join(decodeURIComponent(rootUri.pathname), 'src');
}

function hashOf(parts) {
  const hash = createHash('sha256');
  for (const part of parts) hash.update(part).update('\0');
  return hash.digest('hex').slice(0, 20);
}

async function build(platform) {
  const outDir = path.join(root, 'build', 'ios', platform);
  fs.mkdirSync(outDir, { recursive: true });
  const slices = [];
  for (const target of platforms[platform].targets) {
    slices.push(await buildSlice(platform, target));
  }
  const library = path.join(outDir, 'libaud_auv3_engine.a');
  fs.rmSync(library, { force: true });
  if (slices.length === 1) fs.copyFileSync(slices[0], library);
  else run('lipo', ['-create', '-output', library, ...slices]);
  console.log(`Built ${path.relative(root, library)}`);
}

// Builds one architecture and returns its static library.
async function buildSlice(platform, target) {
  const graph = packageSrc('aud_audio_graph');
  const core = packageSrc('aud_audio_core');
  const sdk = run('xcrun', ['--sdk', platform, '--show-sdk-path']);
  const objDir = path.join(root, '.dart_tool', 'auv3-build', target);
  fs.mkdirSync(objDir, { recursive: true });
  const flags = [
    '-target',
    target,
    '-isysroot',
    sdk,
    '-O2',
    '-g',
    '-std=c++17',
    '-fvisibility=hidden',
    '-fvisibility-inlines-hidden',
    '-I',
    graph,
    '-I',
    core,
    '-I',
    path.join(root, 'src'),
  ];
  const headers = [graph, core, path.join(root, 'src')]
    .flatMap((dir) =>
      fs
        .readdirSync(dir)
        .filter((file) => /\.(h|hpp)$/.test(file))
        .map((file) => path.join(dir, file)),
    )
    .sort();
  const headerHash = hashOf(headers.map((file) => file + fs.readFileSync(file, 'utf8')));
  const sources = [
    ...fs
      .readdirSync(graph)
      .filter((file) => file.endsWith('.cpp'))
      .map((file) => path.join(graph, file)),
    path.join(root, 'src', 'aud_auv3_engine.cpp'),
  ];
  const jobs = sources.map((file) => {
    const key = hashOf([...flags, headerHash, file, fs.readFileSync(file, 'utf8')]);
    return { file, object: path.join(objDir, `${path.basename(file)}-${key}.o`) };
  });
  const pending = jobs.filter((job) => !fs.existsSync(job.object));
  let next = 0;
  const failures = [];
  async function worker() {
    while (next < pending.length) {
      const job = pending[next++];
      const code = await new Promise((resolve) => {
        const child = spawn('clang++', [...flags, '-c', job.file, '-o', `${job.object}.tmp`], {
          cwd: root,
          stdio: 'inherit',
        });
        child.on('close', resolve);
      });
      if (code === 0) fs.renameSync(`${job.object}.tmp`, job.object);
      else failures.push(job.file);
    }
  }
  await Promise.all(Array.from({ length: Math.max(1, os.cpus().length) }, worker));
  if (failures.length > 0) throw new Error(`Compilation failed: ${failures.join(', ')}`);
  const slice = path.join(objDir, 'libaud_auv3_engine.a');
  fs.rmSync(slice, { force: true });
  run('libtool', ['-static', '-o', slice, ...jobs.map((job) => job.object)]);
  return slice;
}

async function main() {
  const requested = process.argv.slice(2);
  const targets = requested.length > 0 ? requested : Object.keys(platforms);
  for (const platform of targets) {
    if (!platforms[platform]) throw new Error(`Unknown platform ${platform}`);
    await build(platform);
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
