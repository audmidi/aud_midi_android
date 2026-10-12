// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'package:aud_midi_core/aud_midi_core.dart';

// #############################################################################
/// An open Android MIDI port that delivers data to the app through the
/// shim's `AudMidiReceiver`.
abstract interface class MidiAndroidReceiver {
  // ...........................................................................
  /// Returns everything received since the last call in the layout of
  /// `AudMidiReceiver.drain()`, or null when nothing arrived.
  Uint8List? drain();

  // ...........................................................................
  /// Calls [tap] on the MIDI thread with every chunk from now on, through
  /// the native tap library: with the bytes of a MIDI 1.0 port, with the
  /// complete UMP packets of a UMP port ([ump]); with `gone` when the
  /// device of the port is removed.
  ///
  /// Throws a [MidiNativeError] when the library cannot be loaded or has
  /// no free slot, and a [StateError] when a tap is attached already.
  void attachNativeTap(MidiNativeTap tap, {required bool ump});

  /// Stops the calls of the tap and returns after the last one returned;
  /// does nothing without a tap.
  void detachNativeTap();

  /// The tap attached right now, or null.
  MidiNativeTap? get nativeTap;

  // ...........................................................................
  /// Stops the delivery, detaches the tap and closes the port.
  void close();
}
