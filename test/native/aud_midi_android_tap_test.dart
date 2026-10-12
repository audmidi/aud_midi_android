// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

// Runs the host-side test of the native tap library,
// test/native/aud_midi_android_tap_test.c, through scripts/test-native.js
// under the sanitizers this machine has; the RealtimeSanitizer build needs
// LLVM from Homebrew and is left out here.
void main() {
  // Whether `command --version` runs on this machine.
  bool has(String command) {
    try {
      return Process.runSync(command, ['--version']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  final node = has('node');
  final compiler = ['clang', 'cc', 'gcc'].any(has);
  final skip = !node
      ? 'node is not installed'
      : !compiler
      ? 'no C compiler (clang, cc or gcc)'
      : false;

  group('scripts/test-native.js', () {
    test('passes the native tap test under the sanitizers', () async {
      final result = await Process.run('node', [
        'scripts/test-native.js',
        '--no-rtsan',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    }, skip: skip);
  });
}
