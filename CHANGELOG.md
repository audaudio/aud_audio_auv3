# Changelog

## Unreleased

### Changed

- Require Dart 3.13 and upgrade the dependencies

- Require Dart 3.13

- Upgrade dna_audanika to ^0.1.0

- Set the identity the DNA layers ask for in dna/_vars.json

- Reformat 1 file with the Dart 3.13 formatter

- Add the blog post of this change, in English and German

- Bring the README to the README template, in English and German

- Upgrade the dependencies published since the first pass

- Lift the lock file to the newest resolvable versions

## 0.2.1 - 2026-10-26

### Changed

- Take the iOS editor's Dart code from the app's Frameworks

## 0.2.0 - 2026-10-26

### Added

- Add the AUv3 shell for macOS and iOS on aud_audio_plugin

### Changed

- Notify state observers of the editor's settings
- Send the editor's notes to the host's MIDI output
- Describe the MIDI output and live play in the README
- Refer to the AUv3's ticket by its number 64
- Keep restored controls untouched and send the preset ids
- Give the example identifiers of its own

## 0.1.1 - 2026-10-24

### Changed

- Resolve the example in a pub workspace

## 0.1.0 - 2026-10-11

### Added

- Add a Flutter editor spike to the AUv3 extension (ticket 24)

- Add AudAuv3Component: the component, channel names and parameter ids of the spike

- Add the engine over the headless host as a static library for iOS

- Add the AUv3 extension with a parameter tree, the render block and a 100 MB ballast

- Show a Flutter editor from one FlutterEngineGroup that follows host automation

- Add the container app that hosts one to four instances and reports the footprint

- Depend on aud_audio_core and aud_audio_graph 0.4.0; drop the template's FFI sample


### Fixed

- Fix the AUv3 editor parameters and the review findings

- Read the success value of aud_auv3_engine_param right: the editor got no parameters

- Fail allocateRenderResources when the engine cannot prepare or start

- Add aud_auv3_engine_param_id and the parameter flags instead of copies

- Stop the meter timer while the editor is hidden and close the sink of the editor

- End a run whose instantiation fails; harden build-engine.js

- Test audParamId with fixed vectors and document it in both READMEs


## 0.0.2 - 2026-10-08

### Added

- Initial boilerplate

### Changed

- Record the gg commit state
- Set up GitHub repo settings and branch rules
- Update dev dependencies
