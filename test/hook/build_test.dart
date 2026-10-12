// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:test/test.dart';

import '../../hook/build.dart' as build_hook;

// Runs the build hook for every target the umbrella builds for: Android
// gets the native tap library, all others nothing.
void main() {
  // The NDK the Flutter tool would pass; the Android build needs it.
  final sdk =
      Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'] ??
      '${Platform.environment['HOME']}/Library/Android/sdk';
  final ndks = Directory('$sdk/ndk');
  final ndk = ndks.existsSync()
      ? (ndks.listSync().whereType<Directory>().toList()
              ..sort((a, b) => a.path.compareTo(b.path)))
            .lastOrNull
      : null;

  group('hook/build.dart', () {
    for (final architecture in [Architecture.arm64, Architecture.x64]) {
      test('builds the tap library for Android $architecture', () async {
        await testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: OS.android,
          targetArchitecture: architecture,
          targetAndroidNdkApi: 24,
          check: (input, output) {
            final asset = output.assets.code.single;
            expect(
              asset.id,
              'package:aud_midi_android/src/native/'
              'aud_midi_android_bindings.g.dart',
            );
            expect(asset.file!.pathSegments.last, 'libaud_midi_android.so');
            expect(asset.linkMode, DynamicLoadingBundled());
            final kind = Process.runSync('file', [
              asset.file!.toFilePath(),
            ]).stdout;
            expect(
              kind,
              contains(
                architecture == Architecture.arm64 ? 'aarch64' : 'x86-64',
              ),
            );
          },
        );
      }, skip: ndk == null ? 'no Android NDK under $sdk/ndk' : false);
    }

    for (final os in [OS.linux, OS.windows, OS.macOS, OS.iOS]) {
      test('builds nothing for $os', () async {
        await testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: os,
          targetArchitecture: Architecture.arm64,
          targetIOSSdk: os == OS.iOS ? IOSSdk.iPhoneOS : null,
          targetIOSVersion: os == OS.iOS ? 15 : null,
          targetMacOSVersion: os == OS.macOS ? 12 : null,
          check: (input, output) => expect(output.assets.code, isEmpty),
        );
      });
    }
  });
}
