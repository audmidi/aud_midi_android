// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_midi_android.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef __ANDROID__
#include <android/log.h>
#endif

// #############################################################################
// Slots

enum { SLOT_FREE = 0, SLOT_ACTIVE = 1, SLOT_CLOSING = 2, SLOT_LEAKED = 3 };

// The bytes of an incomplete UMP that wait for the next chunk: up to three
// words of a four-word packet plus up to three bytes of a word.
#define REST_CAPACITY 15

typedef struct {
  _Atomic int32_t state;
  _Atomic uint32_t generation;
  // Calls inside the slot; a detach waits until it is 0.
  _Atomic int32_t in_flight;
  AudMidiAndroidTapFunction function;
  void *user;
  bool ump;
  // The assembler state, touched by the data thread only.
  uint8_t rest[REST_CAPACITY];
  uint32_t rest_length;
} Slot;

static Slot slots[AUD_MIDI_ANDROID_TAP_SLOTS];

// Serialises attach and detach; the call path never takes it.
static pthread_mutex_t table_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t next_generation = 1;

static void log_leak(int index) {
#ifdef __ANDROID__
  __android_log_print(ANDROID_LOG_ERROR, "aud_midi_android",
                      "tap slot %d: a call did not return, the slot leaks",
                      index);
#else
  fprintf(stderr, "aud_midi_android: tap slot %d: a call did not return, the "
                  "slot leaks\n",
          index);
#endif
}

static int64_t handle_of(int index, uint32_t generation) {
  return ((int64_t)generation << 32) | (int64_t)(index + 1);
}

static int index_of(int64_t handle) {
  const int64_t index = (handle & 0xffffffff) - 1;
  if (index < 0 || index >= AUD_MIDI_ANDROID_TAP_SLOTS) return -1;
  return (int)index;
}

static uint32_t generation_of(int64_t handle) {
  return (uint32_t)((uint64_t)handle >> 32);
}

// Counts the caller in; returns the slot when it is active for [handle],
// else NULL. A detach that saw the count at 0 cannot complete while the
// caller is inside; one that set the state to closing first is seen here.
static Slot *enter(int64_t handle) {
  const int index = index_of(handle);
  if (index < 0) return NULL;
  Slot *slot = &slots[index];
  atomic_fetch_add(&slot->in_flight, 1);
  if (atomic_load(&slot->state) != SLOT_ACTIVE ||
      atomic_load(&slot->generation) != generation_of(handle)) {
    atomic_fetch_sub(&slot->in_flight, 1);
    return NULL;
  }
  return slot;
}

static void leave(Slot *slot) { atomic_fetch_sub(&slot->in_flight, 1); }

int64_t aud_midi_android_tap_attach(AudMidiAndroidTapFunction function,
                                    void *user, int32_t ump) {
  if (function == NULL) return AUD_MIDI_ANDROID_PARAM_ERROR;
  pthread_mutex_lock(&table_lock);
  int64_t handle = AUD_MIDI_ANDROID_FULL_ERROR;
  for (int index = 0; index < AUD_MIDI_ANDROID_TAP_SLOTS; index++) {
    Slot *slot = &slots[index];
    if (atomic_load(&slot->state) != SLOT_FREE) continue;
    const uint32_t generation = next_generation++;
    if (next_generation == 0) next_generation = 1;
    slot->function = function;
    slot->user = user;
    slot->ump = ump != 0;
    slot->rest_length = 0;
    atomic_store(&slot->generation, generation);
    atomic_store(&slot->state, SLOT_ACTIVE);
    handle = handle_of(index, generation);
    break;
  }
  pthread_mutex_unlock(&table_lock);
  return handle;
}

int32_t aud_midi_android_tap_detach(int64_t handle, int32_t timeout_ms) {
  const int index = index_of(handle);
  if (index < 0) return AUD_MIDI_ANDROID_PARAM_ERROR;
  Slot *slot = &slots[index];
  pthread_mutex_lock(&table_lock);
  if (atomic_load(&slot->state) != SLOT_ACTIVE ||
      atomic_load(&slot->generation) != generation_of(handle)) {
    pthread_mutex_unlock(&table_lock);
    return AUD_MIDI_ANDROID_PARAM_ERROR;
  }
  atomic_store(&slot->state, SLOT_CLOSING);
  pthread_mutex_unlock(&table_lock);

  const int64_t deadline =
      aud_midi_android_now_ns() + (int64_t)timeout_ms * 1000000;
  bool drained = true;
  while (atomic_load(&slot->in_flight) != 0) {
    if (aud_midi_android_now_ns() > deadline) {
      drained = false;
      break;
    }
    const struct timespec pause = {0, 50000};
    nanosleep(&pause, NULL);
  }

  pthread_mutex_lock(&table_lock);
  if (drained) {
    slot->function = NULL;
    slot->user = NULL;
    atomic_store(&slot->state, SLOT_FREE);
  } else {
    // The call may still touch the function and the user; the slot stays
    // as it is, never reused.
    atomic_store(&slot->state, SLOT_LEAKED);
    log_leak(index);
  }
  pthread_mutex_unlock(&table_lock);
  return drained ? 0 : AUD_MIDI_ANDROID_TIMEOUT_ERROR;
}

// #############################################################################
// Calls

static const uint8_t ump_sizes[16] = {1, 1, 1, 2, 2, 4, 1, 1,
                                      2, 2, 2, 3, 3, 4, 4, 4};

// Feeds [count] bytes (at most AUD_MIDI_ANDROID_TAP_CHUNK_BYTES) of a UMP
// port into the assembler of [slot] and calls the tap with the complete
// packets; returns whether it was called.
static bool send_ump(Slot *slot, const uint8_t *data, uint32_t count,
                     int64_t host_time_ns) {
  uint8_t bytes[REST_CAPACITY + AUD_MIDI_ANDROID_TAP_CHUNK_BYTES];
  uint32_t words[(REST_CAPACITY + AUD_MIDI_ANDROID_TAP_CHUNK_BYTES) / 4];
  memcpy(bytes, slot->rest, slot->rest_length);
  memcpy(bytes + slot->rest_length, data, count);
  const uint32_t total = slot->rest_length + count;
  const uint32_t word_count = total / 4;
  for (uint32_t w = 0; w < word_count; w++) {
    const uint8_t *b = &bytes[w * 4];
    words[w] = (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 |
               (uint32_t)b[2] << 8 | (uint32_t)b[3];
  }
  uint32_t complete = 0;
  while (complete < word_count) {
    const uint32_t size = ump_sizes[words[complete] >> 28];
    if (complete + size > word_count) break;
    complete += size;
  }
  slot->rest_length = total - complete * 4;
  memcpy(slot->rest, bytes + complete * 4, slot->rest_length);
  if (complete == 0) return false;
  slot->function(slot->user, AUD_MIDI_ANDROID_TAP_UMP, words, complete,
                 host_time_ns);
  return true;
}

int32_t aud_midi_android_tap_send(int64_t handle, const uint8_t *data,
                                  uint32_t count, int64_t host_time_ns) {
  if (count == 0 || data == NULL) return 0;
  if (host_time_ns == 0) host_time_ns = aud_midi_android_now_ns();
  Slot *slot = enter(handle);
  if (slot == NULL) return 0;
  bool called = false;
  uint32_t position = 0;
  while (position < count) {
    uint32_t piece = count - position;
    if (piece > AUD_MIDI_ANDROID_TAP_CHUNK_BYTES) {
      piece = AUD_MIDI_ANDROID_TAP_CHUNK_BYTES;
    }
    if (slot->ump) {
      called |= send_ump(slot, data + position, piece, host_time_ns);
    } else {
      slot->function(slot->user, AUD_MIDI_ANDROID_TAP_BYTES, data + position,
                     piece, host_time_ns);
      called = true;
    }
    position += piece;
  }
  leave(slot);
  return called ? 1 : 0;
}

int32_t aud_midi_android_tap_gone(int64_t handle, int64_t host_time_ns) {
  if (host_time_ns == 0) host_time_ns = aud_midi_android_now_ns();
  Slot *slot = enter(handle);
  if (slot == NULL) return 0;
  slot->function(slot->user, AUD_MIDI_ANDROID_TAP_GONE, NULL, 0,
                 host_time_ns);
  leave(slot);
  return 1;
}

// #############################################################################
// Inspection

int32_t aud_midi_android_tap_in_flight(int64_t handle) {
  const int index = index_of(handle);
  if (index < 0) return -1;
  Slot *slot = &slots[index];
  if (atomic_load(&slot->state) != SLOT_ACTIVE ||
      atomic_load(&slot->generation) != generation_of(handle)) {
    return -1;
  }
  return atomic_load(&slot->in_flight);
}

int32_t aud_midi_android_tap_count(void) {
  int32_t count = 0;
  pthread_mutex_lock(&table_lock);
  for (int index = 0; index < AUD_MIDI_ANDROID_TAP_SLOTS; index++) {
    if (atomic_load(&slots[index].state) != SLOT_FREE) count++;
  }
  pthread_mutex_unlock(&table_lock);
  return count;
}

// #############################################################################
// Probe

struct AudMidiAndroidProbe {
  _Atomic int64_t ump_calls;
  _Atomic int64_t byte_calls;
  _Atomic int64_t gone_calls;
  _Atomic int64_t words;
  _Atomic int64_t bytes;
  _Atomic int64_t last_time;
  _Atomic int64_t sum;
  _Atomic int64_t first;
  _Atomic int64_t overlaps;
  _Atomic int64_t min_delay;
  _Atomic int32_t inside;
};

static void probe_tap(void *user, uint32_t kind, const void *data,
                      uint32_t count, int64_t host_time_ns) {
  AudMidiAndroidProbe *probe = user;
  if (atomic_fetch_add(&probe->inside, 1) != 0) {
    atomic_fetch_add(&probe->overlaps, 1);
  }
  atomic_store(&probe->last_time, host_time_ns);
  if (kind == AUD_MIDI_ANDROID_TAP_GONE) {
    atomic_fetch_add(&probe->gone_calls, 1);
  } else {
    const int64_t delay = aud_midi_android_now_ns() - host_time_ns;
    if (delay < atomic_load(&probe->min_delay)) {
      atomic_store(&probe->min_delay, delay);
    }
    int64_t sum = 0;
    if (kind == AUD_MIDI_ANDROID_TAP_UMP) {
      const uint32_t *words = data;
      for (uint32_t i = 0; i < count; i++) sum += words[i];
      atomic_fetch_add(&probe->ump_calls, 1);
      atomic_fetch_add(&probe->words, count);
      if (count > 0) atomic_store(&probe->first, words[0]);
    } else {
      const uint8_t *bytes = data;
      for (uint32_t i = 0; i < count; i++) sum += bytes[i];
      atomic_fetch_add(&probe->byte_calls, 1);
      atomic_fetch_add(&probe->bytes, count);
      if (count > 0) atomic_store(&probe->first, bytes[0]);
    }
    atomic_fetch_add(&probe->sum, sum);
  }
  atomic_fetch_sub(&probe->inside, 1);
}

AudMidiAndroidProbe *aud_midi_android_probe_create(void) {
  AudMidiAndroidProbe *probe = calloc(1, sizeof(AudMidiAndroidProbe));
  atomic_store(&probe->min_delay, INT64_MAX);
  return probe;
}

void aud_midi_android_probe_free(AudMidiAndroidProbe *probe) { free(probe); }

AudMidiAndroidTapFunction aud_midi_android_probe_function(void) {
  return probe_tap;
}

void aud_midi_android_probe_read(const AudMidiAndroidProbe *probe,
                                 int64_t *out, uint32_t capacity) {
  const int64_t values[AUD_MIDI_ANDROID_PROBE_VALUES] = {
      atomic_load(&probe->ump_calls), atomic_load(&probe->byte_calls),
      atomic_load(&probe->gone_calls), atomic_load(&probe->words),
      atomic_load(&probe->bytes),     atomic_load(&probe->last_time),
      atomic_load(&probe->sum),       atomic_load(&probe->first),
      atomic_load(&probe->overlaps),  atomic_load(&probe->min_delay),
  };
  if (capacity > AUD_MIDI_ANDROID_PROBE_VALUES) {
    capacity = AUD_MIDI_ANDROID_PROBE_VALUES;
  }
  memcpy(out, values, capacity * sizeof(int64_t));
}

int64_t aud_midi_android_now_ns(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (int64_t)now.tv_sec * 1000000000 + now.tv_nsec;
}
