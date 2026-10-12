// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// coverage:ignore-file
// Reason: JNI glue to android.media.midi and the Java shim; it runs on
// Android only. The logic behind it is tested with fakes of
// MidiAndroidPlatform; the glue itself is verified on the emulator with the
// example app.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:jni/jni.dart';

import '../amidi/midi_android_amidi.dart';
import '../amidi/midi_android_amidi_bindings.g.dart' show AMidiDevice;
import '../clock/midi_android_monotonic_clock.dart';
import '../logic/midi_android_error_codes.dart';
import '../native/aud_midi_android_bindings.g.dart' as native;
import '../platform/midi_android_ble_scan_result.dart';
import '../platform/midi_android_ble_scanner.dart';
import '../platform/midi_android_device.dart';
import '../platform/midi_android_device_description.dart';
import '../platform/midi_android_platform.dart';
import '../platform/midi_android_port_description.dart';
import '../platform/midi_android_receiver.dart';
import '../platform/midi_android_sender.dart';
import 'midi_android_jni_bindings.g.dart' hide Duration;

// #############################################################################
/// The [MidiAndroidPlatform] of a real Android device: `android.media.midi`
/// through the jnigen bindings, the Java shim and AMidi.
///
/// package:jni loads classes through the application class loader that its
/// plugin captured, so the platform works in any isolate of the app, e.g.
/// the MIDI isolate; JNI attaches the isolate's threads on demand.
final class MidiAndroidJniPlatform implements MidiAndroidPlatform {
  /// Creates the platform over the application [context]; null uses the
  /// context the shim captured at app start.
  ///
  /// Throws [MidiUnsupported] outside Android and when no context exists.
  factory MidiAndroidJniPlatform({JObject? context}) {
    if (!Platform.isAndroid) {
      throw const MidiUnsupported('android.media.midi outside Android');
    }
    final app = context?.as(Context.type) ?? AudMidiContext.get();
    if (app == null) {
      throw const MidiUnsupported(
        'android.media.midi without an application context: is the '
        'aud_midi_android plugin part of the app?',
      );
    }
    return MidiAndroidJniPlatform._(app);
  }

  MidiAndroidJniPlatform._(this._context)
    : sdkInt = Build$VERSION.SDK_INT,
      _manager = AudMidiContext.midiManager(_context);

  // ...........................................................................
  @override
  List<MidiAndroidDeviceDescription> devices() => [
    for (final transport in _transports) ..._devicesOf(transport),
  ];

  @override
  void watchDevices({
    required void Function(MidiAndroidDeviceDescription device) onAdded,
    required void Function(int id) onRemoved,
  }) {
    unwatchDevices();
    final manager = _manager;
    if (manager == null) return;
    final listener = AudMidiDeviceListener.implement(
      $AudMidiDeviceListener(
        onDeviceAdded: (info, transport) {
          if (info == null) return;
          final device = _describe(info, transport);
          info.release();
          onAdded(device);
        },
        onDeviceAdded$async: true,
        onDeviceRemoved: (info, transport) {
          if (info == null) return;
          final id = info.id;
          info.release();
          onRemoved(id);
        },
        onDeviceRemoved$async: true,
      ),
    );
    _deviceListener = listener;
    _deviceCallbacks = [
      for (final transport in _transports)
        AudMidiDeviceCallback.new$1(listener, transport)..register(manager),
    ];
  }

  @override
  void unwatchDevices() {
    final manager = _manager;
    for (final callback in _deviceCallbacks) {
      if (manager != null) callback.unregister(manager);
      callback.release();
    }
    _deviceCallbacks = const [];
    _deviceListener?.release();
    _deviceListener = null;
  }

  // ...........................................................................
  @override
  Future<MidiAndroidDevice?> openDevice(int id) async {
    final manager = _manager;
    if (manager == null) return null;
    for (final transport in _transports) {
      final info = _find(manager, transport, id);
      if (info == null) continue;
      try {
        return await _open(
          transport,
          (listener) => manager.openDevice(info, listener, null),
        );
      } finally {
        info.release();
      }
    }
    return null;
  }

  @override
  Future<MidiAndroidDevice?> openBluetoothDevice(String address) async {
    final manager = _manager;
    final adapter = _bluetoothAdapter;
    if (manager == null || adapter == null) return null;
    final JObject? device;
    try {
      device = using(
        (arena) =>
            adapter.getRemoteDevice$1(address.toJString()..releasedBy(arena)),
      );
    } on JThrowable {
      return null;
    }
    if (device == null) return null;
    try {
      return await _open(
        MidiAndroidDeviceDescription.transportByteStream,
        (listener) => manager.openBluetoothDevice(
          device!.as(BluetoothDevice.type),
          listener,
          null,
        ),
      );
    } finally {
      device.release();
    }
  }

  // ...........................................................................
  @override
  MidiAndroidReceiver openVirtualInput({
    required String service,
    required int port,
    required void Function() onData,
  }) {
    final receiver = using(
      (arena) => AudMidiVirtualDevices.inputReceiver(
        service.toJString()..releasedBy(arena),
        port,
      ),
    );
    return _data.attach(receiver!, onData: onData);
  }

  @override
  MidiAndroidSender openVirtualOutput({
    required String service,
    required int port,
  }) => _JniVirtualSender(service: service, port: port);

  // ...........................................................................
  @override
  bool hasPermission(String permission) => using(
    (arena) => AudMidiContext.hasPermission(
      _context,
      permission.toJString()..releasedBy(arena),
    ),
  );

  @override
  int monotonicMicros() => _clock.nowMicros();

  @override
  void dispose() {
    unwatchDevices();
    _scanner?.stop();
    _data.dispose();
  }

  // ...........................................................................
  @override
  final int sdkInt;

  @override
  bool get hasMidi => _manager != null;

  @override
  MidiAndroidBleScanner? get bleScanner {
    final adapter = _bluetoothAdapter;
    if (adapter == null) return null;
    return _scanner ??= _JniBleScanner(adapter, sdkInt: sdkInt);
  }

  // ...........................................................................
  final Context _context;
  final MidiManager? _manager;
  final _clock = MidiAndroidMonotonicClock();
  final _data = _JniDataListener();
  late final MidiAndroidAMidi? _amidi = MidiAndroidAMidi.load(sdkInt: sdkInt);
  late final BluetoothAdapter? _bluetoothAdapter = _adapter();
  AudMidiDeviceListener? _deviceListener;
  List<AudMidiDeviceCallback> _deviceCallbacks = const [];
  _JniBleScanner? _scanner;

  List<int> get _transports => [
    MidiAndroidDeviceDescription.transportByteStream,
    if (sdkInt >= 33) MidiAndroidDeviceDescription.transportUmp,
  ];

  BluetoothAdapter? _adapter() {
    final manager = AudMidiContext.bluetoothManager(_context);
    if (manager == null) return null;
    try {
      return manager.adapter;
    } finally {
      manager.release();
    }
  }

  List<MidiAndroidDeviceDescription> _devicesOf(int transport) {
    final manager = _manager;
    if (manager == null) return const [];
    final infos = AudMidiDeviceCallback.devices(manager, transport);
    if (infos == null) return const [];
    try {
      return [
        for (var i = 0; i < infos.length; i++)
          if (infos[i] case final info?) _describeAndRelease(info, transport),
      ];
    } finally {
      infos.release();
    }
  }

  MidiDeviceInfo? _find(MidiManager manager, int transport, int id) {
    final infos = AudMidiDeviceCallback.devices(manager, transport);
    if (infos == null) return null;
    try {
      for (var i = 0; i < infos.length; i++) {
        final info = infos[i];
        if (info == null) continue;
        if (info.id == id) return info;
        info.release();
      }
      return null;
    } finally {
      infos.release();
    }
  }

  Future<MidiAndroidDevice?> _open(
    int transport,
    void Function(MidiManager$OnDeviceOpenedListener listener) call,
  ) async {
    final opened = Completer<MidiDevice?>();
    final listener = MidiManager$OnDeviceOpenedListener.implement(
      $MidiManager$OnDeviceOpenedListener(
        onDeviceOpened: (device) {
          if (!opened.isCompleted) opened.complete(device);
        },
        onDeviceOpened$async: true,
      ),
    );
    try {
      call(listener);
    } on JThrowable {
      return null;
    } finally {
      listener.release();
    }
    final device = await opened.future;
    if (device == null) return null;
    final info = device.info;
    if (info == null) {
      device
        ..close()
        ..release();
      return null;
    }
    final description = _describeAndRelease(info, transport);
    return _JniDevice(device, description, amidi: _amidi, data: _data);
  }

  MidiAndroidDeviceDescription _describeAndRelease(
    MidiDeviceInfo info,
    int transport,
  ) {
    try {
      return _describe(info, transport);
    } finally {
      info.release();
    }
  }

  MidiAndroidDeviceDescription _describe(MidiDeviceInfo info, int transport) =>
      using((arena) {
        final properties = info.properties?..releasedBy(arena);
        String text(String key) =>
            properties
                ?.getString(key.toJString()..releasedBy(arena))
                ?.toDartString(releaseOriginal: true) ??
            '';
        final type = info.type$1;
        return MidiAndroidDeviceDescription(
          id: info.id,
          type: type,
          transport: transport,
          defaultProtocol: sdkInt >= 33
              ? info.defaultProtocol
              : MidiAndroidDeviceDescription.protocolUnknown,
          name: text('name'),
          manufacturer: text('manufacturer'),
          product: text('product'),
          serialNumber: text('serial_number'),
          version: text('version'),
          ports: _ports(info, arena),
          ownService: type == MidiAndroidDeviceDescription.typeVirtual
              ? AudMidiVirtualDevices.ownService(
                  _context,
                  info,
                )?.toDartString(releaseOriginal: true)
              : null,
          bluetoothAddress: type == MidiAndroidDeviceDescription.typeBluetooth
              ? _bluetoothAddress(properties, arena)
              : '',
          isPrivate: info.isPrivate,
        );
      });

  static List<MidiAndroidPortDescription> _ports(
    MidiDeviceInfo info,
    Arena arena,
  ) {
    final ports = info.ports?..releasedBy(arena);
    if (ports == null) return const [];
    return [
      for (var i = 0; i < ports.length; i++)
        if (ports[i] case final port?)
          MidiAndroidPortDescription(
            type: (port..releasedBy(arena)).type$1,
            number: port.portNumber,
            name: port.name?.toDartString(releaseOriginal: true) ?? '',
          ),
    ];
  }

  static String _bluetoothAddress(Bundle? properties, Arena arena) {
    final device = properties?.getParcelable<BluetoothDevice?>(
      'bluetooth_device'.toJString()..releasedBy(arena),
    );
    if (device == null) return '';
    device.releasedBy(arena);
    return device.address?.toDartString(releaseOriginal: true) ?? '';
  }
}

// #############################################################################
/// An opened `MidiDevice` with the AMidi device connected to it on demand.
final class _JniDevice implements MidiAndroidDevice {
  _JniDevice(
    this._device,
    this.description, {
    required this._amidi,
    required this._data,
  });

  @override
  final MidiAndroidDeviceDescription description;

  final MidiDevice _device;
  final _JniDataListener _data;
  MidiAndroidAMidi? _amidi;
  Pointer<AMidiDevice>? _native;
  final List<MidiAndroidSender> _nativeSenders = [];

  @override
  MidiAndroidReceiver? openOutputPort({
    required int port,
    required void Function() onData,
  }) {
    final MidiOutputPort? outputPort;
    try {
      outputPort = _device.openOutputPort(port);
    } on JThrowable {
      return null;
    }
    if (outputPort == null) return null;
    final receiver = AudMidiReceiver(AudMidiReceiver.DEFAULT_CAPACITY);
    final result = _data.attach(
      receiver,
      onData: onData,
      port: outputPort,
      deviceId: description.id,
    );
    outputPort.connect(receiver);
    return result;
  }

  @override
  MidiAndroidSender? openNativeInputPort(int port) {
    final amidi = _amidi;
    if (amidi == null) return null;
    final native = _native ??= amidi.connect(_device);
    if (native == null) {
      _amidi = null;
      return null;
    }
    final sender = amidi.openInputPort(native, port);
    if (sender != null) _nativeSenders.add(sender);
    return sender;
  }

  @override
  MidiAndroidSender? openJavaInputPort(int port) {
    try {
      final inputPort = _device.openInputPort(port);
      return inputPort == null ? null : _JniSender(inputPort);
    } on JThrowable {
      return null;
    }
  }

  @override
  void close() {
    for (final sender in _nativeSenders) {
      sender.close();
    }
    _nativeSenders.clear();
    final native = _native;
    if (native != null) _amidi?.release(native);
    _native = null;
    try {
      _device.close();
    } on JThrowable {
      // The device is gone already.
    }
    _device.release();
  }
}

// #############################################################################
/// Sends through a Java `MidiInputPort`.
final class _JniSender implements MidiAndroidSender {
  _JniSender(this._port);

  final MidiInputPort _port;
  bool _closed = false;

  @override
  void send(Uint8List data, {required int timestampNanos}) {
    final array = JByteArray(data.length)..setRange(0, data.length, data);
    try {
      _port.send$1(array, 0, data.length, timestampNanos);
    } on JThrowable {
      throw const MidiNativeError(
        api: 'MidiInputPort.send',
        code: MidiAndroidErrorCodes.unavailable,
      );
    } finally {
      array.release();
    }
  }

  @override
  void flush() {
    try {
      _port.flush();
    } on JThrowable {
      throw const MidiNativeError(
        api: 'MidiInputPort.flush',
        code: MidiAndroidErrorCodes.unavailable,
      );
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _port.close();
    } on JThrowable {
      // The port is gone already.
    }
    _port.release();
  }

  @override
  String get kind => MidiAndroidSender.java;
}

// #############################################################################
/// Sends out of an output port of the app's own virtual device.
final class _JniVirtualSender implements MidiAndroidSender {
  _JniVirtualSender({required String service, required this.port})
    : _service = service.toJString();

  final JString _service;
  final int port;
  bool _closed = false;

  @override
  void send(Uint8List data, {required int timestampNanos}) {
    final array = JByteArray(data.length)..setRange(0, data.length, data);
    try {
      // False means that no app has the device open: nobody listens.
      AudMidiVirtualDevices.send(
        _service,
        port,
        array,
        0,
        data.length,
        timestampNanos,
      );
    } on JThrowable {
      throw const MidiNativeError(
        api: 'AudMidiVirtualDevices.send',
        code: MidiAndroidErrorCodes.unavailable,
      );
    } finally {
      array.release();
    }
  }

  @override
  void flush() {
    try {
      AudMidiVirtualDevices.flush(_service, port);
    } on JThrowable {
      throw const MidiNativeError(
        api: 'AudMidiVirtualDevices.flush',
        code: MidiAndroidErrorCodes.unavailable,
      );
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _service.release();
  }

  @override
  String get kind => MidiAndroidSender.virtual;
}

// #############################################################################
/// An `AudMidiReceiver` attached to the data listener, connected to an
/// output port unless it belongs to an own virtual device.
///
/// A native tap takes a slot of the native tap library
/// (`src/aud_midi_android.c`); the Java receiver hands every chunk to it on
/// the MIDI thread, the device callback reports `gone` for the device
/// [_deviceId].
final class _JniReceiver implements MidiAndroidReceiver {
  _JniReceiver(this._receiver, this._port, this._deviceId, this._onClose);

  final AudMidiReceiver _receiver;
  final MidiOutputPort? _port;
  final int _deviceId;
  final void Function() _onClose;
  bool _closed = false;
  MidiNativeTap? _tap;
  int _tapHandle = 0;

  @override
  Uint8List? drain() {
    if (_closed) return null;
    final array = _receiver.drain();
    if (array == null) return null;
    try {
      return Uint8List.fromList(array.getRange(0, array.length));
    } finally {
      array.release();
    }
  }

  @override
  void attachNativeTap(MidiNativeTap tap, {required bool ump}) {
    if (_closed) throw StateError('The receiver is closed');
    if (_tap != null) throw StateError('A native tap is attached already');
    if (!AudMidiNativeTap.load()) {
      throw const MidiNativeError(
        api: 'System.loadLibrary(aud_midi_android)',
        code: MidiAndroidErrorCodes.unavailable,
      );
    }
    final handle = native.aud_midi_android_tap_attach(
      Pointer.fromAddress(tap.function),
      Pointer.fromAddress(tap.user),
      ump ? 1 : 0,
    );
    if (handle <= 0) {
      throw MidiNativeError(api: 'aud_midi_android_tap_attach', code: handle);
    }
    _tap = tap;
    _tapHandle = handle;
    _receiver.setNativeTap(handle, _deviceId);
  }

  @override
  void detachNativeTap() {
    final handle = _tapHandle;
    if (handle == 0) return;
    _tap = null;
    _tapHandle = 0;
    // No new call starts after this; the detach waits for the ones inside
    // and leaks the slot with a log line when one does not return.
    _receiver.setNativeTap(0, 0);
    native.aud_midi_android_tap_detach(handle, _detachTimeoutMs);
  }

  @override
  MidiNativeTap? get nativeTap => _tap;

  @override
  void close() {
    if (_closed) return;
    detachNativeTap();
    _closed = true;
    _receiver.setListener(null, 0);
    final port = _port;
    if (port != null) {
      try {
        port
          ..disconnect(_receiver)
          ..close();
      } on JThrowable {
        // The port is gone already.
      }
      port.release();
    }
    _receiver.release();
    _onClose();
  }

  /// How long a detach waits for the calls in flight.
  static const int _detachTimeoutMs = 1000;
}

// #############################################################################
/// The one `AudMidiDataListener` of the platform: it routes the data signals
/// of all receivers by token to the callbacks of the backend.
final class _JniDataListener {
  final Map<int, void Function()> _callbacks = {};
  AudMidiDataListener? _listener;
  int _nextToken = 1;

  _JniReceiver attach(
    AudMidiReceiver receiver, {
    required void Function() onData,
    MidiOutputPort? port,
    int deviceId = 0,
  }) {
    final token = _nextToken++;
    _callbacks[token] = onData;
    receiver.setListener(_proxy, token);
    return _JniReceiver(
      receiver,
      port,
      deviceId,
      () => _callbacks.remove(token),
    );
  }

  void dispose() {
    _callbacks.clear();
    _listener?.release();
    _listener = null;
  }

  AudMidiDataListener get _proxy => _listener ??= AudMidiDataListener.implement(
    $AudMidiDataListener(
      onDataAvailable: (token) => _callbacks[token]?.call(),
      onDataAvailable$async: true,
    ),
  );
}

// #############################################################################
/// Scans with `BluetoothLeScanner` for the BLE-MIDI service.
final class _JniBleScanner implements MidiAndroidBleScanner {
  _JniBleScanner(this._adapter, {required this._sdkInt});

  final BluetoothAdapter _adapter;
  final int _sdkInt;
  BluetoothLeScanner? _scanner;
  AudMidiScanCallback? _callback;
  AudMidiScanListener? _listener;

  @override
  bool get isEnabled {
    try {
      return _adapter.isEnabled;
    } on JThrowable {
      return false;
    }
  }

  @override
  void start({
    required void Function(MidiAndroidBleScanResult result) onResult,
    required void Function(int errorCode) onFailed,
  }) {
    stop();
    final scanner = _adapter.bluetoothLeScanner;
    if (scanner == null) {
      scheduleMicrotask(() => onFailed(MidiAndroidErrorCodes.unavailable));
      return;
    }
    final listener = AudMidiScanListener.implement(
      $AudMidiScanListener(
        onScanResult: (result) {
          if (result == null) return;
          final read = _read(result);
          result.release();
          if (read != null) onResult(read);
        },
        onScanResult$async: true,
        onScanFailed: onFailed,
        onScanFailed$async: true,
      ),
    );
    final callback = AudMidiScanCallback(listener);
    try {
      using((arena) {
        final uuid = ParcelUuid.fromString(
          MidiBleTransport.serviceUuid.toJString()..releasedBy(arena),
        )?..releasedBy(arena);
        final filterBuilder = ScanFilter$Builder()..releasedBy(arena);
        filterBuilder.setServiceUuid(uuid)?.releasedBy(arena);
        final filters = JArrayList<ScanFilter?>()..releasedBy(arena);
        filters.add(filterBuilder.build()?..releasedBy(arena));
        final settingsBuilder = ScanSettings$Builder()..releasedBy(arena);
        settingsBuilder
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            ?.releasedBy(arena);
        final settings = settingsBuilder.build()?..releasedBy(arena);
        scanner.startScan$2(filters, settings, callback);
      });
    } on JThrowable {
      callback.release();
      listener.release();
      scanner.release();
      scheduleMicrotask(() => onFailed(MidiAndroidErrorCodes.unavailable));
      return;
    }
    _scanner = scanner;
    _callback = callback;
    _listener = listener;
  }

  @override
  void stop() {
    final scanner = _scanner;
    final callback = _callback;
    if (scanner != null && callback != null) {
      try {
        scanner.stopScan$1(callback);
      } on JThrowable {
        // Bluetooth was switched off; the scan ended with it.
      }
    }
    scanner?.release();
    callback?.release();
    _listener?.release();
    _scanner = null;
    _callback = null;
    _listener = null;
  }

  MidiAndroidBleScanResult? _read(ScanResult result) => using((arena) {
    final device = result.device?..releasedBy(arena);
    final address = device?.address?.toDartString(releaseOriginal: true);
    if (address == null) return null;
    final record = result.scanRecord?..releasedBy(arena);
    return MidiAndroidBleScanResult(
      address: address,
      name: record?.deviceName?.toDartString(releaseOriginal: true) ?? '',
      rssi: result.rssi,
      isConnectable: _sdkInt < 26 || result.isConnectable,
    );
  });
}
