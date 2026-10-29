# aud_midi_android example

A Flutter app that checks `aud_midi_android` on a device or the emulator.
It runs in a background isolate, like the MIDI isolate of `aud_midi`, and
writes a report to the screen and to logcat (tag `flutter`, prefix
`AUD_MIDI_REPORT`).

The manifest declares the test devices of the shim: a MIDI 1.0 loopback
(`AudMidiLoopbackService`), a UMP loopback (`AudMidiUmpLoopbackService`,
API 33) and the app's own virtual devices (`AudMidiDeviceService`,
`AudMidiUmpDeviceService`).

The report covers:

- the ports with directions, transports, protocols and capabilities
- bytes, order and timestamps through the MIDI 1.0 and the UMP loopback,
  sent with AMidi, including a 3000-byte SysEx and a scheduled packet
- data in both directions through the app's own virtual devices, with
  another client of the device sending through `MidiInputPort` and AMidi
- a Bluetooth LE scan, an `NsdManager` registration and the multicast lock
- typed messages through `MidiEngine` of `aud_midi_core`, including a note
  the engine schedules in software and a MIDI 1.0 message translated for
  the MIDI 2.0 port

## Run

```bash
flutter pub get
flutter build apk --release   # or --debug
adb install build/app/outputs/flutter-apk/app-release.apk
adb shell pm grant com.example.aud_midi_android_example \
  android.permission.BLUETOOTH_SCAN
adb shell pm grant com.example.aud_midi_android_example \
  android.permission.BLUETOOTH_CONNECT
adb shell am start -n com.example.aud_midi_android_example/.MainActivity
adb logcat | grep AUD_MIDI_REPORT
```

Without the Bluetooth grants the report shows the scan refused with
`MidiPermissionDenied`.
