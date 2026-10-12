# aud_midi_android

Das Android-Backend von aud_midi: `android.media.midi` über jnigen-Bindings
und einen kleinen Java-Shim, AMidi über FFI zum Senden.

Teil der aud_midi-Familie, siehe [aud_midi](https://github.com/audmidi/aud_midi).

## Ziele

- USB-, Bluetooth-LE- und virtuelle MIDI-Geräte als Ports
- MIDI-1.0-Bytestrom-Geräte und ab API 33 Universal MIDI Packets
- Android-Zeitstempel beim Empfang, AMidi mit Zeitstempeln beim Senden
- Java-Shim für die abstrakten Callback-Klassen, kein MethodChannel
- Native Taps: ein C-Konsument, über JNI auf dem MIDI-Thread aufgerufen
- Eigene virtuelle Geräte der App: `MidiDeviceService`, `MidiUmpDeviceService`
- `NsdManager`-Ankündigung und Multicast-Lock für Netzwerk-Sessions
- BLE-Peripheral über BluetoothGattServer

## Stand

`AndroidMidiBackend` (Name `android`) implementiert `MidiBackend` aus
[aud_midi_core](https://github.com/audmidi/aud_midi_core):

- Ports: jeder Port jedes Geräts, das der MIDI-Dienst kennt: USB,
  Bluetooth und die virtuellen Geräte anderer Apps; ab API 33 beide
  Transporte (`getDevicesForTransport`). Androids Input-Port, Daten in das
  Gerät, ist ein Output der App und umgekehrt. Ids sind
  `android:<Geräte-Id>:in|out:<Portnummer>`; Android vergibt beim erneuten
  Einstecken eine neue Geräte-Id, der `fingerprint` findet die Kandidaten.
  Bytestrom-Geräte sprechen MIDI 1.0; UMP-Geräte nehmen ihr Protokoll aus
  `getDefaultProtocol` und tauschen UMP-Wörter aus, Big-Endian in Androids
  Byte-Arrays.
- Empfang: der `AudMidiReceiver` des Shims kopiert jedes Stück mit seinem
  Zeitstempel in einen Puffer von 64 KiB je Port und signalisiert dem
  Isolate einmal; das Isolate holt alle Stücke mit einem JNI-Aufruf ab.
  Ein voller Puffer verwirft das neueste Stück und zählt es
  (`queueOverflow`). Die Zeitstempel, `System.nanoTime()` =
  `CLOCK_MONOTONIC`, werden über `MidiClockMapper` zu Paketzeiten, alle
  10 s und bei Hotplug neu vermessen.
- Senden: AMidi `sendWithTimestamp` ab API 29, `MidiInputPort.send`
  darunter oder wenn AMidi ein Gerät ablehnt (Diagnose `nativeError`).
  Stücke haben höchstens 1012 Bytes und teilen nie ein UMP. Outputs zu
  USB- und Bluetooth-Geräten melden `scheduledSend` und `cancelPending`:
  der MIDI-Dienst hält die Daten bis zur Fälligkeit und verwirft sie bei
  einem Flush. Ein virtuelles Gerät bekommt den Zeitstempel mit den Daten
  und entscheidet selbst, daher plant die Engine für es.
- Hotplug: `AudMidiDeviceCallback` je Transport → hinzugefügte, entfernte
  und geänderte Ports; die offenen Ports eines entfernten Geräts werden
  geschlossen.
- Native Taps (`MidiNativeTapBackend` aus aud_midi_core): `attachNativeTap`
  öffnet den Port bei Bedarf und belegt einen Slot der nativen
  Tap-Bibliothek (`src/aud_midi_android.c`, gebaut von `hook/build.dart`);
  der Java-Empfänger reicht jedes Stück über JNI auf dem MIDI-Thread an sie
  weiter, in einen begrenzten Stack-Puffer kopiert, mit dem
  `System.nanoTime()`-Stempel. Ein MIDI-1.0-Port bekommt die Bytes, ein
  UMP-Port die vollständigen Pakete in Host-Reihenfolge (die Bibliothek
  setzt die Wörter über Stücke hinweg zusammen). `AudMidiDeviceCallback`
  meldet `gone` an die Taps eines entfernten Geräts, bevor Dart davon
  erfährt; das Backend löst sie dann mit dem Port. Ein Tap hält den Port
  ohne Dart-Listener offen, und ein nur für seinen Tap offener Port kopiert
  nichts durch Java und Dart; `detachNativeTap` kehrt zurück, nachdem der
  letzte Aufruf des Taps zurückgekehrt ist, und gibt nie einen Slot frei,
  den ein Aufruf noch berühren kann (ein Timeout leakt ihn und loggt).
- `virtualPorts` (statisch): die Ports der eigenen `AudMidiDeviceService`
  und `AudMidiUmpDeviceService` (oder Unterklassen) aus dem Manifest,
  gelistet mit `isOwn`. `create(spec)` gibt einen deklarierten Port aus,
  benannt wie die Spec oder den ersten freien; Android erzeugt zur
  Laufzeit keinen.
- `bluetooth`: Bluetooth-LE-Suche mit dem UUID-Filter des BLE-MIDI-Dienstes,
  `connect` über `openBluetoothDevice`; das Peripheriegerät bleibt bis
  `disconnect` offen. Berechtigungen je API-Level; eine fehlende wirft
  `MidiPermissionDenied` und steht in `capabilities.missingPermissions`.
- `network` ist null: Android hat keine Netzwerk-Session. Der Umbrella
  setzt die AppleMIDI-Session aus aud_midi_network mit
  `MidiAndroidServiceAdvertiser` (`NsdManager`) zusammen; mDNS-Suche
  braucht einen `MidiAndroidMulticastLock`.
- Isolates: package:jni lädt Klassen über den Application-Classloader,
  den sein Plugin festhält, und hängt Threads bei Bedarf an; das Backend
  läuft daher in jedem Isolate. Der Application-Context kommt vom
  Content-Provider des Shims oder aus dem Parameter `context`.

Verifiziert auf dem Android-Emulator (API 36, arm64) mit der
[Beispiel-App](example/README.md) in einem Hintergrund-Isolate, Debug- und
Release-Build (R8):

| Prüfung | Ergebnis |
| --- | --- |
| Aufzählung | MIDI-1.0- und UMP-Loopback, eigene MIDI-1.0- und UMP-Geräte mit `isOwn` |
| MIDI-1.0-Loopback über AMidi, 3018 Bytes mit einer SysEx von 3000 Bytes | Bytes und Reihenfolge unverändert, Zeitstempel auf 0–2 µs zurück |
| Paket fällig in 200 ms | Zeitstempel gleich der Fälligkeit; kommt sofort an, ein virtuelles Gerät plant nicht |
| UMP-Loopback über AMidi, 607 Wörter mit 300 MIDI-2.0-Noten | Wörter und Reihenfolge unverändert |
| Latenz vom Java-Empfänger nach Dart | 0,15–2,5 ms Release, 7–12 ms Debug |
| Eigene virtuelle Geräte, MIDI 1.0 und UMP | Daten in beide Richtungen, der andere Client sendet über `MidiInputPort` und AMidi |
| `System.nanoTime()`-Stempel gegen den `CLOCK_MONOTONIC`-Leser | Ankunft 46–169 µs nach dem Stempel: dieselbe Uhr |
| `cancelPending`, `MidiInputPort.flush` | kein Fehler |
| Bluetooth-LE-Suche | startet und endet, findet auf dem Emulator nichts |
| `NsdManager`, Multicast-Lock | `_apple-midi._udp` angemeldet und abgemeldet; Lock gehalten |
| `MidiEngine` über `AndroidMidiBackend` | typisierte Nachrichten unverändert; eine in Software geplante Note 1,5–1,9 ms nach Fälligkeit; ein MIDI-1.0-Note-On an einen MIDI-2.0-Port kommt als MIDI 2.0 an |
| Release-Build | R8 behält alle Shim-Klassen; gleicher Bericht |
| `System.loadLibrary("aud_midi_android")` | Flutter packt die Bibliothek des Build-Hooks unter `lib/<abi>/`, Java lädt sie, Dart erreicht dieselbe Datei als Code-Asset |
| Nativer Tap auf den Loopbacks | Bytes und UMP-Pakete erreichen den Probe-Tap mit `CLOCK_MONOTONIC`-Stempeln (Stempel bis Tap 0,4–1 ms), nichts bei Dart ohne Listener |
| Tap unter einem Burst gelöst | kein Aufruf, nachdem das Lösen zurückgekehrt ist |
| `gone` | aus dem Geräte-Callback 1,2 s nach dem Abschalten des Loopback-Dienstes, 67 ms bevor Dart das Entfernen sah |

Nicht verifiziert: USB-Geräte und echte BLE-MIDI-Peripheriegeräte (keine
Hardware), API-Level unter 33 (kein UMP) und unter 29 (Senden nur über
`MidiInputPort`; dieser Weg lief auf API 36 als Client des eigenen
Geräts), Hotplug echter Geräte. Ihre Logik ist mit Fakes getestet.

Erkenntnisse, die das Verhalten bestimmen:

- Android schneidet Daten über 1015 Bytes in Pakete, auch mitten in
  UMP-Wörtern; das Backend teilt UMP-Daten selbst, zwischen Paketen.
- Ein `MidiDeviceService` bekommt den Zeitstempel, aber niemand plant für
  ihn; nur USB- und Bluetooth-Geräte liegen hinter dem Scheduler des
  MIDI-Dienstes.
- Die `ServiceInfo` eines virtuellen Geräts liegt unter dem versteckten
  Property-Schlüssel `service_info`; der Shim liest sie, um die eigenen
  Geräte der App zu erkennen.
- package:jni findet die Shim-Klassen auch aus Hintergrund-Isolates ohne
  weitere Einrichtung; ein Classloader-Umweg ist nicht nötig.

## Installation

```bash
dart pub add aud_midi_android
```

Das Paket ist ein Android-Plugin ohne Flutter-Abhängigkeit: Flutter baut
den Java-Shim in die App und die native Tap-Bibliothek über den Build-Hook
des Pakets (`hook/build.dart`, NDK), R8 behält den Shim über die
`consumer-rules.pro`. `minSdk` 24; AMidi wird ab API 29 genutzt, UMP-Geräte erscheinen ab
API 33.

Die App deklariert in `AndroidManifest.xml`:

```xml
<uses-feature android:name="android.software.midi" android:required="true" />
<!-- Bluetooth LE MIDI -->
<uses-feature android:name="android.hardware.bluetooth_le" android:required="false" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
<!-- Netzwerk-Sessions -->
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
```

Die Laufzeit-Berechtigungen fordert die App selbst an: `BLUETOOTH_SCAN` und
`BLUETOOTH_CONNECT` ab API 31, `ACCESS_FINE_LOCATION` darunter.

Ein virtuelles Gerät der App, innerhalb von `<application>`:

```xml
<service
    android:name="com.audanika.aud_midi_android.AudMidiDeviceService"
    android:permission="android.permission.BIND_MIDI_DEVICE_SERVICE"
    android:exported="true">
    <intent-filter>
        <action android:name="android.media.midi.MidiDeviceService" />
    </intent-filter>
    <meta-data
        android:name="android.media.midi.MidiDeviceService"
        android:resource="@xml/midi_device_info" />
</service>
```

mit `res/xml/midi_device_info.xml`:

```xml
<devices>
  <device manufacturer="Meine Firma" product="Meine App">
    <input-port name="Meine App in" />
    <output-port name="Meine App out" />
  </device>
</devices>
```

Ein UMP-Gerät (API 33) nutzt `AudMidiUmpDeviceService` mit der Aktion
`android.media.midi.MidiUmpDeviceService`, einer `<property>` statt
`<meta-data>` und Einträgen `<port name="…" />`. Mehrere Geräte brauchen je
eine Unterklasse.

## Dokumentation

- [Der Plan der aud_midi-Familie](https://github.com/audmidi/aud_midi_pm/blob/main/doc/2026-Q4/tickets/2026-10-06-aud_midi_01-initial-midi-implementation.md)
- [Beispiel-App](example/README.md)
- [Guides](doc/guides/)

## Code-Beispiele

```dart
import 'package:aud_midi_android/aud_midi_android.dart';
import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

// Läuft in einem Isolate einer Android-App, z. B. dem MIDI-Isolate.
Future<void> main() async {
  final engine = MidiEngine(backend: AndroidMidiBackend());
  await engine.open();
  for (final port in engine.outputs) {
    final output = await engine.openOutput(port.id);
    await output.send(const MidiNoteOn(channel: 0, note: 60, velocity: 100));
  }
  await engine.close();

  final registration = await MidiAndroidServiceAdvertiser().register(
    name: 'Meine Session',
    type: '_apple-midi._udp',
    port: 5004,
  );
  await registration.unregister();
}
```

## Bindings neu erzeugen

Die Bindings sind erzeugte Dateien in `lib/src/**/*.g.dart`. Nach einer
Änderung am Java-Shim, an `jnigen.yaml` oder `ffigen.yaml`:

```bash
# jnigen: android.media.midi, Bluetooth, NsdManager, WifiManager, der Shim
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
dart run jnigen:setup            # einmal: baut den API-Summarizer
dart run jnigen --config jnigen.yaml

# ffigen: AMidi aus dem NDK
NDK="$ANDROID_SDK_ROOT/ndk/28.2.13676358"
SYSROOT="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot"
dart run ffigen --config ffigen.yaml \
  --compiler-opts "--target=aarch64-linux-android33 --sysroot=$SYSROOT"

# ffigen: die native Tap-Bibliothek
dart run ffigen --config ffigen_tap.yaml
```

Die native Tap-Bibliothek hat einen Test auf dem Entwicklungsrechner,
`node scripts/test-native.js`, unter ASan/UBSan, ThreadSanitizer und, mit
LLVM aus Homebrew, RealtimeSanitizer; `node scripts/check-notices.js` prüft
die Lizenz-Header und `NOTICES.md`.

Beide nutzen das Dart des Flutter-SDK (package:jni braucht es) und
erzeugen dieselben Dateien erneut.

## Funktionsweise

- Dart spricht mit Android nur über `MidiAndroidPlatform`. Dessen
  JNI-Implementierung und der AMidi-Kleber sind dünn und laufen nur auf
  Android; alles andere ist reines Dart, auf dem Entwicklungsrechner mit
  Fakes getestet.
- Java-Threads warten nie auf Dart: die Callbacks des Shims sind Listener,
  die an den Port des Isolates posten und zurückkehren.
- Empfang: MIDI-Thread → `AudMidiReceiver.onSend` kopiert → ein Signal →
  das Isolate leert den Puffer → Dekodieren → Port-Pakete mit Zeiten.
- Native Taps: MIDI-Thread → `AudMidiReceiver.onSend` →
  `AudMidiNativeTap.send` (JNI) → der Slot der Tap-Bibliothek → der
  C-Konsument; `AudMidiDeviceCallback.onDeviceRemoved` →
  `AudMidiNativeTap.gone`.
- Senden: Paketzeit → `CLOCK_MONOTONIC` über den Clock-Mapper → AMidi oder
  `MidiInputPort` mit diesem Zeitstempel.

## Mitwirken

Siehe [doc/guides/develop-guide.md](doc/guides/develop-guide.md).
