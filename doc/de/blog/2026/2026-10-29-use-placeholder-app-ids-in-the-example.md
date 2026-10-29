<!--
@license
Copyright (c) Audanika. All Rights Reserved.

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Platzhalter-App-IDs im Example

## Motivation

- Die Example-App trug eine ID der Organisation (`com.audanika.*`).
- Wer das Example kopiert, hätte diese ID übernommen, und das Example
  belegte eine ID der Organisation auf Geräten und in Stores.

## Strategie

- Das Präfix durch den Platzhalter `com.example` ersetzen; der Rest jeder
  ID bleibt.
- An der Bibliothek nichts ändern.

## Umsetzung

- Android: `namespace`, `applicationId` und der Kotlin-Paketordner.
- iOS und macOS: `PRODUCT_BUNDLE_IDENTIFIER` der App und von
  `RunnerTests`; Linux `APPLICATION_ID` und der Windows-Firmenname, wo
  vorhanden.
- Die neuen IDs:
  - `com.example.aud_midi_android_example`
- Die Services der Bibliothek behalten ihre Klassennamen, z. B.
  `com.audanika.aud_midi_android.AudMidiLoopbackService`.

## Ergebnis

- Das Example analysiert sauber; keine ID der Organisation ist mehr darin.
