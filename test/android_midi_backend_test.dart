// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:typed_data';

import 'package:aud_midi_android/aud_midi_android.dart';
import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

void main() {
  const input = MidiAndroidPortDescription.typeInput;
  const output = MidiAndroidPortDescription.typeOutput;
  const usb = MidiAndroidDeviceDescription(
    id: 7,
    type: MidiAndroidDeviceDescription.typeUsb,
    name: 'Keys',
    manufacturer: 'Acme',
    ports: [
      MidiAndroidPortDescription(type: input, number: 0),
      MidiAndroidPortDescription(type: output, number: 0),
    ],
  );
  const ump = MidiAndroidDeviceDescription(
    id: 9,
    type: MidiAndroidDeviceDescription.typeUsb,
    transport: MidiAndroidDeviceDescription.transportUmp,
    defaultProtocol: MidiAndroidDeviceDescription.protocolMidi2,
    name: 'Synth 2',
    ports: [
      MidiAndroidPortDescription(type: input, number: 0),
      MidiAndroidPortDescription(type: output, number: 0),
    ],
  );
  const own = MidiAndroidDeviceDescription(
    id: 3,
    type: MidiAndroidDeviceDescription.typeVirtual,
    name: 'Mine',
    ownService: 'com.example.Service',
    ports: [
      MidiAndroidPortDescription(type: input, number: 0, name: 'in'),
      MidiAndroidPortDescription(type: output, number: 0, name: 'out'),
    ],
  );
  const usbIn = MidiPortId('android:7:in:0');
  const usbOut = MidiPortId('android:7:out:0');
  const umpIn = MidiPortId('android:9:in:0');
  const umpOut = MidiPortId('android:9:out:0');
  const ownIn = MidiPortId('android:own:com.example.Service:in:0');
  const ownOut = MidiPortId('android:own:com.example.Service:out:0');

  late _FakePlatform platform;
  late _FakeHost host;
  late AndroidMidiBackend backend;
  late _FakeDevice usbDevice;
  late _FakeDevice umpDevice;

  // Builds what AudMidiReceiver.drain() returns.
  Uint8List drained(List<(int, List<int>)> chunks, {int dropped = 0}) {
    final builder = BytesBuilder()
      ..add((ByteData(4)..setInt32(0, dropped)).buffer.asUint8List());
    for (final (timestamp, bytes) in chunks) {
      builder
        ..add(
          (ByteData(12)
                ..setInt64(0, timestamp)
                ..setInt32(8, bytes.length))
              .buffer
              .asUint8List(),
        )
        ..add(bytes);
    }
    return builder.toBytes();
  }

  Future<void> start({
    int sdkInt = 36,
    List<MidiAndroidDeviceDescription> devices = const [usb, ump, own],
    MidiAndroidBleScanner? scanner,
  }) async {
    platform = _FakePlatform(
      sdkInt: sdkInt,
      devices: devices,
      scanner: scanner,
    );
    platform.openers[7] = () async => usbDevice;
    platform.openers[9] = () async => umpDevice;
    backend = AndroidMidiBackend(platform: platform);
    await backend.start(host);
  }

  setUp(() {
    host = _FakeHost();
    usbDevice = _FakeDevice(usb);
    umpDevice = _FakeDevice(ump);
  });

  group('AndroidMidiBackend', () {
    group('start(host)', () {
      test('enumerates the ports of all devices', () async {
        await start();
        expect(backend.ports, [
          for (final device in [usb, ump, own])
            ...const MidiAndroidPortMapper().ports(device),
        ]);
        expect(backend.ports.map((port) => port.id).toList(), [
          usbOut,
          usbIn,
          umpOut,
          umpIn,
          ownIn,
          ownOut,
        ]);
        expect(platform.added, isNotNull);
        expect(host.events, isEmpty);
      });

      test('throws MidiUnsupported without android.software.midi', () {
        backend = AndroidMidiBackend(platform: _FakePlatform(hasMidi: false));
        expect(
          () => backend.start(host),
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              'MIDI without android.software.midi',
            ),
          ),
        );
      });

      test('throws MidiUnsupported outside Android', () {
        expect(
          () => AndroidMidiBackend().start(host),
          throwsA(isA<MidiUnsupported>()),
        );
      });

      test('throws a StateError when started twice', () async {
        await start();
        expect(() => backend.start(host), throwsA(isA<StateError>()));
      });

      test('offers Bluetooth only with a scanner', () async {
        await start();
        expect(backend.bluetooth, isNull);
        await start(scanner: _FakeScanner());
        expect(backend.bluetooth, isA<MidiAndroidBluetooth>());
      });
    });

    group('stop()', () {
      test('does nothing before start', () async {
        await AndroidMidiBackend(platform: _FakePlatform()).stop();
      });

      test('closes ports and devices and releases the platform', () async {
        final scanner = _FakeScanner();
        await start(scanner: scanner);
        await backend.openPort(usbIn);
        await backend.openPort(usbOut);
        await backend.openPort(ownIn);
        platform.granted.add('android.permission.BLUETOOTH_SCAN');
        unawaited(backend.bluetooth!.scan().drain<void>());
        await backend.stop();
        expect(usbDevice.receivers[0]!.closed, isTrue);
        expect(usbDevice.senders[0]!.closed, isTrue);
        expect(
          platform.virtualInputs[('com.example.Service', 0)]!.closed,
          isTrue,
        );
        expect(usbDevice.closes, 1);
        expect(scanner.stops, 1);
        expect(platform.added, isNull);
        expect(platform.disposals, 1);
        expect(backend.ports, isEmpty);
        expect(backend.bluetooth, isNull);
        expect(backend.capabilities, const MidiCapabilities.none());
      });
    });

    group('openPort(port)', () {
      test('opens an input on the output port of the device', () async {
        await start();
        await backend.openPort(usbIn);
        expect(platform.openedIds, [7]);
        expect(usbDevice.receivers.keys, [0]);
      });

      test('sends through AMidi from API 29', () async {
        await start(sdkInt: 29);
        await backend.openPort(usbOut);
        expect(backend.sendPath(usbOut), MidiAndroidSender.amidi);
      });

      test('sends through MidiInputPort below API 29', () async {
        await start(sdkInt: 28);
        await backend.openPort(usbOut);
        expect(backend.sendPath(usbOut), MidiAndroidSender.java);
      });

      test('falls back to MidiInputPort when AMidi fails', () async {
        usbDevice = _FakeDevice(usb, native: false);
        await start();
        await backend.openPort(usbOut);
        expect(backend.sendPath(usbOut), MidiAndroidSender.java);
        expect(host.diagnostics.single.kind, MidiDiagnosticKind.nativeError);
        expect(host.diagnostics.single.port, usbOut);
      });

      test('throws MidiNativeError when no input port opens', () async {
        usbDevice = _FakeDevice(usb, native: false, java: false);
        await start();
        await expectLater(
          backend.openPort(usbOut),
          throwsA(
            isA<MidiNativeError>()
                .having((e) => e.api, 'api', 'MidiDevice.openInputPort')
                .having(
                  (e) => e.code,
                  'code',
                  MidiAndroidErrorCodes.unavailable,
                ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(usbDevice.closes, 1);
      });

      test('throws MidiNativeError when no output port opens', () async {
        usbDevice = _FakeDevice(usb, outputs: false);
        await start();
        await expectLater(
          backend.openPort(usbIn),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.api,
              'api',
              'MidiDevice.openOutputPort',
            ),
          ),
        );
      });

      test('throws MidiNativeError when the device does not open', () async {
        await start();
        platform.openers[7] = () async => null;
        await expectLater(
          backend.openPort(usbIn),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.api,
              'api',
              'MidiManager.openDevice',
            ),
          ),
        );
        platform.openers[7] = () async => usbDevice;
        await backend.openPort(usbIn);
        expect(platform.openedIds, [7, 7]);
      });

      test('throws MidiPortGone for an unknown port', () async {
        await start();
        await expectLater(
          backend.openPort(const MidiPortId('android:1:in:0')),
          throwsA(isA<MidiPortGone>()),
        );
      });

      test('throws MidiPortGone when the device leaves meanwhile', () async {
        await start();
        final opened = Completer<MidiAndroidDevice?>();
        platform.openers[7] = () => opened.future;
        final opening = backend.openPort(usbIn);
        await Future<void>.delayed(Duration.zero);
        platform.removed!(7);
        opened.complete(usbDevice);
        await expectLater(opening, throwsA(isA<MidiPortGone>()));
        await Future<void>.delayed(Duration.zero);
        expect(usbDevice.closes, 1);
      });

      test('throws a StateError before start', () {
        expect(
          () => AndroidMidiBackend(platform: _FakePlatform()).openPort(usbIn),
          throwsA(isA<StateError>()),
        );
      });

      test('opens a port once and a device once', () async {
        await start();
        await Future.wait([
          backend.openPort(usbIn),
          backend.openPort(usbIn),
          backend.openPort(usbOut),
        ]);
        await backend.openPort(usbIn);
        expect(platform.openedIds, [7]);
        expect(usbDevice.receivers.keys, [0]);
        expect(usbDevice.senders.keys, [0]);
      });

      test('opens the ports of the own virtual device', () async {
        await start();
        await backend.openPort(ownIn);
        await backend.openPort(ownOut);
        expect(platform.openedIds, isEmpty);
        expect(platform.virtualInputs.keys, [('com.example.Service', 0)]);
        expect(backend.sendPath(ownOut), MidiAndroidSender.virtual);
      });
    });

    group('closePort(port)', () {
      test('closes the device with its last port', () async {
        await start();
        await backend.openPort(usbIn);
        await backend.openPort(usbOut);
        await backend.closePort(usbIn);
        expect(usbDevice.receivers[0]!.closed, isTrue);
        expect(usbDevice.closes, 0);
        await backend.closePort(usbOut);
        await Future<void>.delayed(Duration.zero);
        expect(usbDevice.senders[0]!.closed, isTrue);
        expect(usbDevice.closes, 1);
      });

      test('ignores a port that is not open', () async {
        await start();
        await backend.closePort(usbIn);
      });

      test('closes own virtual ports without a device', () async {
        await start();
        await backend.openPort(ownIn);
        await backend.openPort(ownOut);
        await backend.closePort(ownIn);
        await backend.closePort(ownOut);
        expect(platform.virtualInputs.values.single.closed, isTrue);
        expect(platform.virtualOutputs.values.single.closed, isTrue);
      });
    });

    group('send(port, packet)', () {
      test('sends bytes due at the time of the packet', () async {
        await start();
        await backend.openPort(usbOut);
        // Package time 6000 is native 2000 (offset 4000), after now 1000.
        await backend.send(
          usbOut,
          MidiBytesPacket(
            bytes: MidiBytes.fromHex('90 3c 64'),
            time: const MidiTime(6000),
          ),
        );
        expect(usbDevice.senders[0]!.chunks, [
          [
            [0x90, 0x3c, 0x64],
            2000000,
          ],
        ]);
      });

      test('sends a packet that is due already now', () async {
        await start();
        await backend.openPort(usbOut);
        await backend.send(
          usbOut,
          MidiBytesPacket(bytes: MidiBytes.fromHex('f8'), time: MidiTime.zero),
        );
        expect(usbDevice.senders[0]!.chunks, [
          [
            [0xf8],
            1000000,
          ],
        ]);
      });

      test('sends UMP words big-endian in chunks', () async {
        await start();
        await backend.openPort(umpOut);
        final words = [for (var i = 0; i < 300; i++) 0x40903c00 | i];
        await backend.send(
          umpOut,
          MidiUmpPacket(words: words, time: const MidiTime(6000)),
        );
        // 126 packets of two words fill 1008 of the 1012 bytes of a chunk.
        final sent = umpDevice.senders[0]!.sent;
        expect(sent.map((chunk) => chunk.bytes.length).toList(), [1008, 192]);
        expect(sent.first.bytes.sublist(0, 4), [0x40, 0x90, 0x3c, 0x00]);
        expect(sent.last.timestamp, 2000000);
      });

      test('throws an ArgumentError for the wrong packet type', () async {
        await start();
        await backend.openPort(usbOut);
        await backend.openPort(umpOut);
        await expectLater(
          backend.send(usbOut, MidiUmpPacket(words: [0], time: MidiTime.zero)),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              'The port takes bytes',
            ),
          ),
        );
        await expectLater(
          backend.send(
            umpOut,
            MidiBytesPacket(bytes: MidiBytes.empty, time: MidiTime.zero),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              'The port takes UMP packets',
            ),
          ),
        );
      });

      test('throws MidiPortGone for an unknown port', () async {
        await start();
        await expectLater(
          backend.send(
            const MidiPortId('android:1:out:0'),
            MidiBytesPacket(bytes: MidiBytes.empty, time: MidiTime.zero),
          ),
          throwsA(isA<MidiPortGone>()),
        );
      });

      test('throws a StateError for a port that is not open', () async {
        await start();
        await expectLater(
          backend.send(
            usbOut,
            MidiBytesPacket(bytes: MidiBytes.empty, time: MidiTime.zero),
          ),
          throwsA(isA<StateError>()),
        );
      });

      test('measures the clock offset again when it is due', () async {
        await start();
        await backend.openPort(usbOut);
        platform.nowMicros = 2000;
        host.clock.advance(const Duration(seconds: 9));
        await backend.send(
          usbOut,
          MidiBytesPacket(bytes: MidiBytes.fromHex('f8'), time: MidiTime.zero),
        );
        host.clock.advance(const Duration(seconds: 1));
        await backend.send(
          usbOut,
          MidiBytesPacket(
            bytes: MidiBytes.fromHex('f8'),
            time: host.clock.now() + const Duration(microseconds: 10),
          ),
        );
        expect(usbDevice.senders[0]!.sent.map((s) => s.timestamp).toList(), [
          2000000,
          2010000,
        ]);
      });
    });

    group('cancelPending(port)', () {
      test('flushes the sender of the port', () async {
        await start();
        await backend.openPort(usbOut);
        await backend.cancelPending(usbOut);
        expect(usbDevice.senders[0]!.flushes, 1);
      });
    });

    group('sendPath(port)', () {
      test('is null for a port that is not open', () async {
        await start();
        expect(backend.sendPath(usbOut), isNull);
      });
    });

    group('receiving', () {
      test('delivers bytes with the Android timestamps', () async {
        await start();
        await backend.openPort(usbIn);
        usbDevice.receivers[0]!.push(
          drained([
            (2000000, [0x90, 0x3c, 0x64]),
            (2500000, [0x80, 0x3c, 0x00]),
          ]),
        );
        expect(host.packets, [
          (
            usbIn,
            MidiBytesPacket(
              bytes: MidiBytes.fromHex('90 3c 64'),
              time: const MidiTime(6000),
            ),
          ),
          (
            usbIn,
            MidiBytesPacket(
              bytes: MidiBytes.fromHex('80 3c 00'),
              time: const MidiTime(6500),
            ),
          ),
        ]);
      });

      test('assembles UMP words across chunks', () async {
        await start();
        await backend.openPort(umpIn);
        umpDevice.receivers[0]!
          ..push(
            drained([
              (2000000, [0x40, 0x90, 0x3c, 0x00, 0xc0]),
            ]),
          )
          ..push(
            drained([
              (3000000, [0x00, 0x00, 0x00]),
            ]),
          );
        expect(host.packets, [
          (
            umpIn,
            MidiUmpPacket(
              words: [0x40903c00, 0xc0000000],
              time: const MidiTime(7000),
            ),
          ),
        ]);
      });

      test('reports dropped chunks and resets the assembler', () async {
        await start();
        await backend.openPort(umpIn);
        umpDevice.receivers[0]!.push(
          drained([
            (2000000, [0x40, 0x90]),
          ], dropped: 3),
        );
        umpDevice.receivers[0]!.push(
          drained([
            (2000000, [0x20, 0x90, 0x3c, 0x64]),
          ]),
        );
        expect(host.diagnostics.single.kind, MidiDiagnosticKind.queueOverflow);
        expect(host.diagnostics.single.count, 3);
        expect(host.diagnostics.single.port, umpIn);
        expect(host.packets.single.$2, isA<MidiUmpPacket>());
        expect((host.packets.single.$2 as MidiUmpPacket).words, [0x20903c64]);
      });

      test('reports dropped chunks of a byte port', () async {
        await start();
        await backend.openPort(usbIn);
        usbDevice.receivers[0]!.push(drained(const [], dropped: 1));
        expect(host.diagnostics.single.kind, MidiDiagnosticKind.queueOverflow);
      });

      test('reports truncated data', () async {
        await start();
        await backend.openPort(usbIn);
        usbDevice.receivers[0]!.push(Uint8List.fromList([0, 0]));
        expect(host.diagnostics.single.kind, MidiDiagnosticKind.invalidData);
        expect(host.packets, isEmpty);
      });

      test('ignores a signal without data and one after close', () async {
        await start();
        await backend.openPort(usbIn);
        final receiver = usbDevice.receivers[0]!..onData();
        await backend.closePort(usbIn);
        receiver.push(
          drained([
            (2000000, [0xf8]),
          ]),
        );
        expect(host.packets, isEmpty);
      });

      test('delivers on own virtual inputs', () async {
        await start();
        await backend.openPort(ownIn);
        platform.virtualInputs[('com.example.Service', 0)]!.push(
          drained([
            (2000000, [0xf8]),
          ]),
        );
        expect(host.packets.single.$1, ownIn);
      });
    });

    group('supportsNativeTap, attachNativeTap, detachNativeTap', () {
      const tap = MidiNativeTap(function: 0x100, user: 0x200);

      test('open the port for the tap and close it after the detach', () async {
        await start();
        expect(backend.supportsNativeTap(usbIn), isTrue);
        expect(backend.supportsNativeTap(usbOut), isFalse);
        expect(
          backend.supportsNativeTap(const MidiPortId('android:x')),
          isFalse,
        );
        await backend.attachNativeTap(usbIn, tap);
        final receiver = usbDevice.receivers[0]!;
        expect(receiver.tapCalls, ['attach 256 512 ump=false']);
        expect(receiver.nativeTap, tap);
        await backend.closePort(usbIn);
        expect(receiver.closed, isFalse);
        await backend.detachNativeTap(usbIn);
        await backend.detachNativeTap(usbIn);
        expect(receiver.tapCalls, ['attach 256 512 ump=false', 'detach']);
        expect(receiver.closed, isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(usbDevice.closes, 1);
      });

      test('keep a port a listener opened', () async {
        await start();
        await backend.openPort(umpIn);
        await backend.attachNativeTap(umpIn, tap);
        final receiver = umpDevice.receivers[0]!;
        expect(receiver.tapCalls, ['attach 256 512 ump=true']);
        await backend.detachNativeTap(umpIn);
        expect(receiver.closed, isFalse);
        await backend.closePort(umpIn);
        expect(receiver.closed, isTrue);
      });

      test('keep a port a listener opens after the tap', () async {
        await start();
        await backend.attachNativeTap(usbIn, tap);
        await backend.openPort(usbIn);
        await backend.detachNativeTap(usbIn);
        final receiver = usbDevice.receivers[0]!;
        expect(receiver.closed, isFalse);
        await backend.closePort(usbIn);
        expect(receiver.closed, isTrue);
      });

      test('throw for unknown ports, outputs and a second tap', () async {
        await start();
        const unknown = MidiPortId('android:x');
        await expectLater(
          backend.attachNativeTap(unknown, tap),
          throwsA(isA<MidiPortGone>()),
        );
        await expectLater(
          backend.detachNativeTap(unknown),
          throwsA(isA<MidiPortGone>()),
        );
        await expectLater(
          backend.attachNativeTap(usbOut, tap),
          throwsA(isA<ArgumentError>()),
        );
        await backend.attachNativeTap(usbIn, tap);
        await expectLater(
          backend.attachNativeTap(usbIn, tap),
          throwsA(isA<StateError>()),
        );
        expect(() => backend.attachNativeTap(usbIn, tap), throwsStateError);
      });

      test('throw what the receiver throws and keep the port open', () async {
        await start();
        await backend.openPort(usbIn);
        const error = MidiNativeError(api: 'tap', code: 1);
        usbDevice.receivers[0]!.attachError = error;
        await expectLater(
          backend.attachNativeTap(usbIn, tap),
          throwsA(same(error)),
        );
        expect(usbDevice.receivers[0]!.closed, isFalse);
        await backend.detachNativeTap(usbIn);
      });

      test('race a device that leaves while the port opens', () async {
        await start();
        final opening = backend.attachNativeTap(usbIn, tap);
        platform.removed!(7);
        await expectLater(opening, throwsA(isA<MidiPortGone>()));
      });

      test('throw a StateError before start', () {
        backend = AndroidMidiBackend(platform: _FakePlatform());
        expect(() => backend.attachNativeTap(usbIn, tap), throwsStateError);
      });

      test('detach with the receiver of a removed device', () async {
        await start();
        await backend.attachNativeTap(usbIn, tap);
        platform.removed!(7);
        final receiver = usbDevice.receivers[0]!;
        expect(receiver.tapCalls, ['attach 256 512 ump=false', 'detach']);
        expect(receiver.closed, isTrue);
        await expectLater(
          backend.detachNativeTap(usbIn),
          throwsA(isA<MidiPortGone>()),
        );
      });

      test('drop the data of a port open for its tap only', () async {
        await start();
        await backend.attachNativeTap(usbIn, tap);
        final receiver = usbDevice.receivers[0]!;
        receiver.push(
          drained([
            (5, [0xf8]),
          ]),
        );
        expect(host.packets, isEmpty);
        await backend.openPort(usbIn);
        receiver.push(
          drained([
            (5, [0xf8]),
          ]),
        );
        expect(host.packets, hasLength(1));
      });

      test('detach on stop', () async {
        await start();
        await backend.attachNativeTap(ownIn, tap);
        await backend.stop();
        expect(platform.virtualInputs.values.single.tapCalls, [
          'attach 256 512 ump=false',
          'detach',
        ]);
      });
    });

    group('hotplug', () {
      test('reports added devices and measures the clock again', () async {
        await start(devices: const []);
        platform.nowMicros = 3000;
        platform.added!(usb);
        expect(host.events.map((e) => e.runtimeType).toList(), [
          MidiPortAdded,
          MidiPortAdded,
        ]);
        await backend.openPort(usbOut);
        await backend.send(
          usbOut,
          MidiBytesPacket(bytes: MidiBytes.fromHex('f8'), time: MidiTime.zero),
        );
        expect(usbDevice.senders[0]!.sent.single.timestamp, 3000000);
      });

      test('reports nothing for a device known already', () async {
        await start();
        platform.added!(usb);
        expect(host.events, isEmpty);
      });

      test('closes the ports of a removed device', () async {
        await start();
        await backend.openPort(usbIn);
        await backend.openPort(usbOut);
        await backend.openPort(umpIn);
        platform.removed!(7);
        await Future<void>.delayed(Duration.zero);
        expect(host.events.map((e) => e.port.id).toList(), [usbOut, usbIn]);
        expect(host.events.every((e) => e is MidiPortRemoved), isTrue);
        expect(usbDevice.receivers[0]!.closed, isTrue);
        expect(usbDevice.senders[0]!.closed, isTrue);
        expect(usbDevice.closes, 1);
        expect(umpDevice.receivers[0]!.closed, isFalse);
        await expectLater(
          backend.send(
            usbOut,
            MidiBytesPacket(bytes: MidiBytes.empty, time: MidiTime.zero),
          ),
          throwsA(isA<MidiPortGone>()),
        );
      });

      test('ignores the removal of a device that is not open', () async {
        await start();
        platform.removed!(9);
        expect(host.events.length, 2);
      });

      test('ignores notifications after stop', () async {
        await start();
        final added = platform.added!;
        final removed = platform.removed!;
        await backend.stop();
        added(usb);
        removed(7);
        expect(host.events, isEmpty);
      });
    });

    group('capabilities', () {
      test('are none before start', () {
        expect(
          AndroidMidiBackend(platform: _FakePlatform()).capabilities,
          const MidiCapabilities.none(),
        );
      });

      test('describe Android after start', () async {
        await start(scanner: _FakeScanner());
        platform.granted.addAll([
          'android.permission.BLUETOOTH_SCAN',
          'android.permission.BLUETOOTH_CONNECT',
        ]);
        expect(
          backend.capabilities,
          MidiCapabilities(
            virtualPorts: MidiVirtualPortSupport.staticPorts,
            bleScan: true,
            ump: true,
            scheduling: MidiSchedulingSupport.hardware,
            missingPermissions: {MidiPermission.localNetwork},
          ),
        );
      });

      test('have no UMP below API 33', () async {
        await start(sdkInt: 32);
        expect(backend.capabilities.ump, isFalse);
      });
    });

    group('devices', () {
      test('maps the known devices', () async {
        await start(devices: const [usb]);
        expect(backend.devices, [const MidiAndroidPortMapper().device(usb)]);
      });
    });

    group('name, network, virtualPorts', () {
      test('describe the backend', () async {
        await start();
        expect(backend.name, 'android');
        expect(backend.network, isNull);
        expect(backend.resyncInterval, const Duration(seconds: 10));
        final port = await backend.virtualPorts.create(
          MidiVirtualPortSpec(name: 'out', direction: MidiDirection.output),
        );
        expect(port.id, ownOut);
        await backend.openPort(ownOut);
        await backend.virtualPorts.remove(ownOut);
        expect(backend.sendPath(ownOut), isNull);
      });
    });

    group('bluetooth', () {
      const address = 'AA:BB:CC:DD:EE:FF';
      const ble = MidiAndroidDeviceDescription(
        id: 11,
        type: MidiAndroidDeviceDescription.typeBluetooth,
        name: 'BLE Keys',
        bluetoothAddress: address,
        ports: [
          MidiAndroidPortDescription(type: input, number: 0),
          MidiAndroidPortDescription(type: output, number: 0),
        ],
      );
      const bleIn = MidiPortId('android:11:in:0');

      late _FakeDevice bleDevice;
      late MidiBluetoothBackend bluetooth;

      Future<void> startBluetooth() async {
        bleDevice = _FakeDevice(ble);
        await start(scanner: _FakeScanner());
        platform
          ..granted.add('android.permission.BLUETOOTH_CONNECT')
          ..bluetoothOpeners[address] = () async => bleDevice;
        bluetooth = backend.bluetooth!;
      }

      test('connect() opens the peripheral and returns its ports', () async {
        await startBluetooth();
        final ports = await bluetooth.connect(address);
        expect(ports.map((port) => port.id).toList(), [
          const MidiPortId('android:11:out:0'),
          bleIn,
        ]);
        expect(host.events.length, 2);
        expect(await bluetooth.connect(address), ports);
        await backend.openPort(bleIn);
        await backend.closePort(bleIn);
        await Future<void>.delayed(Duration.zero);
        expect(bleDevice.closes, 0);
      });

      test('connect() keeps a device opened through its ports', () async {
        await startBluetooth();
        final throughPort = _FakeDevice(ble);
        platform
          ..deviceList.add(ble)
          ..openers[11] = () async => throughPort;
        platform.added!(ble);
        await backend.openPort(bleIn);
        await bluetooth.connect(address);
        expect(bleDevice.closes, 1);
        await backend.closePort(bleIn);
        await Future<void>.delayed(Duration.zero);
        expect(throughPort.closes, 0);
      });

      test('connect() throws when Android cannot open it', () async {
        await startBluetooth();
        platform.bluetoothOpeners[address] = () async => null;
        await expectLater(
          bluetooth.connect(address),
          throwsA(
            isA<MidiNativeError>()
                .having((e) => e.api, 'api', 'MidiManager.openBluetoothDevice')
                .having(
                  (e) => e.code,
                  'code',
                  MidiAndroidErrorCodes.unavailable,
                ),
          ),
        );
      });

      test('connect() times out and closes a late device', () async {
        await startBluetooth();
        final opened = Completer<MidiAndroidDevice?>();
        platform.bluetoothOpeners[address] = () => opened.future;
        await expectLater(
          bluetooth.connect(address, timeout: Duration.zero),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.code,
              'code',
              MidiAndroidErrorCodes.timeout,
            ),
          ),
        );
        opened.complete(bleDevice);
        await Future<void>.delayed(Duration.zero);
        expect(bleDevice.closes, 1);
      });

      test('connect() throws a StateError after stop', () async {
        await startBluetooth();
        await backend.stop();
        await expectLater(
          bluetooth.connect(address),
          throwsA(isA<StateError>()),
        );
      });

      test('disconnect() closes the peripheral and its ports', () async {
        await startBluetooth();
        await bluetooth.connect(address);
        await backend.openPort(bleIn);
        await bluetooth.disconnect(address);
        await bluetooth.disconnect('unknown');
        await Future<void>.delayed(Duration.zero);
        expect(bleDevice.receivers[0]!.closed, isTrue);
        expect(bleDevice.closes, 1);
        expect(host.events.whereType<MidiPortRemoved>().length, 2);
      });

      test('stop() closes a connected peripheral', () async {
        await startBluetooth();
        await bluetooth.connect(address);
        await backend.stop();
        expect(bleDevice.closes, 1);
      });

      test('reports a failed scan as a diagnostic', () async {
        final scanner = _FakeScanner();
        await start(scanner: scanner);
        platform.granted.add('android.permission.BLUETOOTH_SCAN');
        final scan = backend.bluetooth!.scan().toList();
        scanner.onFailed!(2);
        expect(await scan, isEmpty);
        expect(host.diagnostics.single.kind, MidiDiagnosticKind.nativeError);
        expect(
          host.diagnostics.single.cause,
          'The Bluetooth LE scan failed with error 2',
        );
      });
    });
  });
}

// #############################################################################
final class _FakeHost implements MidiBackendHost {
  @override
  final MidiFakeClock clock = MidiFakeClock(start: const MidiTime(5000));

  final List<MidiPortEvent> events = [];
  final List<(MidiPortId, MidiPacket)> packets = [];
  final List<MidiDiagnostic> diagnostics = [];

  @override
  void portsChanged(List<MidiPortEvent> events) => this.events.addAll(events);

  @override
  void received(MidiPortId port, MidiPacket packet) =>
      packets.add((port, packet));

  @override
  void diagnostic(MidiDiagnostic diagnostic) => diagnostics.add(diagnostic);
}

// #############################################################################
final class _FakePlatform implements MidiAndroidPlatform {
  _FakePlatform({
    this.sdkInt = 36,
    this.hasMidi = true,
    List<MidiAndroidDeviceDescription> devices = const [],
    MidiAndroidBleScanner? scanner,
  }) : deviceList = [...devices],
       bleScanner = scanner;

  @override
  final int sdkInt;

  @override
  final bool hasMidi;

  @override
  final MidiAndroidBleScanner? bleScanner;

  final List<MidiAndroidDeviceDescription> deviceList;
  final Map<int, Future<MidiAndroidDevice?> Function()> openers = {};
  final Map<String, Future<MidiAndroidDevice?> Function()> bluetoothOpeners =
      {};
  final List<int> openedIds = [];
  final Set<String> granted = {};
  final Map<(String, int), _FakeReceiver> virtualInputs = {};
  final Map<(String, int), _FakeSender> virtualOutputs = {};
  void Function(MidiAndroidDeviceDescription device)? added;
  void Function(int id)? removed;
  int nowMicros = 1000;
  int disposals = 0;

  @override
  List<MidiAndroidDeviceDescription> devices() => [...deviceList];

  @override
  void watchDevices({
    required void Function(MidiAndroidDeviceDescription device) onAdded,
    required void Function(int id) onRemoved,
  }) {
    added = onAdded;
    removed = onRemoved;
  }

  @override
  void unwatchDevices() {
    added = null;
    removed = null;
  }

  @override
  Future<MidiAndroidDevice?> openDevice(int id) {
    openedIds.add(id);
    return openers[id]!();
  }

  @override
  Future<MidiAndroidDevice?> openBluetoothDevice(String address) =>
      bluetoothOpeners[address]!();

  @override
  MidiAndroidReceiver openVirtualInput({
    required String service,
    required int port,
    required void Function() onData,
  }) => virtualInputs[(service, port)] = _FakeReceiver(onData);

  @override
  MidiAndroidSender openVirtualOutput({
    required String service,
    required int port,
  }) =>
      virtualOutputs[(service, port)] = _FakeSender(MidiAndroidSender.virtual);

  @override
  bool hasPermission(String permission) => granted.contains(permission);

  @override
  int monotonicMicros() => nowMicros;

  @override
  void dispose() => disposals++;
}

// #############################################################################
final class _FakeDevice implements MidiAndroidDevice {
  _FakeDevice(
    this.description, {
    this.native = true,
    this.java = true,
    this.outputs = true,
  });

  @override
  final MidiAndroidDeviceDescription description;

  final bool native;
  final bool java;
  final bool outputs;
  final Map<int, _FakeReceiver> receivers = {};
  final Map<int, _FakeSender> senders = {};
  int closes = 0;

  @override
  MidiAndroidReceiver? openOutputPort({
    required int port,
    required void Function() onData,
  }) => outputs ? receivers[port] = _FakeReceiver(onData) : null;

  @override
  MidiAndroidSender? openNativeInputPort(int port) =>
      native ? senders[port] = _FakeSender(MidiAndroidSender.amidi) : null;

  @override
  MidiAndroidSender? openJavaInputPort(int port) =>
      java ? senders[port] = _FakeSender(MidiAndroidSender.java) : null;

  @override
  void close() => closes++;
}

// #############################################################################
final class _FakeReceiver implements MidiAndroidReceiver {
  _FakeReceiver(this.onData);

  final void Function() onData;
  final List<Uint8List> queue = [];
  final List<String> tapCalls = [];
  bool closed = false;
  Object? attachError;

  void push(Uint8List data) {
    queue.add(data);
    onData();
  }

  @override
  Uint8List? drain() => queue.isEmpty ? null : queue.removeAt(0);

  @override
  void attachNativeTap(MidiNativeTap tap, {required bool ump}) {
    if (attachError case final error?) throw error;
    tapCalls.add('attach ${tap.function} ${tap.user} ump=$ump');
    nativeTap = tap;
  }

  @override
  void detachNativeTap() {
    if (nativeTap == null) return;
    tapCalls.add('detach');
    nativeTap = null;
  }

  @override
  MidiNativeTap? nativeTap;

  @override
  void close() {
    detachNativeTap();
    closed = true;
  }
}

// #############################################################################
final class _FakeSender implements MidiAndroidSender {
  _FakeSender(this.kind);

  @override
  final String kind;

  final List<({List<int> bytes, int timestamp})> sent = [];
  int flushes = 0;
  bool closed = false;

  @override
  void send(Uint8List data, {required int timestampNanos}) =>
      sent.add((bytes: data.toList(), timestamp: timestampNanos));

  /// The sent chunks as lists, which matchers compare deeply.
  List<List<Object>> get chunks => [
    for (final chunk in sent) [chunk.bytes, chunk.timestamp],
  ];

  @override
  void flush() => flushes++;

  @override
  void close() => closed = true;
}

// #############################################################################
final class _FakeScanner implements MidiAndroidBleScanner {
  void Function(int errorCode)? onFailed;
  int stops = 0;

  @override
  bool get isEnabled => true;

  @override
  void start({
    required void Function(MidiAndroidBleScanResult result) onResult,
    required void Function(int errorCode) onFailed,
  }) => this.onFailed = onFailed;

  @override
  void stop() => stops++;
}
