# Changelog

## Unreleased

### Added

- Add native taps through JNI on Android

- A C library built by a build hook and loaded by Java with System.loadLibrary; the receiver calls the tap with the bytes or UMP words and System.nanoTime

- GONE from the device callback; a detach returns after the last call; the loopback service can be switched off for hot-plug tests

- AndroidMidiBackend implements MidiNativeTapBackend; native tests under the sanitizers; NOTICES and the notices check

- Add the CommonJS notices check

- scripts/check-notices.js runs on older Node

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
