# Changelog

## Unreleased

### Changed

- Name files with / in check-notices.js

## 0.2.0 - 2026-10-12

### Added

- Add native taps through JNI on Android

- A C library built by a build hook and loaded by Java with System.loadLibrary; the receiver calls the tap with the bytes or UMP words and System.nanoTime

- GONE from the device callback; a detach returns after the last call; the loopback service can be switched off for hot-plug tests

- AndroidMidiBackend implements MidiNativeTapBackend; native tests under the sanitizers; NOTICES and the notices check

- Add the CommonJS notices check

- scripts/check-notices.js runs on older Node

- Add aud_midi_standard from pub.dev to the example

- The example resolves aud_midi_standard from pub.dev instead of a sibling checkout

- Add review fixes of ticket 26

- README.de.md mirrors the native tap additions of README.md

- Remove the unused AudMidiNativeTap.setLoaded and aud_midi_android_register_natives

- MidiAndroidReceiver.setListening: a port open for its tap only copies nothing through Java and Dart

- test/native/aud_midi_android_tap_test.dart runs scripts/test-native.js under the sanitizers

- scripts/check-notices.js as an ES module like the other scripts

- AudMidiReceiver.setNativeTap: registerTap and unregisterTap

- aud_midi_android.h: PARAM_ERROR for a NULL function

- test-native.js: the asan build no longer shadows main

- aud_midi_core ^0.2.0

- Add independent constraints on the aud_midi packages

- Add review fixes of ticket 26


## 0.1.1 - 2026-10-12

### Removed

- Remove publish_to none from pubspec.yaml

## 0.1.0 - 2026-10-07

### Added

- Add boilerplate
- Add package dependencies
- Add the Android backend with Java shim and AMidi

### Changed

- Upgrade dependencies
- Rename the PM repo to aud_midi_pm and move the plan there
- Use git dependencies and set publish_to none
- Reference the aud_midi packages on pub.dev and the audmidi organization
- Plan BLE peripheral support
- Merge main

## 0.0.0 - 2026-10-06

- Initial boilerplate
