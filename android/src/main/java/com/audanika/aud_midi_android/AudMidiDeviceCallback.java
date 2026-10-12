// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

package com.audanika.aud_midi_android;

import android.annotation.TargetApi;
import android.media.midi.MidiDeviceInfo;
import android.media.midi.MidiManager;
import android.os.Build;
import java.util.concurrent.Executor;

/**
 * Forwards the hotplug notifications of {@link MidiManager} for one transport
 * to an {@link AudMidiDeviceListener}.
 */
public final class AudMidiDeviceCallback extends MidiManager.DeviceCallback {
  /** The transport of MIDI 1.0 byte-stream devices, also below API 33. */
  public static final int TRANSPORT_MIDI_BYTE_STREAM = 1;

  /** The transport of Universal MIDI Packet devices, API 33 and later. */
  public static final int TRANSPORT_UNIVERSAL_MIDI_PACKETS = 2;

  private static final Executor DIRECT = Runnable::run;

  private final AudMidiDeviceListener listener;
  private final int transport;

  /** Creates a callback for {@code transport} that forwards to {@code listener}. */
  public AudMidiDeviceCallback(AudMidiDeviceListener listener, int transport) {
    this.listener = listener;
    this.transport = transport;
  }

  /** Registers the callback with {@code manager}. */
  @SuppressWarnings("deprecation")
  public void register(MidiManager manager) {
    if (Build.VERSION.SDK_INT >= 33) {
      registerForTransport(manager);
    } else {
      manager.registerDeviceCallback(this, null);
    }
  }

  /** Unregisters the callback from {@code manager}. */
  public void unregister(MidiManager manager) {
    manager.unregisterDeviceCallback(this);
  }

  /** Returns the devices of {@code transport} known to {@code manager}. */
  @SuppressWarnings("deprecation")
  public static MidiDeviceInfo[] devices(MidiManager manager, int transport) {
    if (Build.VERSION.SDK_INT >= 33) {
      return devicesForTransport(manager, transport);
    }
    return transport == TRANSPORT_MIDI_BYTE_STREAM
        ? manager.getDevices()
        : new MidiDeviceInfo[0];
  }

  @Override
  public void onDeviceAdded(MidiDeviceInfo device) {
    listener.onDeviceAdded(device, transport);
  }

  @Override
  public void onDeviceRemoved(MidiDeviceInfo device) {
    // The native taps of the device learn it first, without Dart.
    AudMidiReceiver.deviceGone(device.getId());
    listener.onDeviceRemoved(device, transport);
  }

  @TargetApi(33)
  private void registerForTransport(MidiManager manager) {
    manager.registerDeviceCallback(transport, DIRECT, this);
  }

  @TargetApi(33)
  private static MidiDeviceInfo[] devicesForTransport(MidiManager manager, int transport) {
    return manager.getDevicesForTransport(transport).toArray(new MidiDeviceInfo[0]);
  }
}
