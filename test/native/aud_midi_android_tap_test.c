// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The host-side test of the native tap library, the part independent of
// JNI: the slot table, the UMP assembler, the detach guarantee and the
// probe. scripts/test-native.js builds it under the address, undefined
// behaviour, realtime and thread sanitizers.

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "aud_midi_android.h"

#ifdef AUD_MIDI_RTSAN
#define NONBLOCKING [[clang::nonblocking]]
#else
#define NONBLOCKING
#endif

static int failures = 0;

#define CHECK(condition)                                                   \
  do {                                                                     \
    if (!(condition)) {                                                    \
      fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__,     \
              #condition);                                                 \
      failures++;                                                          \
    }                                                                      \
  } while (0)

enum {
  UMP_CALLS,
  BYTE_CALLS,
  GONE_CALLS,
  WORDS,
  BYTES,
  LAST_TIME,
  SUM,
  FIRST,
  OVERLAPS,
  MIN_DELAY
};

static int64_t value(const AudMidiAndroidProbe *probe, int index) {
  int64_t values[AUD_MIDI_ANDROID_PROBE_VALUES];
  aud_midi_android_probe_read(probe, values, AUD_MIDI_ANDROID_PROBE_VALUES);
  return values[index];
}

static void sleep_ms(int ms) {
  const struct timespec pause = {ms / 1000, (ms % 1000) * 1000000L};
  nanosleep(&pause, NULL);
}

// Big-endian bytes of [words].
static void pack(const uint32_t *words, uint32_t count, uint8_t *out) {
  for (uint32_t i = 0; i < count; i++) {
    out[i * 4] = (uint8_t)(words[i] >> 24);
    out[i * 4 + 1] = (uint8_t)(words[i] >> 16);
    out[i * 4 + 2] = (uint8_t)(words[i] >> 8);
    out[i * 4 + 3] = (uint8_t)words[i];
  }
}

// #############################################################################
// Bytes

static void test_bytes_reach_the_tap(void) {
  AudMidiAndroidProbe *probe = aud_midi_android_probe_create();
  const int64_t handle = aud_midi_android_tap_attach(
      aud_midi_android_probe_function(), probe, 0);
  CHECK(handle > 0);
  CHECK(aud_midi_android_tap_count() == 1);
  const uint8_t note_on[3] = {0x90, 0x3c, 0x64};
  const int64_t before = aud_midi_android_now_ns();
  CHECK(aud_midi_android_tap_send(handle, note_on, 3, before) == 1);
  CHECK(value(probe, BYTE_CALLS) == 1);
  CHECK(value(probe, BYTES) == 3);
  CHECK(value(probe, SUM) == 0x90 + 0x3c + 0x64);
  CHECK(value(probe, FIRST) == 0x90);
  CHECK(value(probe, LAST_TIME) == before);
  CHECK(value(probe, MIN_DELAY) >= 0);
  // 0 means now: the time is never 0.
  CHECK(aud_midi_android_tap_send(handle, note_on, 3, 0) == 1);
  CHECK(value(probe, LAST_TIME) >= before);
  // Empty data and NULL do nothing.
  CHECK(aud_midi_android_tap_send(handle, note_on, 0, 0) == 0);
  CHECK(aud_midi_android_tap_send(handle, NULL, 3, 0) == 0);
  CHECK(value(probe, BYTE_CALLS) == 2);
  CHECK(aud_midi_android_tap_detach(handle, 100) == 0);
  CHECK(aud_midi_android_tap_count() == 0);
  // A stale handle is ignored.
  CHECK(aud_midi_android_tap_send(handle, note_on, 3, 0) == 0);
  CHECK(aud_midi_android_tap_gone(handle, 0) == 0);
  CHECK(aud_midi_android_tap_detach(handle, 100) ==
        AUD_MIDI_ANDROID_PARAM_ERROR);
  CHECK(aud_midi_android_tap_in_flight(handle) == -1);
  CHECK(value(probe, BYTE_CALLS) == 2);
  aud_midi_android_probe_free(probe);
}

static void test_long_data_arrive_in_bounded_pieces(void) {
  AudMidiAndroidProbe *probe = aud_midi_android_probe_create();
  const int64_t handle = aud_midi_android_tap_attach(
      aud_midi_android_probe_function(), probe, 0);
  uint8_t *data = malloc(3000);
  for (int i = 0; i < 3000; i++) data[i] = (uint8_t)(i & 0x7f);
  CHECK(aud_midi_android_tap_send(handle, data, 3000, 7) == 1);
  CHECK(value(probe, BYTE_CALLS) == 3);
  CHECK(value(probe, BYTES) == 3000);
  int64_t sum = 0;
  for (int i = 0; i < 3000; i++) sum += data[i];
  CHECK(value(probe, SUM) == sum);
  free(data);
  CHECK(aud_midi_android_tap_detach(handle, 100) == 0);
  aud_midi_android_probe_free(probe);
}

// #############################################################################
// UMP

static void test_ump_words_are_assembled_across_chunks(void) {
  AudMidiAndroidProbe *probe = aud_midi_android_probe_create();
  const int64_t handle = aud_midi_android_tap_attach(
      aud_midi_android_probe_function(), probe, 1);
  const uint32_t words[7] = {0x40903c00, 0xc0000000, 0x20903c64,
                             0x50160001, 0x02030405, 0x06070809,
                             0x0a0b0c0d};
  uint8_t bytes[28];
  pack(words, 7, bytes);
  // One byte: nothing complete.
  CHECK(aud_midi_android_tap_send(handle, bytes, 1, 1) == 0);
  CHECK(value(probe, UMP_CALLS) == 0);
  // Up to the middle of the second word: still nothing.
  CHECK(aud_midi_android_tap_send(handle, bytes + 1, 5, 2) == 0);
  CHECK(value(probe, UMP_CALLS) == 0);
  // The rest of the first packet and the whole second one: one call with
  // both packets, host order.
  CHECK(aud_midi_android_tap_send(handle, bytes + 6, 6, 3) == 1);
  CHECK(value(probe, UMP_CALLS) == 1);
  CHECK(value(probe, WORDS) == 3);
  CHECK(value(probe, FIRST) == 0x40903c00);
  CHECK(value(probe, SUM) ==
        (int64_t)0x40903c00 + 0xc0000000 + 0x20903c64);
  CHECK(value(probe, LAST_TIME) == 3);
  // Three words of the four-word packet wait.
  CHECK(aud_midi_android_tap_send(handle, bytes + 12, 12, 4) == 0);
  CHECK(value(probe, UMP_CALLS) == 1);
  CHECK(aud_midi_android_tap_send(handle, bytes + 24, 4, 5) == 1);
  CHECK(value(probe, UMP_CALLS) == 2);
  CHECK(value(probe, WORDS) == 7);
  CHECK(value(probe, FIRST) == 0x50160001);
  CHECK(aud_midi_android_tap_detach(handle, 100) == 0);
  aud_midi_android_probe_free(probe);
}

static void test_ump_rest_does_not_survive_a_new_attach(void) {
  AudMidiAndroidProbe *probe = aud_midi_android_probe_create();
  int64_t handle = aud_midi_android_tap_attach(
      aud_midi_android_probe_function(), probe, 1);
  const uint8_t partial[2] = {0x20, 0x90};
  CHECK(aud_midi_android_tap_send(handle, partial, 2, 1) == 0);
  CHECK(aud_midi_android_tap_detach(handle, 100) == 0);
  handle = aud_midi_android_tap_attach(aud_midi_android_probe_function(),
                                       probe, 1);
  const uint8_t whole[4] = {0x20, 0x90, 0x3c, 0x64};
  CHECK(aud_midi_android_tap_send(handle, whole, 4, 1) == 1);
  CHECK(value(probe, WORDS) == 1);
  CHECK(value(probe, FIRST) == 0x20903c64);
  CHECK(aud_midi_android_tap_detach(handle, 100) == 0);
  aud_midi_android_probe_free(probe);
}

static void test_long_ump_data_keep_packets_whole(void) {
  AudMidiAndroidProbe *probe = aud_midi_android_probe_create();
  const int64_t handle = aud_midi_android_tap_attach(
      aud_midi_android_probe_function(), probe, 1);
  // 300 two-word packets: 2400 bytes, more than two pieces.
  uint32_t words[600];
  for (int i = 0; i < 300; i++) {
    words[i * 2] = 0x40900000u | (uint32_t)(i & 0x7f) << 8;
    words[i * 2 + 1] = (uint32_t)i;
  }
  uint8_t bytes[2400];
  pack(words, 600, bytes);
  CHECK(aud_midi_android_tap_send(handle, bytes, 2400, 9) == 1);
  CHECK(value(probe, WORDS) == 600);
  int64_t sum = 0;
  for (int i = 0; i < 600; i++) sum += words[i];
  CHECK(value(probe, SUM) == sum);
  CHECK(aud_midi_android_tap_detach(handle, 100) == 0);
  aud_midi_android_probe_free(probe);
}

// #############################################################################
// Gone, slots

static void test_gone_reaches_the_tap(void) {
  AudMidiAndroidProbe *probe = aud_midi_android_probe_create();
  const int64_t handle = aud_midi_android_tap_attach(
      aud_midi_android_probe_function(), probe, 0);
  CHECK(aud_midi_android_tap_gone(handle, 42) == 1);
  CHECK(value(probe, GONE_CALLS) == 1);
  CHECK(value(probe, LAST_TIME) == 42);
  CHECK(aud_midi_android_tap_gone(handle, 0) == 1);
  CHECK(value(probe, LAST_TIME) > 42);
  CHECK(aud_midi_android_tap_detach(handle, 100) == 0);
  aud_midi_android_probe_free(probe);
}

static void test_every_slot_can_be_taken_once(void) {
  AudMidiAndroidProbe *probe = aud_midi_android_probe_create();
  int64_t handles[AUD_MIDI_ANDROID_TAP_SLOTS];
  for (int i = 0; i < AUD_MIDI_ANDROID_TAP_SLOTS; i++) {
    handles[i] = aud_midi_android_tap_attach(
        aud_midi_android_probe_function(), probe, 0);
    CHECK(handles[i] > 0);
  }
  CHECK(aud_midi_android_tap_count() == AUD_MIDI_ANDROID_TAP_SLOTS);
  CHECK(aud_midi_android_tap_attach(aud_midi_android_probe_function(), probe,
                                    0) == AUD_MIDI_ANDROID_FULL_ERROR);
  CHECK(aud_midi_android_tap_attach(NULL, probe, 0) ==
        AUD_MIDI_ANDROID_PARAM_ERROR);
  for (int i = 0; i < AUD_MIDI_ANDROID_TAP_SLOTS; i++) {
    CHECK(aud_midi_android_tap_detach(handles[i], 100) == 0);
  }
  CHECK(aud_midi_android_tap_count() == 0);
  // Handles out of range are refused.
  CHECK(aud_midi_android_tap_detach(0, 100) == AUD_MIDI_ANDROID_PARAM_ERROR);
  CHECK(aud_midi_android_tap_detach(AUD_MIDI_ANDROID_TAP_SLOTS + 1, 100) ==
        AUD_MIDI_ANDROID_PARAM_ERROR);
  CHECK(aud_midi_android_tap_send(0, (const uint8_t *)"a", 1, 0) == 0);
  // A reused slot carries a new generation, so the old handle is stale.
  const int64_t old = aud_midi_android_tap_attach(
      aud_midi_android_probe_function(), probe, 0);
  CHECK(aud_midi_android_tap_detach(old, 100) == 0);
  const int64_t renewed = aud_midi_android_tap_attach(
      aud_midi_android_probe_function(), probe, 0);
  CHECK((renewed & 0xffffffff) == (old & 0xffffffff));
  CHECK(renewed != old);
  CHECK(aud_midi_android_tap_send(old, (const uint8_t *)"a", 1, 0) == 0);
  CHECK(aud_midi_android_tap_detach(renewed, 100) == 0);
  aud_midi_android_probe_free(probe);
}

// #############################################################################
// Threads

typedef struct {
  _Atomic int64_t handle;
  _Atomic int stop;
  _Atomic int64_t sent;
} Sender;

static void *send_loop(void *argument) {
  Sender *sender = argument;
  const uint8_t clock_byte = 0xf8;
  while (!atomic_load(&sender->stop)) {
    const int64_t handle = atomic_load(&sender->handle);
    if (aud_midi_android_tap_send(handle, &clock_byte, 1, 0) == 1) {
      atomic_fetch_add(&sender->sent, 1);
    }
  }
  return NULL;
}

// A tap that takes a while, so that a detach meets calls in flight.
static _Atomic int64_t slow_calls;
static _Atomic int64_t slow_after_detach;
static _Atomic int detached;

static void slow_tap(void *user, uint32_t kind, const void *data,
                     uint32_t count, int64_t host_time_ns) {
  (void)user, (void)kind, (void)data, (void)count, (void)host_time_ns;
  if (atomic_load(&detached)) atomic_fetch_add(&slow_after_detach, 1);
  atomic_fetch_add(&slow_calls, 1);
  sleep_ms(1);
}

static void test_detach_waits_for_the_calls_in_flight(void) {
  Sender sender = {0};
  pthread_t threads[4];
  for (int i = 0; i < 4; i++) {
    pthread_create(&threads[i], NULL, send_loop, &sender);
  }
  for (int round = 0; round < 20; round++) {
    atomic_store(&detached, 0);
    const int64_t handle = aud_midi_android_tap_attach(slow_tap, NULL, 0);
    CHECK(handle > 0);
    atomic_store(&sender.handle, handle);
    sleep_ms(3);
    CHECK(aud_midi_android_tap_in_flight(handle) >= 0);
    CHECK(aud_midi_android_tap_detach(handle, 1000) == 0);
    // No call runs after the detach returned.
    atomic_store(&detached, 1);
    CHECK(aud_midi_android_tap_in_flight(handle) == -1);
    sleep_ms(2);
    CHECK(atomic_load(&slow_after_detach) == 0);
  }
  atomic_store(&sender.stop, 1);
  for (int i = 0; i < 4; i++) pthread_join(threads[i], NULL);
  CHECK(atomic_load(&slow_calls) > 0);
  CHECK(atomic_load(&sender.sent) == atomic_load(&slow_calls));
  CHECK(aud_midi_android_tap_count() == 0);
}

static void test_gone_may_overlap_a_data_call(void) {
  AudMidiAndroidProbe *probe = aud_midi_android_probe_create();
  const int64_t handle = aud_midi_android_tap_attach(
      aud_midi_android_probe_function(), probe, 0);
  Sender sender = {0};
  atomic_store(&sender.handle, handle);
  pthread_t thread;
  pthread_create(&thread, NULL, send_loop, &sender);
  for (int i = 0; i < 1000; i++) {
    CHECK(aud_midi_android_tap_gone(handle, 0) == 1);
  }
  atomic_store(&sender.stop, 1);
  pthread_join(thread, NULL);
  CHECK(value(probe, GONE_CALLS) == 1000);
  CHECK(value(probe, BYTE_CALLS) == atomic_load(&sender.sent));
  CHECK(aud_midi_android_tap_detach(handle, 100) == 0);
  aud_midi_android_probe_free(probe);
}

// A tap that blocks until it is released: the detach times out and leaks.
static _Atomic int blocking_release;
static _Atomic int blocking_entered;

static void blocking_tap(void *user, uint32_t kind, const void *data,
                         uint32_t count, int64_t host_time_ns) {
  (void)user, (void)kind, (void)data, (void)count, (void)host_time_ns;
  atomic_store(&blocking_entered, 1);
  while (!atomic_load(&blocking_release)) sleep_ms(1);
}

static void *send_once(void *argument) {
  const int64_t handle = *(int64_t *)argument;
  const uint8_t byte = 0xfe;
  aud_midi_android_tap_send(handle, &byte, 1, 0);
  return NULL;
}

static void test_detach_leaks_a_slot_whose_call_never_returns(void) {
  const int before = aud_midi_android_tap_count();
  int64_t handle = aud_midi_android_tap_attach(blocking_tap, NULL, 0);
  pthread_t thread;
  pthread_create(&thread, NULL, send_once, &handle);
  while (!atomic_load(&blocking_entered)) sleep_ms(1);
  CHECK(aud_midi_android_tap_in_flight(handle) == 1);
  CHECK(aud_midi_android_tap_detach(handle, 20) ==
        AUD_MIDI_ANDROID_TIMEOUT_ERROR);
  // The slot stays taken, also after the call returned.
  CHECK(aud_midi_android_tap_count() == before + 1);
  atomic_store(&blocking_release, 1);
  pthread_join(thread, NULL);
  CHECK(aud_midi_android_tap_count() == before + 1);
  CHECK(aud_midi_android_tap_detach(handle, 20) ==
        AUD_MIDI_ANDROID_PARAM_ERROR);
  CHECK(aud_midi_android_tap_send(handle, (const uint8_t *)"a", 1, 0) == 0);
}

// #############################################################################
// Realtime: the call path never blocks or allocates. Under the realtime
// sanitizer this function is checked for both.

// With AUD_TEST_RTSAN_PROBE set, the path allocates: the sanitizer has to
// catch it, otherwise its silence on the real path would prove nothing.
static bool rtsan_probe;

static void call_path(int64_t handle, const uint8_t *bytes,
                      uint32_t count) NONBLOCKING {
  aud_midi_android_tap_send(handle, bytes, count, 0);
  aud_midi_android_tap_gone(handle, 0);
  if (rtsan_probe) {
    // Stored through a volatile pointer, so that the optimiser keeps it.
    volatile char *probe = malloc(16);
    if (probe != NULL) probe[0] = 1;
    free((void *)probe);
  }
}

static void test_call_path_is_nonblocking(void) {
  AudMidiAndroidProbe *probe = aud_midi_android_probe_create();
  const int64_t bytes_handle = aud_midi_android_tap_attach(
      aud_midi_android_probe_function(), probe, 0);
  const int64_t ump_handle = aud_midi_android_tap_attach(
      aud_midi_android_probe_function(), probe, 1);
  const uint32_t words[2] = {0x40903c00, 0xc0000000};
  uint8_t bytes[8];
  pack(words, 2, bytes);
  call_path(bytes_handle, bytes, 8);
  call_path(ump_handle, bytes, 5);
  call_path(ump_handle, bytes + 5, 3);
  CHECK(value(probe, BYTE_CALLS) == 1);
  CHECK(value(probe, UMP_CALLS) == 1);
  CHECK(value(probe, GONE_CALLS) == 3);
  CHECK(aud_midi_android_tap_detach(bytes_handle, 100) == 0);
  CHECK(aud_midi_android_tap_detach(ump_handle, 100) == 0);
  aud_midi_android_probe_free(probe);
}

// #############################################################################

int main(void) {
  rtsan_probe = getenv("AUD_TEST_RTSAN_PROBE") != NULL;
  if (rtsan_probe) {
    test_call_path_is_nonblocking();
    printf("aud_midi_android_tap_test: the probe allocation passed\n");
    return 0;
  }
  test_bytes_reach_the_tap();
  test_long_data_arrive_in_bounded_pieces();
  test_ump_words_are_assembled_across_chunks();
  test_ump_rest_does_not_survive_a_new_attach();
  test_long_ump_data_keep_packets_whole();
  test_gone_reaches_the_tap();
  test_every_slot_can_be_taken_once();
  test_detach_waits_for_the_calls_in_flight();
  test_gone_may_overlap_a_data_call();
  test_call_path_is_nonblocking();
  // Last: it leaks a slot on purpose.
  test_detach_leaks_a_slot_whose_call_never_returns();
  if (failures != 0) {
    fprintf(stderr, "%d checks failed\n", failures);
    return 1;
  }
  printf("aud_midi_android_tap_test: all checks passed\n");
  return 0;
}
