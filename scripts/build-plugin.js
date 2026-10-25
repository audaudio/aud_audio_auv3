// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Builds the AUv3 of an app from its plugin.json (ticket 41, plugin-011,
// doc/plugin-bundle.md) with clang, without CMake: the shared core of
// aud_audio_plugin, the graph engine, the node packages plugin.json names
// and the shell, compiled by aud_audio_plugin's scripts/plugin-build.js
// from a package config - the app's, so that the plugin plays the versions
// the app plays (plugin-010).
//
// For each platform it writes a static library, which an app's extension
// target links with -force_load and holds no code of its own; next to them
// the extension's Info.plist with its AudioComponents entry, an xcconfig
// the target includes, and the folder aud_plugin (plugin.json, document,
// presets), which the target copies into the extension's resources:
//
//   <out>/macos/libaud_auv3.a           Apple silicon, macOS 12
//   <out>/ios/libaud_auv3.a             iPhone and iPad, iOS 15
//   <out>/ios-simulator/libaud_auv3.a   the simulator on Apple silicon
//   <out>/Info.plist  <out>/AudAuv3.xcconfig  <out>/aud_plugin/
//
// With --appex it also links a standalone extension for macOS and puts it
// into the PlugIns of the app --app names (its bundle id prefixes the
// extension's), signed with --sign: what the package's own tests run.
//
//   node scripts/build-plugin.js                       the example, macOS
//   node scripts/build-plugin.js --config <plugin.json>
//       [--package-config <.dart_tool/package_config.json>]
//       [--platform macos|ios|ios-simulator]...   (default: macos)
//       [--out <directory>] [--appex --app <App.app> [--sign <identity>]]

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { fileURLToPath, pathToFileURL } = require('node:url');

const root = path.resolve(__dirname, '..');

// The package config the build resolves its packages through: the app's,
// named by --package-config, or this package's own.
function packageConfigOf(argv) {
  const at = argv.indexOf('--package-config');
  return at >= 0 && at + 1 < argv.length
    ? path.resolve(argv[at + 1])
    : path.join(root, '.dart_tool', 'package_config.json');
}

// The shared build of aud_audio_plugin (scripts/plugin-build.js), from the
// package config of this run.
function pluginBuildOf(configPath) {
  if (!fs.existsSync(configPath)) {
    throw new Error(`Run dart pub get first: ${configPath} is missing`);
  }
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const entry = config.packages.find((p) => p.name === 'aud_audio_plugin');
  if (!entry) throw new Error(`Package aud_audio_plugin is not in ${configPath}`);
  const pluginRoot = fileURLToPath(new URL(entry.rootUri, pathToFileURL(configPath)));
  return require(path.join(pluginRoot, 'scripts', 'plugin-build.js'));
}

const core = pluginBuildOf(
  packageConfigOf(require.main === module ? process.argv.slice(2) : []),
);

const buildDir = path.join(root, '.dart_tool', 'auv3-build');
const exampleConfig = path.join(root, 'example', 'plugin', 'plugin.json');

// The shell's own sources.
const shellSources = [
  'src/aud_auv3_audio_unit.mm',
  'src/aud_auv3_editor_bridge.mm',
  'src/aud_auv3_events.cpp',
  'src/aud_auv3_view_controller.mm',
];

// The functions the editor's Dart code finds with dart:ffi
// (src/aud_auv3_editor_api.h); the extension's binary exports them.
const editorExports = [
  '_aud_auv3_editor_connect',
  '_aud_auv3_editor_disconnect',
  '_aud_auv3_editor_free',
  '_aud_auv3_editor_send',
];

// The Flutter framework the view controller compiles against, per platform:
// the release engine of the Flutter SDK that builds the app. The extension
// loads the one of the app at run time.
function flutterFrameworkDir(platform) {
  const flutter = fs.realpathSync(execFileSync('which', ['flutter'], { encoding: 'utf8' }).trim());
  const engine = path.join(path.dirname(path.dirname(flutter)), 'bin', 'cache', 'artifacts', 'engine');
  if (platform === 'macos') {
    return path.join(engine, 'darwin-x64-release', 'FlutterMacOS.xcframework', 'macos-arm64_x86_64');
  }
  return path.join(
    engine,
    'ios-release',
    'Flutter.xcframework',
    platform === 'ios' ? 'ios-arm64' : 'ios-arm64_x86_64-simulator',
  );
}

// What an extension links of the system.
const frameworks = ['AVFoundation', 'AudioToolbox', 'CoreAudioKit', 'CoreMIDI', 'Foundation', 'QuartzCore'];

function sdkPath(sdk) {
  return execFileSync('xcrun', ['--sdk', sdk, '--show-sdk-path'], { encoding: 'utf8' }).trim();
}

// The machine of each platform, and its SDK.
const platforms = {
  macos: () => ['-arch', 'arm64', '-mmacosx-version-min=12.0'],
  ios: () => ['-target', 'arm64-apple-ios15.0', '-isysroot', sdkPath('iphoneos')],
  'ios-simulator': () => [
    '-target',
    'arm64-apple-ios15.0-simulator',
    '-isysroot',
    sdkPath('iphonesimulator'),
  ],
};

// ............................................................................
// Arguments, configuration

function parseArgs(argv) {
  const options = {
    config: exampleConfig,
    packageConfig: path.join(root, '.dart_tool', 'package_config.json'),
    platforms: [],
    out: path.join(root, 'build', 'auv3'),
    appex: false,
    app: null,
    sign: '-',
    rtsan: false,
    watchdog: false,
  };
  for (let i = 0; i < argv.length; ++i) {
    const arg = argv[i];
    if (arg === '--config') options.config = path.resolve(argv[++i]);
    else if (arg === '--package-config') options.packageConfig = path.resolve(argv[++i]);
    else if (arg === '--platform') options.platforms.push(argv[++i]);
    else if (arg === '--out') options.out = path.resolve(argv[++i]);
    else if (arg === '--appex') options.appex = true;
    else if (arg === '--app') options.app = path.resolve(argv[++i]);
    else if (arg === '--sign') options.sign = argv[++i];
    else throw new Error(`Unknown option ${arg}`);
  }
  if (options.platforms.length === 0) options.platforms.push('macos');
  for (const platform of options.platforms) {
    if (!platforms[platform]) throw new Error(`Unknown platform ${platform}`);
  }
  if (options.appex && !options.app) throw new Error('--appex needs --app');
  return options;
}

const fourCharCode = /^[\x20-\x7e]{4}$/;

function readConfig(file) {
  const config = JSON.parse(fs.readFileSync(file, 'utf8'));
  for (const key of ['name', 'vendor', 'version', 'bundleId']) {
    if (typeof config[key] !== 'string' || config[key] === '') {
      throw new Error(`${file} needs ${key}`);
    }
  }
  const auv3 = config.auv3 ?? {};
  for (const key of ['type', 'subtype', 'manufacturer']) {
    if (!fourCharCode.test(auv3[key] ?? '')) {
      throw new Error(`${file}: auv3.${key} must be four characters`);
    }
  }
  // Apple reserves the codes of lower-case letters only.
  if (auv3.manufacturer === auv3.manufacturer.toLowerCase()) {
    throw new Error(`${file}: auv3.manufacturer needs a character that is not lower case`);
  }
  config.packages = config.packages ?? [];
  config.auv3 = auv3;
  return config;
}

// The version of an AudioComponents entry: 0xMMMMmmbb of major, minor, bug.
function componentVersion(version) {
  const [major = 0, minor = 0, bug = 0] = version.split(/[.+-]/).map((part) => Number.parseInt(part, 10) || 0);
  return (major << 16) | ((minor & 0xff) << 8) | (bug & 0xff);
}

// The sample cache budget of the extension process on `platform`.
function cacheBudgetOf(config, platform) {
  const budget = config.auv3.cacheBudgetMB ?? {};
  const value = budget[platform.startsWith('ios') ? 'ios' : 'macos'];
  return Number.isInteger(value) && value > 0 ? value : 256;
}

function xml(text) {
  return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// The extension's Info.plist; `fixed` gives the values Xcode would expand
// from the target's build settings.
function infoPlist(config, fixed = null) {
  const value = (setting, fallback) => (fixed ? fixed[setting] ?? fallback : `$(${setting})`);
  const tags = (config.auv3.tags ?? ['Synthesizer']).map((tag) => `\t\t\t\t\t\t<string>${xml(tag)}</string>`);
  const platformKeys = fixed
    ? `\t<key>LSMinimumSystemVersion</key>\n\t<string>12.0</string>\n`
    : '';
  // The entry point of the editor's Dart code; without one the view stays
  // empty.
  const editorKey = config.auv3.editorEntrypoint
    ? `\t<key>AudAuv3EditorEntrypoint</key>\n\t<string>${xml(config.auv3.editorEntrypoint)}</string>\n`
    : '';
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleDevelopmentRegion</key>
\t<string>en</string>
\t<key>CFBundleDisplayName</key>
\t<string>${xml(config.name)}</string>
\t<key>CFBundleExecutable</key>
\t<string>${value('EXECUTABLE_NAME')}</string>
\t<key>CFBundleIdentifier</key>
\t<string>${value('PRODUCT_BUNDLE_IDENTIFIER')}</string>
\t<key>CFBundleInfoDictionaryVersion</key>
\t<string>6.0</string>
\t<key>CFBundleName</key>
\t<string>${value('PRODUCT_NAME')}</string>
\t<key>CFBundlePackageType</key>
\t<string>${value('PRODUCT_BUNDLE_PACKAGE_TYPE', 'XPC!')}</string>
\t<key>CFBundleShortVersionString</key>
\t<string>${value('MARKETING_VERSION', config.version)}</string>
\t<key>CFBundleVersion</key>
\t<string>${value('CURRENT_PROJECT_VERSION', config.version)}</string>
${platformKeys}${editorKey}\t<key>NSExtension</key>
\t<dict>
\t\t<key>NSExtensionAttributes</key>
\t\t<dict>
\t\t\t<key>AudioComponents</key>
\t\t\t<array>
\t\t\t\t<dict>
\t\t\t\t\t<key>description</key>
\t\t\t\t\t<string>${xml(config.auv3.description ?? config.name)}</string>
\t\t\t\t\t<key>manufacturer</key>
\t\t\t\t\t<string>${xml(config.auv3.manufacturer)}</string>
\t\t\t\t\t<key>name</key>
\t\t\t\t\t<string>${xml(`${config.vendor}: ${config.name}`)}</string>
\t\t\t\t\t<key>sandboxSafe</key>
\t\t\t\t\t<true/>
\t\t\t\t\t<key>subtype</key>
\t\t\t\t\t<string>${xml(config.auv3.subtype)}</string>
\t\t\t\t\t<key>tags</key>
\t\t\t\t\t<array>
${tags.join('\n')}
\t\t\t\t\t</array>
\t\t\t\t\t<key>type</key>
\t\t\t\t\t<string>${xml(config.auv3.type)}</string>
\t\t\t\t\t<key>version</key>
\t\t\t\t\t<integer>${componentVersion(config.version)}</integer>
\t\t\t\t</dict>
\t\t\t</array>
\t\t</dict>
\t\t<key>NSExtensionPointIdentifier</key>
\t\t<string>com.apple.AudioUnit-UI</string>
\t\t<key>NSExtensionPrincipalClass</key>
\t\t<string>AudAuv3ViewController</string>
\t</dict>
</dict>
</plist>
`;
}

// The xcconfig an app's extension target includes: the library of the
// platform it builds for, linked whole, and the generated Info.plist.
function xcconfig(out) {
  return [
    '// Generated by aud_audio_auv3/scripts/build-plugin.js; do not edit.',
    `AUD_AUV3_LIB_macosx = ${path.join(out, 'macos', 'libaud_auv3.a')}`,
    `AUD_AUV3_LIB_iphoneos = ${path.join(out, 'ios', 'libaud_auv3.a')}`,
    `AUD_AUV3_LIB_iphonesimulator = ${path.join(out, 'ios-simulator', 'libaud_auv3.a')}`,
    'AUD_AUV3_FLUTTER_macosx = FlutterMacOS',
    'AUD_AUV3_FLUTTER_iphoneos = Flutter',
    'AUD_AUV3_FLUTTER_iphonesimulator = Flutter',
    `FRAMEWORK_SEARCH_PATHS[sdk=macosx*] = $(inherited) ${flutterFrameworkDir('macos')}`,
    `FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*] = $(inherited) ${flutterFrameworkDir('ios')}`,
    `FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*] = $(inherited) ${flutterFrameworkDir('ios-simulator')}`,
    `OTHER_LDFLAGS = $(inherited) -force_load $(AUD_AUV3_LIB_$(PLATFORM_NAME)) -lc++ ${frameworks
      .map((framework) => `-framework ${framework}`)
      .join(' ')} -framework $(AUD_AUV3_FLUTTER_$(PLATFORM_NAME)) ${editorExports
      .map((name) => `-Wl,-exported_symbol,${name}`)
      .join(' ')}`,
    // Flutter of the app: Contents/Frameworks on macOS, Frameworks on iOS.
    'LD_RUNPATH_SEARCH_PATHS[sdk=macosx*] = $(inherited) @executable_path/../../../../Frameworks',
    'LD_RUNPATH_SEARCH_PATHS[sdk=iphone*] = $(inherited) @executable_path/../../Frameworks',
    // The exported functions of the editor keep their symbols.
    'STRIP_STYLE = non-global',
    `INFOPLIST_FILE = ${path.join(out, 'Info.plist')}`,
    'APPLICATION_EXTENSION_API_ONLY = YES',
    `AUD_AUV3_PLUGIN_FOLDER = ${path.join(out, 'aud_plugin')}`,
    '',
  ].join('\n');
}

function cString(text) {
  return JSON.stringify(String(text));
}

// ............................................................................
// The build

async function buildLibrary(options, config, platform) {
  const packageSrc = core.packageSrcOf(options.packageConfig);
  const dirs = { graph: packageSrc('aud_audio_graph'), core: packageSrc('aud_audio_core') };
  const recipes = core.recipesOf(config.packages, packageSrc);
  const target = platforms[platform]();
  const flags = [
    ...core.coreFlags(options, dirs, target),
    '-fapplication-extension',
    '-DAUD_PLUGIN_LOG_ENV="AUD_AUV3_LOG"',
    `-DAUD_PLUGIN_LOG_SUBSYSTEM=${cString(config.bundleId)}`,
    `-DAUD_AUV3_CACHE_BUDGET_MB=${cacheBudgetOf(config, platform)}`,
    '-I',
    path.join(root, 'src'),
  ];
  const headers = core.headersHash([
    dirs.graph,
    dirs.core,
    core.pluginSrc,
    path.join(root, 'src'),
    ...recipes.flatMap((recipe) => recipe.includes),
  ]);
  const objDir = path.join(buildDir, platform);
  const objects = [
    ...(await core.compileAll('clang++', flags, core.cppIn(dirs.graph), path.join(objDir, 'graph'), headers)),
  ];
  for (const recipe of recipes) {
    objects.push(
      ...(await core.compileAll(
        'clang++',
        [
          ...flags,
          ...recipe.includes.flatMap((dir) => ['-I', dir]),
          ...recipe.defines.map((define) => `-D${define}`),
          ...recipe.flags,
        ],
        recipe.sources,
        path.join(objDir, recipe.name),
        headers,
        recipe.cFlags ?? [],
      )),
    );
  }
  const generated = path.join(objDir, `packages-${core.hashOf([config.packages.join(',')])}.cpp`);
  fs.mkdirSync(objDir, { recursive: true });
  fs.writeFileSync(generated, core.packagesSource(recipes));
  objects.push(
    ...(await core.compileAll(
      'clang++',
      [...flags, '-F', flutterFrameworkDir(platform)],
      [
        ...core.coreSources(platform === 'macos' ? 'macos' : 'ios'),
        ...shellSources.map((file) => path.join(root, file)),
        generated,
      ],
      path.join(objDir, 'shell'),
      headers,
    )),
  );
  const library = path.join(options.out, platform, 'libaud_auv3.a');
  fs.mkdirSync(path.dirname(library), { recursive: true });
  fs.rmSync(library, { force: true });
  core.run('libtool', ['-static', '-no_warning_for_no_symbols', '-o', library, ...objects]);
  return { library, recipes };
}

// The configuration the extension carries: plugin.json, document, presets.
function stageSettings(options, config, target) {
  core.removePath(target);
  fs.mkdirSync(target, { recursive: true });
  const configDir = path.dirname(options.config);
  fs.copyFileSync(options.config, path.join(target, 'plugin.json'));
  for (const file of [config.document ?? 'document.json', config.presets ?? 'presets.json']) {
    fs.copyFileSync(path.join(configDir, file), path.join(target, file));
  }
}

// A standalone extension for macOS in the PlugIns of `options.app`.
function buildAppex(options, config, library, recipes) {
  const appInfo = path.join(options.app, 'Contents', 'Info.plist');
  const appId = execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleIdentifier', appInfo], {
    encoding: 'utf8',
  }).trim();
  const executable = config.name.replace(/[^A-Za-z0-9_-]/g, '') || 'AudAuv3';
  const appex = path.join(options.app, 'Contents', 'PlugIns', `${executable}.appex`);
  core.removePath(appex);
  const contents = path.join(appex, 'Contents');
  fs.mkdirSync(path.join(contents, 'MacOS'), { recursive: true });
  const libraries = [...new Set(recipes.flatMap((recipe) => recipe.libraries ?? []))];
  core.run('clang++', [
    ...platforms.macos(),
    '-fapplication-extension',
    '-e',
    '_NSExtensionMain',
    '-o',
    path.join(contents, 'MacOS', executable),
    '-Wl,-force_load',
    library,
    '-lc++',
    ...libraries.map((name) => `-l${name}`),
    ...[...frameworks, 'AppKit'].flatMap((framework) => ['-framework', framework]),
    // Flutter of the app around the extension, at run time as at link time.
    '-F',
    path.join(options.app, 'Contents', 'Frameworks'),
    '-framework',
    'FlutterMacOS',
    '-Wl,-rpath,@executable_path/../../../../Frameworks',
    ...editorExports.map((name) => `-Wl,-exported_symbol,${name}`),
    '-Wl,-dead_strip',
  ]);
  fs.writeFileSync(
    path.join(contents, 'Info.plist'),
    infoPlist(config, {
      EXECUTABLE_NAME: executable,
      PRODUCT_BUNDLE_IDENTIFIER: `${appId}.auv3`,
      PRODUCT_NAME: executable,
    }),
  );
  stageSettings(options, config, path.join(contents, 'Resources', 'aud_plugin'));
  // The editor's Dart code travels inside the extension: the sandbox lets
  // the extension read its own bundle, not the app's resources.
  const dart = path.join(options.app, 'Contents', 'Frameworks', 'App.framework');
  if (config.auv3.editorEntrypoint && fs.existsSync(dart)) {
    fs.mkdirSync(path.join(contents, 'Frameworks'), { recursive: true });
    core.run('ditto', [dart, path.join(contents, 'Frameworks', 'App.framework')]);
  }
  const entitlements = path.join(buildDir, 'appex.entitlements');
  fs.mkdirSync(buildDir, { recursive: true });
  fs.writeFileSync(
    entitlements,
    '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ' +
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n' +
      '\t<key>com.apple.security.app-sandbox</key>\n\t<true/>\n</dict>\n</plist>\n',
  );
  const sign = ['--force', '--options', 'runtime', '--timestamp=none', '--sign', options.sign];
  const embedded = path.join(contents, 'Frameworks', 'App.framework');
  if (fs.existsSync(embedded)) core.run('codesign', [...sign, embedded]);
  core.run('codesign', [...sign, '--entitlements', entitlements, appex]);
  // The extension runs with the hardened runtime and loads only code of its
  // own team: the app's frameworks get the same signature.
  const appFrameworks = path.join(options.app, 'Contents', 'Frameworks');
  for (const framework of fs.existsSync(appFrameworks) ? fs.readdirSync(appFrameworks) : []) {
    core.run('codesign', [...sign, path.join(appFrameworks, framework)]);
  }
  core.run('codesign', [...sign, '--preserve-metadata=entitlements', options.app]);
  return appex;
}

async function build(options) {
  const config = readConfig(options.config);
  let macos = null;
  for (const platform of options.platforms) {
    const built = await buildLibrary(options, config, platform);
    if (platform === 'macos') macos = built;
    console.log(`Built ${built.library}`);
  }
  fs.writeFileSync(path.join(options.out, 'Info.plist'), infoPlist(config));
  fs.writeFileSync(path.join(options.out, 'AudAuv3.xcconfig'), xcconfig(options.out));
  stageSettings(options, config, path.join(options.out, 'aud_plugin'));
  if (options.appex) {
    if (!macos) throw new Error('--appex needs the platform macos');
    console.log(`Built ${buildAppex(options, config, macos.library, macos.recipes)}`);
  }
}

module.exports = {
  root,
  flutterFrameworkDir,
  editorExports,
  core,
  buildDir,
  platforms,
  frameworks,
  readConfig,
  componentVersion,
  infoPlist,
  build,
  parseArgs,
};

if (require.main === module) {
  build(parseArgs(process.argv.slice(2))).catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
