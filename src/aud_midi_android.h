// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The native tap library of aud_midi_android.
//
// The Java shim's AudMidiReceiver gets every chunk of an open port on
// Android's MIDI dispatcher thread. With a native tap attached, it hands the
// chunk to this library through JNI (aud_midi_android_jni.c), which calls
// the tap function of a native consumer without the Dart isolate in
// between:
//
// - a slot table keyed by handles: an attach returns a handle, a detach
//   returns only after the last call of the tap returned and never frees a
//   slot that a call may still touch (a timeout leaks the slot and logs),
// - an in-flight count per slot, so that a detach can wait,
// - a UMP assembler per slot of a UMP port: Android carries UMP words as
//   big-endian bytes and may cut a chunk inside a packet; the tap gets host
//   order words of complete packets only,
// - "gone" from the device callback when the device of the port is removed.
//
// Everything in this header is independent of JNI, so that the tests run
// on the development machine under the sanitizers.

#ifndef AUD_MIDI_ANDROID_H
#define AUD_MIDI_ANDROID_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The kinds of a tap call: UMP words in host byte order (complete
/// packets), bytes of a MIDI 1.0 stream, or the port is gone (no data).
#define AUD_MIDI_ANDROID_TAP_UMP 1
#define AUD_MIDI_ANDROID_TAP_BYTES 2
#define AUD_MIDI_ANDROID_TAP_GONE 3

/// The number of tap slots; an attach beyond it fails.
#define AUD_MIDI_ANDROID_TAP_SLOTS 64

/// The largest chunk the JNI glue hands to a tap in one call, in bytes.
#define AUD_MIDI_ANDROID_TAP_CHUNK_BYTES 1024

/// The error of an invalid handle.
#define AUD_MIDI_ANDROID_PARAM_ERROR -50

/// The error of a detach whose wait for the calls in flight timed out; the
/// slot stays leaked.
#define AUD_MIDI_ANDROID_TIMEOUT_ERROR -1

/// The error of an attach when every slot is taken.
#define AUD_MIDI_ANDROID_FULL_ERROR -2

/// The tap function (the contract with the consumer): [data] are
/// [count] words (UMP) or bytes (BYTES), NULL and 0 for GONE;
/// [host_time_ns] the time of CLOCK_MONOTONIC, `System.nanoTime()`.
typedef void (*AudMidiAndroidTapFunction)(void *user, uint32_t kind,
                                          const void *data, uint32_t count,
                                          int64_t host_time_ns);

/// Takes a slot for [function] called with [user]; [ump] 1 for a UMP port
/// (the bytes are assembled into words), 0 for a MIDI 1.0 port. Returns
/// the handle (never 0), or AUD_MIDI_ANDROID_FULL_ERROR.
int64_t aud_midi_android_tap_attach(AudMidiAndroidTapFunction function,
                                    void *user, int32_t ump);

/// Stops the calls of [handle] and waits up to [timeout_ms] milliseconds
/// until none is in flight, then frees the slot. Returns 0,
/// AUD_MIDI_ANDROID_PARAM_ERROR for a handle that is not attached, or
/// AUD_MIDI_ANDROID_TIMEOUT_ERROR when a call did not return in time; the
/// slot is then leaked and never reused.
int32_t aud_midi_android_tap_detach(int64_t handle, int32_t timeout_ms);

/// Hands [count] bytes of [data], received at [host_time_ns], to the tap
/// of [handle]: as they are for a MIDI 1.0 port, as the complete UMP
/// packets they complete for a UMP port. Returns 1 when the tap was
/// called, 0 when the handle is stale or nothing was complete.
int32_t aud_midi_android_tap_send(int64_t handle, const uint8_t *data,
                                  uint32_t count, int64_t host_time_ns);

/// Reports GONE at [host_time_ns] to the tap of [handle] (0: now). May run
/// on any thread; a stale handle is ignored. Returns 1 when the tap was
/// called.
int32_t aud_midi_android_tap_gone(int64_t handle, int64_t host_time_ns);

/// Returns the number of calls of [handle] in flight right now, or -1 for a
/// handle that is not attached; for tests.
int32_t aud_midi_android_tap_in_flight(int64_t handle);

/// Returns the number of slots taken, leaked ones included; for tests.
int32_t aud_midi_android_tap_count(void);

/// Returns the current time of CLOCK_MONOTONIC in nanoseconds, the clock of
/// `System.nanoTime()`.
int64_t aud_midi_android_now_ns(void);

// #############################################################################
// Probe: a tap for the tests and the example app

/// A tap that counts what it receives.
typedef struct AudMidiAndroidProbe AudMidiAndroidProbe;

/// The number of values aud_midi_android_probe_read fills: UMP calls, byte
/// calls, gone calls, words, bytes, the last host time, the sum of all
/// words and bytes, the first word or byte of the last data call, the
/// number of calls that overlapped another one, and the smallest
/// difference between the time of a data call and its arrival in ns.
#define AUD_MIDI_ANDROID_PROBE_VALUES 10

/// Creates a probe; free it with aud_midi_android_probe_free after the tap
/// was detached.
AudMidiAndroidProbe *aud_midi_android_probe_create(void);

/// Frees [probe].
void aud_midi_android_probe_free(AudMidiAndroidProbe *probe);

/// Returns the tap function of the probes; the probe is the user.
AudMidiAndroidTapFunction aud_midi_android_probe_function(void);

/// Copies up to [capacity] of the AUD_MIDI_ANDROID_PROBE_VALUES values of
/// [probe] into [out].
void aud_midi_android_probe_read(const AudMidiAndroidProbe *probe,
                                 int64_t *out, uint32_t capacity);

#ifdef __cplusplus
}
#endif

#endif  // AUD_MIDI_ANDROID_H
