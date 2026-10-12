// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

package com.audanika.aud_midi_android;

import android.content.ComponentName;
import android.content.Context;
import android.content.pm.PackageManager;
import android.media.midi.MidiDeviceInfo;
import android.media.midi.MidiDeviceService;
import android.media.midi.MidiReceiver;
import java.io.IOException;

/**
 * A virtual MIDI device for tests that sends everything it receives on input
 * port n unchanged, timestamp included, out of output port n.
 *
 * <p>Only test apps declare it in their manifest. {@link #setEnabled} unplugs
 * and re-plugs the device, so that tests see hotplug on the emulator.
 */
public final class AudMidiLoopbackService extends MidiDeviceService {
  /**
   * Enables or disables the service component of this app: the MIDI service
   * removes the device of a disabled component and adds it again when it is
   * enabled, like a device that is unplugged and plugged in again.
   */
  public static void setEnabled(Context context, boolean enabled) {
    context
        .getPackageManager()
        .setComponentEnabledSetting(
            new ComponentName(context, AudMidiLoopbackService.class),
            enabled
                ? PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                : PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP);
  }

  @Override
  public MidiReceiver[] onGetInputPortReceivers() {
    MidiDeviceInfo info = getDeviceInfo();
    int count = info == null ? 0 : info.getInputPortCount();
    MidiReceiver[] receivers = new MidiReceiver[count];
    for (int i = 0; i < count; i++) {
      receivers[i] = new Loop(i);
    }
    return receivers;
  }

  private final class Loop extends MidiReceiver {
    private final int port;

    Loop(int port) {
      this.port = port;
    }

    @Override
    public void onSend(byte[] msg, int offset, int count, long timestamp)
        throws IOException {
      MidiReceiver output = output();
      if (output != null) {
        output.send(msg, offset, count, timestamp);
      }
    }

    @Override
    public void onFlush() throws IOException {
      MidiReceiver output = output();
      if (output != null) {
        output.flush();
      }
    }

    private MidiReceiver output() {
      MidiReceiver[] outputs = getOutputPortReceivers();
      return outputs != null && port < outputs.length ? outputs[port] : null;
    }
  }
}
