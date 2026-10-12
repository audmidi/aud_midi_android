// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:jni/jni.dart';

import 'bluetooth/midi_android_bluetooth.dart';
import 'jni/midi_android_jni_platform.dart';
import 'logic/midi_android_error_codes.dart';
import 'logic/midi_android_packet_encoder.dart';
import 'logic/midi_android_permissions.dart';
import 'logic/midi_android_port_table.dart';
import 'logic/midi_android_receive_decoder.dart';
import 'logic/midi_android_ump_assembler.dart';
import 'platform/midi_android_device.dart';
import 'platform/midi_android_device_description.dart';
import 'platform/midi_android_platform.dart';
import 'platform/midi_android_receiver.dart';
import 'platform/midi_android_sender.dart';
import 'virtual/midi_android_virtual_ports.dart';

// #############################################################################
/// The MIDI backend of Android: `android.media.midi` through JNI and the
/// Java shim of this package, AMidi for sending from API 29.
///
/// - Ports: every port of every device the MIDI service knows, USB,
///   Bluetooth LE and virtual devices of other apps; Android's input ports
///   are outputs of the app. From API 33 Universal MIDI Packet devices too;
///   their ports exchange UMP words.
/// - Receiving: the shim's `AudMidiReceiver` copies the data with their
///   timestamps on the MIDI thread and signals the isolate, which drains
///   them; `CLOCK_MONOTONIC` timestamps become package times.
/// - Sending: AMidi from API 29, `MidiInputPort` below or when AMidi fails;
///   the due time travels as timestamp, USB and Bluetooth devices hold the
///   data until then.
/// - Hotplug through the shim's `AudMidiDeviceCallback`.
/// - [virtualPorts]: the ports of the app's own `AudMidiDeviceService`s.
/// - [bluetooth]: scan and connect of BLE-MIDI peripherals.
/// - Native taps ([attachNativeTap]): the Java receiver hands every chunk
///   of the port to the native tap library on the MIDI thread, with the
///   bytes of a MIDI 1.0 port or the complete packets of a UMP port and
///   the `System.nanoTime()` stamp; `gone` comes from the device callback.
///   A tap keeps the port open without Dart listeners; a removed device
///   detaches its taps after `gone`.
///
/// The backend runs in the isolate that starts it, usually the MIDI
/// isolate; all callbacks arrive there.
final class AndroidMidiBackend implements MidiBackend, MidiNativeTapBackend {
  /// Creates the backend.
  ///
  /// - [context] the Android application context; null uses the context
  ///   the shim captured at app start.
  /// - [platform] replaces the JNI platform, e.g. with a fake in tests.
  /// - [resyncInterval] how often the offset between `CLOCK_MONOTONIC` and
  ///   the package clock is measured again.
  AndroidMidiBackend({
    this._context,
    this._platform,
    this.resyncInterval = const Duration(seconds: 10),
  });

  // ...........................................................................
  /// Enumerates the devices and starts to watch for hotplug.
  ///
  /// Throws [MidiUnsupported] outside Android and on devices without the
  /// feature `android.software.midi`.
  @override
  Future<void> start(MidiBackendHost host) async {
    if (_host != null) throw StateError('The backend is already started');
    final platform = _platform ??= MidiAndroidJniPlatform(context: _context);
    if (!platform.hasMidi) {
      throw const MidiUnsupported('MIDI without android.software.midi');
    }
    final permissions = MidiAndroidPermissions(
      sdkInt: platform.sdkInt,
      isGranted: platform.hasPermission,
    );
    _host = host;
    _permissions = permissions;
    _mapper = MidiClockMapper(
      clock: host.clock,
      nativeNow: platform.monotonicMicros,
    );
    _lastResync = host.clock.now();
    platform.watchDevices(onAdded: _deviceAdded, onRemoved: _deviceRemoved);
    _table.sync(platform.devices());
    final scanner = platform.bleScanner;
    _bluetooth = scanner == null
        ? null
        : MidiAndroidBluetooth(
            scanner: scanner,
            permissions: permissions,
            connectPeripheral: _connectPeripheral,
            disconnectPeripheral: _disconnectPeripheral,
            onScanFailed: _scanFailed,
          );
  }

  /// Closes all ports and devices and stops watching for hotplug.
  @override
  Future<void> stop() async {
    final platform = _platform;
    if (_host == null || platform == null) return;
    platform.unwatchDevices();
    await _bluetooth?.stopScan();
    for (final port in [..._inputs.keys]) {
      _closeInput(port);
    }
    for (final port in [..._outputs.keys]) {
      await closePort(port);
    }
    for (final device in [..._devices.values]) {
      (await device.opening)?.close();
    }
    _devices.clear();
    platform.dispose();
    _table.sync(const []);
    _bluetooth = null;
    _host = null;
  }

  // ...........................................................................
  /// Opens [port]; the device of the port is opened with its first port.
  ///
  /// Throws [MidiPortGone] for an unknown port and a [MidiNativeError] when
  /// Android cannot open it.
  @override
  Future<void> openPort(MidiPortId port) async {
    await _ensureOpen(port);
    final input = _inputs[port];
    if (input == null) return;
    input.isOpen = true;
    input.receiver.setListening(true);
  }

  /// Closes [port]; an input with a native tap stays open for the tap
  /// alone and copies nothing to Dart any more, the device closes with its
  /// last port.
  @override
  Future<void> closePort(MidiPortId port) async {
    final input = _inputs[port];
    if (input != null) {
      input.isOpen = false;
      if (input.tap == null) {
        _closeInput(port);
      } else {
        input.receiver.setListening(false);
      }
    }
    final output = _outputs.remove(port);
    if (output != null) {
      output.sender.close();
      _release(output.device);
    }
  }

  // ...........................................................................
  /// Returns whether [port] is a known input.
  @override
  bool supportsNativeTap(MidiPortId port) =>
      _table.port(port)?.isInput ?? false;

  /// Opens the input [port] when needed and attaches [tap] to its receiver;
  /// a port open for the tap alone copies nothing to Dart.
  ///
  /// Throws [MidiPortGone] for an unknown port, an [ArgumentError] for an
  /// output, a [StateError] when a tap is attached already and a
  /// [MidiNativeError] when Android cannot open the port or the tap library
  /// is missing.
  @override
  Future<void> attachNativeTap(MidiPortId port, MidiNativeTap tap) async {
    _requireHost();
    final info = _table.port(port) ?? (throw MidiPortGone(port));
    if (!info.isInput) throw ArgumentError.value(port, 'port', 'Not an input');
    if (_inputs[port]?.tap != null) throw StateError('$port has a tap already');
    await _ensureOpen(port);
    final input = _inputs[port] ?? (throw MidiPortGone(port));
    if (input.tap != null) throw StateError('$port has a tap already');
    input.receiver.attachNativeTap(tap, ump: input.ump);
    input.tap = tap;
    if (!input.isOpen) input.receiver.setListening(false);
  }

  /// Detaches the tap of [port] after its last call; the port closes when
  /// no Dart listener holds it. Throws [MidiPortGone] for an unknown port.
  @override
  Future<void> detachNativeTap(MidiPortId port) async {
    final input = _inputs[port];
    if (input == null) {
      if (_table.port(port) == null) throw MidiPortGone(port);
      return;
    }
    if (input.tap == null) return;
    input.receiver.detachNativeTap();
    input.tap = null;
    if (!input.isOpen) _closeInput(port);
  }

  // ...........................................................................
  /// Sends [packet] to the open output [port], due at its time.
  ///
  /// Throws [MidiPortGone] for an unknown port, a [StateError] for a port
  /// that is not open and an [ArgumentError] for a byte packet to a UMP
  /// port or the other way round.
  @override
  Future<void> send(MidiPortId port, MidiPacket packet) async {
    final output = _openOutput(port);
    if ((packet is MidiUmpPacket) != output.ump) {
      throw ArgumentError.value(
        packet,
        'packet',
        output.ump ? 'The port takes UMP packets' : 'The port takes bytes',
      );
    }
    _resyncIfDue();
    final timestamp = _timestampNanos(packet.time);
    for (final chunk in _encoder.encode(packet)) {
      output.sender.send(chunk, timestampNanos: timestamp);
    }
  }

  /// Discards what the open output [port] holds and has not sent yet.
  @override
  Future<void> cancelPending(MidiPortId port) async =>
      _openOutput(port).sender.flush();

  /// Returns the path the data to the open output [port] take, see
  /// [MidiAndroidSender.kind], or null when the port is not open.
  String? sendPath(MidiPortId port) => _outputs[port]?.sender.kind;

  // ...........................................................................
  @override
  String get name => backendName;

  /// The Android MIDI capabilities: static virtual ports, hardware
  /// scheduling, Bluetooth LE scanning when the device has Bluetooth LE,
  /// UMP from API 33 and the permissions the app lacks.
  @override
  MidiCapabilities get capabilities {
    final platform = _platform;
    final permissions = _permissions;
    if (_host == null || platform == null || permissions == null) {
      return const MidiCapabilities.none();
    }
    return MidiCapabilities(
      virtualPorts: MidiVirtualPortSupport.staticPorts,
      bleScan: _bluetooth != null,
      ump: platform.sdkInt >= umpApiLevel,
      scheduling: MidiSchedulingSupport.hardware,
      missingPermissions: permissions.missing,
    );
  }

  @override
  List<MidiPortInfo> get ports => _table.ports;

  /// The devices the ports belong to.
  List<MidiDeviceInfo> get devices => [
    for (final device in _table.devices) _table.mapper.device(device),
  ];

  @override
  MidiVirtualPortsBackend get virtualPorts => _virtualPorts;

  @override
  MidiBluetoothBackend? get bluetooth => _bluetooth;

  /// Null: Android has no network session of its own; the umbrella composes
  /// the sessions of `aud_midi_network` with a [MidiServiceAdvertiser].
  @override
  MidiNetworkBackend? get network => null;

  /// How often the clock offset is measured again.
  final Duration resyncInterval;

  // ...........................................................................
  /// The name of the backend and the prefix of its ids.
  static const String backendName = 'android';

  /// The API level from which AMidi sends.
  static const int amidiApiLevel = 29;

  /// The API level from which Universal MIDI Packet devices exist.
  static const int umpApiLevel = 33;

  // ...........................................................................
  final JObject? _context;
  MidiAndroidPlatform? _platform;
  MidiBackendHost? _host;
  MidiAndroidPermissions? _permissions;
  MidiAndroidBluetooth? _bluetooth;
  MidiClockMapper? _mapper;
  MidiTime _lastResync = MidiTime.zero;
  final _table = MidiAndroidPortTable();
  final _decoder = const MidiAndroidReceiveDecoder();
  final _encoder = const MidiAndroidPacketEncoder();
  final Map<int, _OpenDevice> _devices = {};
  final Map<MidiPortId, _OpenInput> _inputs = {};
  final Map<MidiPortId, _OpenOutput> _outputs = {};
  final Map<MidiPortId, Future<void>> _opening = {};
  late final _virtualPorts = MidiAndroidVirtualPorts(
    ports: () => ports,
    closePort: closePort,
  );

  MidiBackendHost _requireHost() =>
      _host ?? (throw StateError('The backend is not started'));

  /// Opens [port] unless it is open or opening.
  Future<void> _ensureOpen(MidiPortId port) {
    _requireHost();
    if (_inputs.containsKey(port) || _outputs.containsKey(port)) {
      return Future.value();
    }
    // A block body: an arrow would return the removed future itself, and
    // whenComplete would wait for it forever.
    return _opening[port] ??= _open(port).whenComplete(() {
      _opening.remove(port);
    });
  }

  /// Closes the input [port] and releases its device.
  void _closeInput(MidiPortId port) {
    final input = _inputs.remove(port);
    if (input == null) return;
    input.receiver.close();
    _release(input.device);
  }

  Future<void> _open(MidiPortId id) async {
    final port = _table.port(id) ?? (throw MidiPortGone(id));
    final device = _table.deviceOf(id)!;
    final service = device.ownService;
    if (service != null) return _openOwn(port, service);
    final entry = _devices[device.id] ??= _OpenDevice(
      device.id,
      _platform!.openDevice(device.id),
    );
    entry.users++;
    try {
      final opened = await _opened(entry);
      if (_table.port(id) == null) throw MidiPortGone(id);
      if (port.isInput) {
        _inputs[id] = _OpenInput(
          receiver:
              opened.openOutputPort(
                port: port.index,
                onData: () => _drain(id),
              ) ??
              (throw const MidiNativeError(
                api: 'MidiDevice.openOutputPort',
                code: MidiAndroidErrorCodes.unavailable,
              )),
          ump: port.capabilities.ump,
          device: entry,
        );
      } else {
        _outputs[id] = _OpenOutput(
          sender: _openSender(id, opened, port.index),
          ump: port.capabilities.ump,
          device: entry,
        );
      }
    } catch (_) {
      _release(entry);
      rethrow;
    }
  }

  void _openOwn(MidiPortInfo port, String service) {
    final platform = _platform!;
    if (port.isInput) {
      _inputs[port.id] = _OpenInput(
        receiver: platform.openVirtualInput(
          service: service,
          port: port.index,
          onData: () => _drain(port.id),
        ),
        ump: port.capabilities.ump,
      );
    } else {
      _outputs[port.id] = _OpenOutput(
        sender: platform.openVirtualOutput(service: service, port: port.index),
        ump: port.capabilities.ump,
      );
    }
  }

  MidiAndroidSender _openSender(
    MidiPortId id,
    MidiAndroidDevice device,
    int index,
  ) {
    if (_platform!.sdkInt >= amidiApiLevel) {
      final native = device.openNativeInputPort(index);
      if (native != null) return native;
      _diagnostic(
        MidiDiagnosticKind.nativeError,
        port: id,
        cause: 'AMidi cannot open the port, MidiInputPort sends instead',
      );
    }
    return device.openJavaInputPort(index) ??
        (throw const MidiNativeError(
          api: 'MidiDevice.openInputPort',
          code: MidiAndroidErrorCodes.unavailable,
        ));
  }

  static Future<MidiAndroidDevice> _opened(_OpenDevice entry) async =>
      await entry.opening ??
      (throw const MidiNativeError(
        api: 'MidiManager.openDevice',
        code: MidiAndroidErrorCodes.unavailable,
      ));

  void _release(_OpenDevice? entry) {
    if (entry == null) return;
    entry.users--;
    if (entry.users > 0 || entry.address != null) return;
    if (!identical(_devices[entry.id], entry)) return;
    _devices.remove(entry.id);
    unawaited(entry.opening.then((device) => device?.close()));
  }

  _OpenOutput _openOutput(MidiPortId port) {
    final output = _outputs[port];
    if (output != null) return output;
    if (_table.port(port) == null) throw MidiPortGone(port);
    throw StateError('The port $port is not open');
  }

  void _drain(MidiPortId id) {
    final input = _inputs[id];
    final host = _host;
    if (input == null || host == null) return;
    final data = input.receiver.drain();
    // A port open for its native tap only copies nothing, but a signal
    // posted before the listening stopped may still arrive.
    if (data == null || !input.isOpen) return;
    _resyncIfDue();
    final MidiAndroidDrained drained;
    try {
      drained = _decoder.decode(data);
    } on FormatException catch (error) {
      _diagnostic(
        MidiDiagnosticKind.invalidData,
        port: id,
        cause: error.message,
      );
      return;
    }
    for (final chunk in drained.chunks) {
      _deliver(host, id, input, chunk);
    }
    if (drained.dropped > 0) {
      input.assembler?.reset();
      _diagnostic(
        MidiDiagnosticKind.queueOverflow,
        port: id,
        count: drained.dropped,
        cause: 'The receive buffer of the Java shim was full',
      );
    }
  }

  void _deliver(
    MidiBackendHost host,
    MidiPortId id,
    _OpenInput input,
    MidiAndroidChunk chunk,
  ) {
    final time = _mapper!.toPackage(chunk.timestampNanos ~/ 1000);
    final assembler = input.assembler;
    if (assembler == null) {
      host.received(
        id,
        MidiBytesPacket(bytes: MidiBytes(chunk.bytes), time: time),
      );
      return;
    }
    final words = assembler.add(chunk.bytes);
    if (words.isNotEmpty) {
      host.received(id, MidiUmpPacket(words: words, time: time));
    }
  }

  int _timestampNanos(MidiTime due) {
    final now = _platform!.monotonicMicros();
    final native = _mapper!.toNative(due);
    return (native > now ? native : now) * 1000;
  }

  void _resyncIfDue() {
    final now = _host!.clock.now();
    if (now.difference(_lastResync) >= resyncInterval) _resync();
  }

  void _resync() {
    _mapper!.resync();
    _lastResync = _host!.clock.now();
  }

  void _deviceAdded(MidiAndroidDeviceDescription device) {
    if (_host == null) return;
    _resync();
    _report(_table.add(device));
  }

  void _deviceRemoved(int id) {
    if (_host == null) return;
    _closeDevice(id);
    _report(_table.remove(id));
  }

  void _closeDevice(int id) {
    for (final entry in [..._inputs.entries]) {
      if (entry.value.device?.id != id) continue;
      _inputs.remove(entry.key);
      entry.value.receiver.close();
    }
    for (final entry in [..._outputs.entries]) {
      if (entry.value.device?.id != id) continue;
      _outputs.remove(entry.key);
      entry.value.sender.close();
    }
    final device = _devices.remove(id);
    if (device != null) {
      unawaited(device.opening.then((device) => device?.close()));
    }
  }

  Future<List<MidiPortInfo>> _connectPeripheral(
    String address,
    Duration timeout,
  ) async {
    _requireHost();
    for (final entry in _devices.entries) {
      if (entry.value.address == address) return _table.portsOf(entry.key);
    }
    final opening = _platform!.openBluetoothDevice(address);
    final device = await opening.timeout(
      timeout,
      onTimeout: () {
        unawaited(opening.then((late) => late?.close()));
        throw const MidiNativeError(
          api: _openBluetoothApi,
          code: MidiAndroidErrorCodes.timeout,
        );
      },
    );
    if (device == null) {
      throw const MidiNativeError(
        api: _openBluetoothApi,
        code: MidiAndroidErrorCodes.unavailable,
      );
    }
    final description = device.description;
    final existing = _devices[description.id];
    if (existing == null) {
      _devices[description.id] = _OpenDevice(
        description.id,
        Future.value(device),
        address: address,
      );
    } else {
      device.close();
      existing.address = address;
    }
    _report(_table.add(description));
    return _table.portsOf(description.id);
  }

  Future<void> _disconnectPeripheral(String address) async {
    final ids = [
      for (final entry in _devices.entries)
        if (entry.value.address == address) entry.key,
    ];
    for (final id in ids) {
      _closeDevice(id);
      _report(_table.remove(id));
    }
  }

  void _scanFailed(int errorCode) => _diagnostic(
    MidiDiagnosticKind.nativeError,
    cause: 'The Bluetooth LE scan failed with error $errorCode',
  );

  void _report(List<MidiPortEvent> events) {
    if (events.isNotEmpty) _host?.portsChanged(events);
  }

  void _diagnostic(
    MidiDiagnosticKind kind, {
    MidiPortId? port,
    int count = 1,
    required String cause,
  }) {
    final host = _host!;
    host.diagnostic(
      MidiDiagnostic(
        kind: kind,
        port: port,
        count: count,
        cause: cause,
        time: host.clock.now(),
      ),
    );
  }

  static const _openBluetoothApi = 'MidiManager.openBluetoothDevice';
}

// #############################################################################
/// A device opened by the backend, shared by its open ports.
final class _OpenDevice {
  _OpenDevice(this.id, this.opening, {this.address});

  /// The id of the device.
  final int id;

  /// Completes with the device, or null when Android could not open it.
  final Future<MidiAndroidDevice?> opening;

  /// The number of open ports of the device.
  int users = 0;

  /// The Bluetooth address of a connected peripheral, which stays open
  /// until it is disconnected.
  String? address;
}

// #############################################################################
/// An open input of the app.
final class _OpenInput {
  _OpenInput({required this.receiver, required this.ump, this.device})
    : assembler = ump ? MidiAndroidUmpAssembler() : null;

  final MidiAndroidReceiver receiver;

  /// Whether the port exchanges UMP words.
  final bool ump;

  /// Assembles the packets of a UMP port; null for a byte port.
  final MidiAndroidUmpAssembler? assembler;

  /// The opened device; null for an own virtual port.
  final _OpenDevice? device;

  /// Whether a Dart listener opened the port with `openPort`.
  bool isOpen = false;

  /// The native tap attached to the port, or null.
  MidiNativeTap? tap;
}

// #############################################################################
/// An open output of the app.
final class _OpenOutput {
  _OpenOutput({required this.sender, required this.ump, this.device});

  final MidiAndroidSender sender;

  /// Whether the port takes UMP packets.
  final bool ump;

  /// The opened device; null for an own virtual port.
  final _OpenDevice? device;
}
