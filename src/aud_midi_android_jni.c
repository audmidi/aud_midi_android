// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The JNI glue of the native tap library: the native methods of the Java
// shim's AudMidiNativeTap. The Java receiver calls them on Android's MIDI
// dispatcher thread with every chunk of a tapped port, and the device
// callback calls `gone` when the device of the port disappears.
//
// The names follow the JNI convention for the package
// com.audanika.aud_midi_android, so that the Java VM resolves them once
// System.loadLibrary("aud_midi_android") loaded this library;
// aud_midi_android_register_natives registers them explicitly when the
// library was loaded another way.

#include <jni.h>

#include "aud_midi_android.h"

#define JNI_NAME(name) Java_com_audanika_aud_1midi_1android_AudMidiNativeTap_##name

JNIEXPORT void JNICALL JNI_NAME(send)(JNIEnv *env, jclass type, jlong handle,
                                      jbyteArray data, jint offset,
                                      jint count, jlong timestamp) {
  (void)type;
  // A bounded copy on the stack per piece; the Java array is never pinned.
  jbyte buffer[AUD_MIDI_ANDROID_TAP_CHUNK_BYTES];
  while (count > 0) {
    const jint piece = count > AUD_MIDI_ANDROID_TAP_CHUNK_BYTES
                           ? AUD_MIDI_ANDROID_TAP_CHUNK_BYTES
                           : count;
    (*env)->GetByteArrayRegion(env, data, offset, piece, buffer);
    if ((*env)->ExceptionCheck(env)) return;
    aud_midi_android_tap_send(handle, (const uint8_t *)buffer,
                              (uint32_t)piece, timestamp);
    offset += piece;
    count -= piece;
  }
}

JNIEXPORT void JNICALL JNI_NAME(gone)(JNIEnv *env, jclass type,
                                      jlong handle) {
  (void)env, (void)type;
  aud_midi_android_tap_gone(handle, 0);
}

/// Registers the native methods with [type], the class AudMidiNativeTap,
/// for a library the Java VM did not load itself. Returns JNI_OK or the
/// JNI error.
JNIEXPORT jint aud_midi_android_register_natives(JNIEnv *env, jclass type) {
  static const JNINativeMethod methods[] = {
      {"send", "(J[BIIJ)V", (void *)JNI_NAME(send)},
      {"gone", "(J)V", (void *)JNI_NAME(gone)},
  };
  return (*env)->RegisterNatives(env, type, methods,
                                 sizeof(methods) / sizeof(methods[0]));
}
