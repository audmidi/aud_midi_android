// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

package com.audanika.aud_midi_android;

/**
 * The native tap library of the package, {@code libaud_midi_android.so},
 * built by the package's Dart build hook and packaged into the app by
 * Flutter.
 *
 * <p>{@link AudMidiReceiver} calls {@link #send} on the MIDI thread with every
 * chunk of a tapped port and {@link AudMidiDeviceCallback} calls {@link #gone}
 * when the device of a tapped port disappears. Both run without Dart.
 */
public final class AudMidiNativeTap {
  private static boolean loaded;
  private static String loadError;

  private AudMidiNativeTap() {}

  /**
   * Loads the library with {@code System.loadLibrary} once and returns whether
   * it is loaded; {@link #loadError()} tells why not.
   */
  public static synchronized boolean load() {
    if (loaded) {
      return true;
    }
    try {
      System.loadLibrary("aud_midi_android");
      loaded = true;
      loadError = null;
    } catch (UnsatisfiedLinkError error) {
      loadError = error.toString();
    }
    return loaded;
  }

  /**
   * Marks the library as loaded by other means, e.g. by Dart, after its native
   * methods were registered.
   */
  public static synchronized void setLoaded() {
    loaded = true;
    loadError = null;
  }

  /** Whether the library is loaded. */
  public static synchronized boolean isLoaded() {
    return loaded;
  }

  /** The error of the last failed {@link #load()}, or null. */
  public static synchronized String loadError() {
    return loadError;
  }

  /**
   * Hands {@code count} bytes of {@code data} from {@code offset}, received at
   * {@code timestamp} ({@code System.nanoTime()}), to the tap {@code handle}.
   */
  static native void send(long handle, byte[] data, int offset, int count, long timestamp);

  /** Tells the tap {@code handle} that its port is gone. */
  static native void gone(long handle);
}
