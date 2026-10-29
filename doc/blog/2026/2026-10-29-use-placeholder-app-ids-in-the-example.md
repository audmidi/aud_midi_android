<!--
@license
Copyright (c) Audanika. All Rights Reserved.

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Use placeholder app IDs in the example

## Motivation

- The example app identified itself with an ID of the organization
  (`com.audanika.*`).
- A developer who copies the example would inherit that ID, and the
  example claimed an ID of the organization on devices and in stores.

## Strategy

- Replace the prefix by the placeholder `com.example`; the rest of each
  ID stays.
- Change nothing in the library.

## Implementation

- Android: `namespace`, `applicationId` and the Kotlin package folder.
- iOS and macOS: `PRODUCT_BUNDLE_IDENTIFIER` of the app and of
  `RunnerTests`; Linux `APPLICATION_ID` and the Windows company name
  where present.
- The new IDs:
  - `com.example.aud_midi_android_example`
- The services of the library keep their class names, e.g.
  `com.audanika.aud_midi_android.AudMidiLoopbackService`.

## Result

- The example analyzes clean; no ID of the organization is left in it.
