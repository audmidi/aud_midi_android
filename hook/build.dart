// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Builds the native tap library of the package, `libaud_midi_android.so`,
/// for Android; on every other target operating system it does nothing, so
/// that the aud_midi umbrella builds everywhere.
///
/// Flutter packages the library into the app, where the Java shim loads it
/// with `System.loadLibrary` and Dart reaches it through the code asset.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    if (input.config.code.targetOS != OS.android) return;

    await CBuilder.library(
      name: 'aud_midi_android',
      assetName: 'src/native/aud_midi_android_bindings.g.dart',
      sources: const ['src/aud_midi_android.c', 'src/aud_midi_android_jni.c'],
      includes: const ['src'],
      libraries: const ['log'],
    ).run(input: input, output: output);
  });
}
