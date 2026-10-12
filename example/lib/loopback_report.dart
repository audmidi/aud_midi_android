// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The example pokes the native tap library of the package on purpose.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:aud_midi_android/aud_midi_android.dart';
import 'package:aud_midi_android/src/jni/midi_android_jni_bindings.g.dart'
    show AudMidiContext, AudMidiLoopbackService, AudMidiNativeTap;
import 'package:aud_midi_android/src/native/aud_midi_android_bindings.g.dart'
    as native;
import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:ffi/ffi.dart';
import 'package:jni/jni.dart';

/// Runs the checks of the example against the loopback devices declared in
/// the manifest and returns the report, one line per entry; [log] gets the
/// lines as they come.
///
/// Meant to run in a background isolate, like the MIDI isolate of aud_midi.
Future<List<String>> runLoopbackReport({
  void Function(String line)? log,
}) async {
  final report = _Report(log);
  _trace = log;
  final host = ReportHost();
  final backend = AndroidMidiBackend();
  try {
    await backend.start(host);
  } on MidiException catch (error) {
    return [...report..add('start failed: $error')];
  }
  report
    ..add('capabilities: ${backend.capabilities}')
    ..add('ports: ${backend.ports.length}');
  for (final port in backend.ports) {
    report.add(
      '  ${port.id} "${port.name}" ${port.direction.name} '
      '${port.transport.name} ${port.protocol.name} '
      'ump=${port.capabilities.ump} own=${port.isOwn} '
      'scheduled=${port.capabilities.scheduledSend}',
    );
  }
  await _check(report, 'native tap library', _nativeTapLibrary);
  await _check(report, 'native taps', () => _nativeTaps(backend, host));
  await _check(report, 'byte loopback', () => _byteLoopback(backend, host));
  await _check(report, 'UMP loopback', () => _umpLoopback(backend, host));
  await _check(report, 'virtual ports', () => _virtualPorts(backend, host));
  await _check(report, 'bluetooth', () => _bluetooth(backend));
  await _check(report, 'nsd', _advertise);
  await _check(report, 'multicast lock', _multicastLock);
  await _check(report, 'native tap gone', () => _nativeTapGone(backend, host));
  report.add('diagnostics: ${host.diagnostics}');
  await backend.stop();
  report.add('stopped');
  await _check(report, 'MidiEngine over AndroidMidiBackend', _engine);
  return [...report];
}

void Function(String line)? _trace;

// #############################################################################
/// The lines of the report, passed on to a log as they are added.
final class _Report extends Iterable<String> {
  _Report(this._log);

  final void Function(String line)? _log;
  final List<String> _lines = [];

  void add(String line) {
    _lines.add(line);
    _log?.call(line);
  }

  void addAll(Iterable<String> lines) => lines.forEach(add);

  @override
  Iterator<String> get iterator => _lines.iterator;
}

// #############################################################################
/// Collects what the backend reports.
final class ReportHost implements MidiBackendHost {
  @override
  final MidiClock clock = const MidiSystemClock();

  /// The packets per port with the time they arrived.
  final Map<MidiPortId, List<(MidiPacket, MidiTime)>> packets = {};

  /// The diagnostics.
  final List<MidiDiagnostic> diagnostics = [];

  /// The port events.
  final List<MidiPortEvent> events = [];

  @override
  void portsChanged(List<MidiPortEvent> events) => this.events.addAll(events);

  @override
  void received(MidiPortId port, MidiPacket packet) =>
      (packets[port] ??= []).add((packet, clock.now()));

  @override
  void diagnostic(MidiDiagnostic diagnostic) => diagnostics.add(diagnostic);

  /// Returns the bytes received on [port] in order.
  List<int> bytesOf(MidiPortId port) => [
    for (final (packet, _) in packets[port] ?? const <(MidiPacket, MidiTime)>[])
      if (packet is MidiBytesPacket) ...packet.bytes.bytes,
  ];

  /// Returns the UMP words received on [port] in order.
  List<int> wordsOf(MidiPortId port) => [
    for (final (packet, _) in packets[port] ?? const <(MidiPacket, MidiTime)>[])
      if (packet is MidiUmpPacket) ...packet.words,
  ];

  /// Waits until [done] holds or [timeout] passed.
  Future<void> waitFor(
    bool Function() done, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final end = clock.now() + timeout;
    while (!done() && clock.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
}

Future<void> _check(
  _Report report,
  String name,
  Future<List<String>> Function() check,
) async {
  report.add('$name:');
  try {
    report.addAll((await check()).map((line) => '  $line'));
  } on Object catch (error) {
    report.add('  failed: $error');
  }
}

/// The loading spike of ticket 26: can the Java shim load the library the
/// build hook built, and does Dart reach it through its code asset?
Future<List<String>> _nativeTapLibrary() async {
  final loaded = AudMidiNativeTap.load();
  final error = AudMidiNativeTap.loadError()?.toDartString(
    releaseOriginal: true,
  );
  return [
    'System.loadLibrary("aud_midi_android") from Java: $loaded'
        '${error == null ? '' : ' ($error)'}',
    'Dart code asset: ${native.aud_midi_android_tap_count()} taps, '
        'now ${native.aud_midi_android_now_ns()} ns',
  ];
}

// #############################################################################
/// The probe tap of the native tap library, read from Dart.
final class _Probe {
  _Probe()
    : pointer = native.aud_midi_android_probe_create(),
      _values = calloc<Int64>(native.AUD_MIDI_ANDROID_PROBE_VALUES);

  final Pointer<native.AudMidiAndroidProbe> pointer;
  final Pointer<Int64> _values;

  MidiNativeTap get tap => MidiNativeTap(
    function: native.aud_midi_android_probe_function().address,
    user: pointer.address,
  );

  /// UMP calls, byte calls, gone calls, words, bytes, last time, sum,
  /// first, overlaps, min delay.
  List<int> read() {
    native.aud_midi_android_probe_read(
      pointer,
      _values,
      native.AUD_MIDI_ANDROID_PROBE_VALUES,
    );
    return _values.asTypedList(native.AUD_MIDI_ANDROID_PROBE_VALUES).toList();
  }

  int get umpCalls => read()[0];
  int get byteCalls => read()[1];
  int get goneCalls => read()[2];
  int get words => read()[3];
  int get bytes => read()[4];
  int get lastTimeNs => read()[5];
  int get sum => read()[6];
  int get overlaps => read()[8];
  int get minDelayNs => read()[9];

  void free() {
    native.aud_midi_android_probe_free(pointer);
    calloc.free(_values);
  }
}

/// Native taps on the loopback inputs: the data reach the probe on the MIDI
/// thread without a Dart listener on the port, bytes on the MIDI 1.0 loop,
/// complete packets on the UMP loop, stamped with System.nanoTime().
Future<List<String>> _nativeTaps(
  AndroidMidiBackend backend,
  ReportHost host,
) async {
  final input = _port(backend, 'loop out', MidiDirection.input);
  final output = _port(backend, 'loop in', MidiDirection.output);
  final umpInput = _port(backend, 'ump loop', MidiDirection.input);
  final umpOutput = _port(backend, 'ump loop', MidiDirection.output);
  if (input == null ||
      output == null ||
      umpInput == null ||
      umpOutput == null) {
    return ['loopback devices not found'];
  }
  final lines = <String>[];
  final probe = _Probe();
  final umpProbe = _Probe();
  lines.add(
    'supportsNativeTap: in ${backend.supportsNativeTap(input.id)}, '
    'out ${backend.supportsNativeTap(output.id)}',
  );
  await backend.attachNativeTap(input.id, probe.tap);
  await backend.attachNativeTap(umpInput.id, umpProbe.tap);
  await backend.openPort(output.id);
  await backend.openPort(umpOutput.id);
  final messages = [
    MidiBytes.fromHex('90 3c 64'),
    MidiBytes.fromHex('b0 07 7f'),
    MidiBytes.fromHex('80 3c 00'),
  ];
  final sendTime = platformNowNs();
  for (final message in messages) {
    await backend.send(
      output.id,
      MidiBytesPacket(bytes: message, time: host.clock.now()),
    );
  }
  final sent = [for (final message in messages) ...message.bytes];
  await host.waitFor(() => probe.bytes >= sent.length);
  final sum = sent.fold<int>(0, (a, b) => a + b);
  lines.add(
    'bytes: ${probe.byteCalls} calls, ${probe.bytes} bytes '
    '(sent ${sent.length}), sum ok: ${probe.sum == sum}, '
    'overlaps ${probe.overlaps}',
  );
  lines.add(
    'bytes: last stamp minus send time ${(probe.lastTimeNs - sendTime) ~/ 1000} us, '
    'min stamp to tap delay ${probe.minDelayNs ~/ 1000} us (CLOCK_MONOTONIC)',
  );
  final words = [
    [0x40903c00, 0xc0000000],
    [0x20903c64],
    [0xf0000101, 0x0000001f, 0, 0],
  ];
  for (final packet in words) {
    await backend.send(
      umpOutput.id,
      MidiUmpPacket(words: packet, time: host.clock.now()),
    );
  }
  final wordCount = words.fold<int>(0, (a, b) => a + b.length);
  await host.waitFor(() => umpProbe.words >= wordCount);
  final wordSum = [for (final p in words) ...p].fold<int>(0, (a, b) => a + b);
  lines.add(
    'ump: ${umpProbe.umpCalls} calls, ${umpProbe.words} words '
    '(sent $wordCount), sum ok: ${umpProbe.sum == wordSum}, '
    'min stamp to tap delay ${umpProbe.minDelayNs ~/ 1000} us',
  );
  // No Dart listener: nothing reached the host.
  lines.add(
    'packets at the Dart host while only tapped: '
    '${(host.packets[input.id] ?? const []).length}',
  );
  // Detach under traffic: no call after the detach returned.
  var sending = true;
  final burst = () async {
    while (sending) {
      await backend.send(
        output.id,
        MidiBytesPacket(bytes: MidiBytes.fromHex('f8'), time: host.clock.now()),
      );
      await Future<void>.delayed(Duration.zero);
    }
  }();
  await Future<void>.delayed(const Duration(milliseconds: 50));
  await backend.detachNativeTap(input.id);
  final afterDetach = probe.byteCalls;
  await Future<void>.delayed(const Duration(milliseconds: 100));
  sending = false;
  await burst;
  lines.add(
    'detach under traffic: ${probe.byteCalls == afterDetach ? 'no' : 'a'} '
    'call after the detach returned ($afterDetach calls)',
  );
  await backend.detachNativeTap(umpInput.id);
  // The loopback device still echoes the burst: let it drain before the
  // next check opens the ports.
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await backend.closePort(output.id);
  await backend.closePort(umpOutput.id);
  await backend.closePort(input.id);
  await backend.closePort(umpInput.id);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  host.packets.remove(input.id);
  host.packets.remove(umpInput.id);
  lines.add('slots after detach: ${native.aud_midi_android_tap_count()}');
  probe.free();
  umpProbe.free();
  return lines;
}

/// GONE from the device callback: the app disables its loopback service
/// while a tap is attached to its input, which unplugs the device.
Future<List<String>> _nativeTapGone(
  AndroidMidiBackend backend,
  ReportHost host,
) async {
  final input = _port(backend, 'loop out', MidiDirection.input);
  if (input == null) return ['loopback device not found'];
  final probe = _Probe();
  await backend.attachNativeTap(input.id, probe.tap);
  final context = AudMidiContext.get()!;
  _trace?.call('  waiting for gone: disabling AudMidiLoopbackService');
  final started = host.clock.now();
  final disabledAt = platformNowNs();
  AudMidiLoopbackService.setEnabled(context, false);
  await host.waitFor(
    () => probe.goneCalls >= 1,
    timeout: const Duration(seconds: 40),
  );
  final gone = probe.goneCalls;
  final goneAt = probe.lastTimeNs;
  // The removal reaches Dart later; then the port is unknown.
  await host.waitFor(
    () => host.events.any((e) => e is MidiPortRemoved && e.port.id == input.id),
    timeout: const Duration(seconds: 10),
  );
  final removedAt = platformNowNs();
  String detach;
  try {
    await backend.detachNativeTap(input.id);
    detach = 'ok';
  } on MidiPortGone catch (error) {
    detach = '$error';
  }
  final lines = [
    'gone calls: $gone after ${host.clock.now().difference(started).inMilliseconds} ms',
    if (gone > 0)
      'gone ${(goneAt - disabledAt) ~/ 1000000} ms after the disable, Dart '
          'saw the removal ${(removedAt - goneAt) ~/ 1000000} ms after the '
          'gone call',
    'detach afterwards: $detach',
    'slots: ${native.aud_midi_android_tap_count()}',
  ];
  probe.free();
  AudMidiLoopbackService.setEnabled(context, true);
  context.release();
  await host.waitFor(
    () =>
        host.events.any((e) => e is MidiPortAdded && e.port.name == 'loop out'),
    timeout: const Duration(seconds: 10),
  );
  lines.add(
    're-enabled: ${_port(backend, 'loop out', MidiDirection.input)?.id}',
  );
  return lines;
}

/// The time of CLOCK_MONOTONIC in ns, the clock of the tap stamps.
int platformNowNs() => native.aud_midi_android_now_ns();

Future<List<String>> _byteLoopback(
  AndroidMidiBackend backend,
  ReportHost host,
) async {
  final input = _port(backend, 'loop out', MidiDirection.input);
  final output = _port(backend, 'loop in', MidiDirection.output);
  if (input == null || output == null) return ['loopback device not found'];
  _trace?.call('  opening ${input.id}');
  await backend.openPort(input.id);
  _trace?.call('  opening ${output.id}');
  await backend.openPort(output.id);
  _trace?.call('  sending');
  final sysEx = [0xf0, 0x7d, for (var i = 0; i < 3000; i++) i & 0x7f, 0xf7];
  final messages = [
    MidiBytes.fromHex('90 3c 64'),
    MidiBytes.fromHex('b0 07 7f'),
    MidiBytes.fromHex('e0 00 40'),
    MidiBytes.fromHex('80 3c 00'),
    MidiBytes(sysEx),
  ];
  final sent = <MidiBytesPacket>[];
  for (final message in messages) {
    final packet = MidiBytesPacket(bytes: message, time: host.clock.now());
    sent.add(packet);
    await backend.send(output.id, packet);
  }
  final scheduled = MidiBytesPacket(
    bytes: MidiBytes.fromHex('90 40 50'),
    time: host.clock.now() + const Duration(milliseconds: 200),
  );
  await backend.send(output.id, scheduled);
  final expected = [
    for (final packet in [...sent, scheduled]) ...packet.bytes.bytes,
  ];
  await host.waitFor(() => host.bytesOf(input.id).length >= expected.length);
  final received = host.packets[input.id] ?? const [];
  final last = received.isEmpty ? null : received.last;
  await backend.cancelPending(output.id);
  return [
    'send path: ${backend.sendPath(output.id)}, cancelPending: ok',
    'bytes sent ${expected.length}, received '
        '${host.bytesOf(input.id).length} in ${received.length} packets',
    'equal and in order: ${_equal(host.bytesOf(input.id), expected)}',
    'timestamps of the first four packets minus send time (us): '
        '${[for (var i = 0; i < 4 && i < received.length; i++) received[i].$1.time.difference(sent[i].time).inMicroseconds]}',
    'delivery latency of the first four packets (us): '
        '${[for (var i = 0; i < 4 && i < received.length; i++) received[i].$2.difference(received[i].$1.time).inMicroseconds]}',
    if (last != null)
      'scheduled packet: timestamp minus due time '
          '${last.$1.time.difference(scheduled.time).inMicroseconds} us, '
          'arrived ${scheduled.time.difference(last.$2).inMilliseconds} ms '
          'before due (a virtual device does not schedule)',
  ];
}

Future<List<String>> _umpLoopback(
  AndroidMidiBackend backend,
  ReportHost host,
) async {
  final input = _port(backend, 'ump loop', MidiDirection.input);
  final output = _port(backend, 'ump loop', MidiDirection.output);
  if (input == null || output == null) return ['UMP loopback not found'];
  await backend.openPort(input.id);
  await backend.openPort(output.id);
  final packets = [
    [0x40903c00, 0xc0000000],
    [0x20903c64],
    [0xf0000101, 0x0000001f, 0, 0],
    [
      for (var i = 0; i < 300; i++) ...[0x40900000 | (i & 0x7f) << 8, i],
    ],
  ];
  final sent = <MidiUmpPacket>[];
  for (final words in packets) {
    final packet = MidiUmpPacket(words: words, time: host.clock.now());
    sent.add(packet);
    await backend.send(output.id, packet);
  }
  final expected = [for (final packet in sent) ...packet.words];
  await host.waitFor(() => host.wordsOf(input.id).length >= expected.length);
  final received = host.packets[input.id] ?? const [];
  return [
    'protocol ${output.protocol.name}, send path: '
        '${backend.sendPath(output.id)}',
    'words sent ${expected.length}, received '
        '${host.wordsOf(input.id).length} in ${received.length} packets',
    'equal and in order: ${_equal(host.wordsOf(input.id), expected)}',
    'timestamp of the first packet minus send time (us): '
        '${received.isEmpty ? '-' : received.first.$1.time.difference(sent.first.time).inMicroseconds}',
  ];
}

Future<List<String>> _virtualPorts(
  AndroidMidiBackend backend,
  ReportHost host,
) async {
  final ownIn = await backend.virtualPorts.create(
    MidiVirtualPortSpec(name: 'virtual in', direction: MidiDirection.input),
  );
  final umpLines = await _ownUmpDevice(backend, host);
  final ownOut = await backend.virtualPorts.create(
    MidiVirtualPortSpec(name: 'virtual out', direction: MidiDirection.output),
  );
  await backend.openPort(ownIn.id);
  await backend.openPort(ownOut.id);
  // Another client of the app's own virtual device, as another app would be.
  final platform = MidiAndroidJniPlatform();
  final device = platform.devices().firstWhere((d) => d.ownService != null);
  final client = await platform.openDevice(device.id);
  if (client == null) return ['the own device cannot be opened as client'];
  final clientBytes = <int>[];
  late final MidiAndroidReceiver clientReceiver;
  clientReceiver = client.openOutputPort(
    port: 0,
    onData: () {
      final data = clientReceiver.drain();
      if (data == null) return;
      for (final chunk
          in const MidiAndroidReceiveDecoder().decode(data).chunks) {
        clientBytes.addAll(chunk.bytes);
      }
    },
  )!;
  final clientSender = client.openJavaInputPort(0)!;
  // Timestamp 0: the shim's receiver stamps the data with System.nanoTime().
  clientSender
    ..send(Uint8List.fromList([0x90, 0x30, 0x40]), timestampNanos: 0)
    ..flush();
  await host.waitFor(() => host.bytesOf(ownIn.id).length >= 3);
  final (stamped, arrived) = host.packets[ownIn.id]!.first;
  await backend.send(
    ownOut.id,
    MidiBytesPacket(
      bytes: MidiBytes.fromHex('b0 01 02'),
      time: host.clock.now(),
    ),
  );
  await host.waitFor(() => clientBytes.length >= 3);
  final lines = [
    'own ports: ${ownIn.id} (${ownIn.direction.name}), '
        '${ownOut.id} (${ownOut.direction.name})',
    'other app -> own input: ${_hex(host.bytesOf(ownIn.id))}, '
        'arrival minus System.nanoTime() stamp: '
        '${arrived.difference(stamped.time).inMicroseconds} us',
    'own output -> other app: ${_hex(clientBytes)}',
  ];
  clientSender.close();
  clientReceiver.close();
  client.close();
  platform.dispose();
  return [...lines, ...umpLines];
}

Future<List<String>> _ownUmpDevice(
  AndroidMidiBackend backend,
  ReportHost host,
) async {
  final ownIn = await backend.virtualPorts.create(
    MidiVirtualPortSpec(
      name: 'ump virtual',
      direction: MidiDirection.input,
      protocol: MidiProtocol.midi2,
    ),
  );
  final ownOut = await backend.virtualPorts.create(
    MidiVirtualPortSpec(
      name: 'ump virtual',
      direction: MidiDirection.output,
      protocol: MidiProtocol.midi2,
    ),
  );
  await backend.openPort(ownIn.id);
  await backend.openPort(ownOut.id);
  final platform = MidiAndroidJniPlatform();
  final device = platform.devices().firstWhere(
    (d) =>
        d.ownService == 'com.audanika.aud_midi_android.AudMidiUmpDeviceService',
  );
  final client = await platform.openDevice(device.id);
  if (client == null) return ['the own UMP device cannot be opened'];
  final clientWords = <int>[];
  final assembler = MidiAndroidUmpAssembler();
  late final MidiAndroidReceiver clientReceiver;
  clientReceiver = client.openOutputPort(
    port: 0,
    onData: () {
      final data = clientReceiver.drain();
      if (data == null) return;
      for (final chunk
          in const MidiAndroidReceiveDecoder().decode(data).chunks) {
        clientWords.addAll(assembler.add(chunk.bytes));
      }
    },
  )!;
  final clientSender =
      client.openNativeInputPort(0) ?? client.openJavaInputPort(0)!;
  clientSender.send(
    MidiAndroidPacketEncoder.pack(const [0x40903c00, 0xc0000000]),
    timestampNanos: platform.monotonicMicros() * 1000,
  );
  await host.waitFor(() => host.wordsOf(ownIn.id).length >= 2);
  await backend.send(
    ownOut.id,
    MidiUmpPacket(words: const [0x20b00102], time: host.clock.now()),
  );
  await host.waitFor(() => clientWords.isNotEmpty);
  final lines = [
    'own UMP ports: ${ownIn.id} ump=${ownIn.capabilities.ump}, '
        '${ownOut.id}',
    'other app -> own UMP input: '
        '${host.wordsOf(ownIn.id).map((w) => w.toRadixString(16))}',
    'own UMP output -> other app (${clientSender.kind}): '
        '${clientWords.map((w) => w.toRadixString(16))}',
  ];
  clientSender.close();
  clientReceiver.close();
  client.close();
  platform.dispose();
  return lines;
}

Future<List<String>> _engine() async {
  final engine = MidiEngine(backend: AndroidMidiBackend());
  await engine.open();
  try {
    MidiPortId find(String name, MidiDirection direction) => engine.ports
        .firstWhere((p) => p.name == name && p.direction == direction)
        .id;
    final input = await engine.openInput(find('loop out', MidiDirection.input));
    final output = await engine.openOutput(
      find('loop in', MidiDirection.output),
    );
    final events = <MidiEvent>[];
    final subscription = input.events.listen(events.add);
    final messages = <MidiMessage>[
      const MidiNoteOn(channel: 0, note: 60, velocity: 100),
      const MidiControlChange(channel: 1, controller: 7, value: 99),
      MidiSysEx([0x7d, 1, 2, 3]),
    ];
    for (final message in messages) {
      await output.send(message);
    }
    // The virtual loopback does not schedule: the engine times the note.
    final due = engine.clock.now() + const Duration(milliseconds: 100);
    await output.send(const MidiNoteOff(channel: 0, note: 60), at: due);
    final end = engine.clock.now() + const Duration(seconds: 3);
    while (events.length < 4 && engine.clock.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final umpInput = await engine.openInput(
      find('ump loop', MidiDirection.input),
    );
    final umpOutput = await engine.openOutput(
      find('ump loop', MidiDirection.output),
    );
    final umpEvents = <MidiEvent>[];
    final umpSubscription = umpInput.events.listen(umpEvents.add);
    await umpOutput.send(
      const MidiNoteOn2(channel: 2, note: 64, velocity: 0x8000),
    );
    // A MIDI 1.0 message to a MIDI 2.0 port: the engine translates it.
    await umpOutput.send(const MidiNoteOn(channel: 3, note: 65, velocity: 64));
    final umpEnd = engine.clock.now() + const Duration(seconds: 3);
    while (umpEvents.length < 2 && engine.clock.now().isBefore(umpEnd)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await subscription.cancel();
    await umpSubscription.cancel();
    final received = [for (final event in events) event.message];
    return [
      'bytes: sent ${messages.length + 1} messages, received '
          '${received.length}, equal and in order: '
          '${_equal(received, [...messages, const MidiNoteOff(channel: 0, note: 60)])}',
      if (events.length == 4)
        'software-scheduled note: received '
            '${events.last.time.difference(due).inMicroseconds} us after due',
      'UMP: received ${[for (final event in umpEvents) event.message]}',
    ];
  } finally {
    await engine.close();
  }
}

Future<List<String>> _bluetooth(AndroidMidiBackend backend) async {
  final bluetooth = backend.bluetooth;
  if (bluetooth == null) return ['no Bluetooth LE'];
  try {
    final found = await bluetooth
        .scan(timeout: const Duration(seconds: 2))
        .toList();
    return ['scan of 2 s found ${found.length} BLE-MIDI peripherals'];
  } on MidiException catch (error) {
    return ['scan refused: $error'];
  }
}

Future<List<String>> _advertise() async {
  final registration = await MidiAndroidServiceAdvertiser().register(
    name: 'aud_midi example',
    type: '_apple-midi._udp',
    port: 5004,
  );
  final name = registration.name;
  await registration.unregister();
  return ['registered and unregistered "$name"'];
}

Future<List<String>> _multicastLock() async {
  final lock = MidiAndroidMulticastLock()..acquire();
  final held = lock.isHeld;
  lock.dispose();
  return ['held after acquire: $held'];
}

MidiPortInfo? _port(
  AndroidMidiBackend backend,
  String name,
  MidiDirection direction,
) => backend.ports
    .where((port) => port.name == name && port.direction == direction)
    .firstOrNull;

bool _equal(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
