// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:aud_audio_plugin/aud_audio_plugin.dart';
import 'package:ffi/ffi.dart';

// .............................................................................
typedef _ReceiverNative = Void Function(Pointer<Utf8>);
typedef _ConnectNative = Int32 Function(
  Int64,
  Pointer<NativeFunction<_ReceiverNative>>,
);
typedef _ConnectDart = int Function(
  int,
  Pointer<NativeFunction<_ReceiverNative>>,
);
typedef _SendNative = Int32 Function(Int64, Pointer<Utf8>);
typedef _SendDart = int Function(int, Pointer<Utf8>);
typedef _DisconnectNative = Void Function(Int64);
typedef _DisconnectDart = void Function(int);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

// #############################################################################
/// The editor's end of the shell protocol inside the AUv3 extension
/// (ticket 64, plugin-012): the editor's Dart code and the unit share the
/// extension's process, so [AudShellMessage]s travel as JSON through the C
/// functions of `src/aud_auv3_editor_api.h`, called with `dart:ffi`. The
/// extension starts the editor with the argument `--aud-auv3-instance=<n>`
/// ([instanceOf]); the editor connects with it, says hello and gets the
/// welcome, as an editor of the VST3 shell does over its socket.
final class AudAuv3Shell {
  AudAuv3Shell._(this.instance, DynamicLibrary library)
    : _connect = library.lookupFunction<_ConnectNative, _ConnectDart>(
        'aud_auv3_editor_connect',
      ),
      _send = library.lookupFunction<_SendNative, _SendDart>(
        'aud_auv3_editor_send',
      ),
      _disconnect = library.lookupFunction<_DisconnectNative, _DisconnectDart>(
        'aud_auv3_editor_disconnect',
      ),
      _free = library.lookupFunction<_FreeNative, _FreeDart>(
        'aud_auv3_editor_free',
      ) {
    _receiver = NativeCallable<_ReceiverNative>.listener(_receive);
    if (_connect(instance, _receiver.nativeFunction) != 0) {
      _receiver.close();
      throw StateError('The unit has no editor of instance $instance');
    }
  }

  // ...........................................................................
  /// Connects the editor of the unit's [instance] through the functions of
  /// [library] - by default those the extension's process exports. Throws
  /// a [StateError] when the unit has no editor of that instance.
  factory AudAuv3Shell.connect(int instance, {DynamicLibrary? library}) =>
      AudAuv3Shell._(instance, library ?? DynamicLibrary.process());

  // ...........................................................................
  /// The start argument that names the instance.
  static const String instanceArgument = '--aud-auv3-instance=';

  // ...........................................................................
  /// The instance in the [arguments] of the editor's entry point; null when
  /// the editor does not run inside the extension.
  static int? instanceOf(List<String> arguments) {
    for (final argument in arguments) {
      if (argument.startsWith(instanceArgument)) {
        return int.tryParse(argument.substring(instanceArgument.length));
      }
    }
    return null;
  }

  // ...........................................................................
  /// The instance of the editor's unit.
  final int instance;

  // ...........................................................................
  /// The messages of the unit; the stream ends with [close].
  Stream<AudShellMessage> get messages => _messages.stream;

  // ...........................................................................
  /// Sends [message] to the unit; nothing after [close].
  void send(AudShellMessage message) {
    if (_closed) return;
    final text = jsonEncode(message.toJson()).toNativeUtf8();
    try {
      _send(instance, text);
    } finally {
      malloc.free(text);
    }
  }

  // ...........................................................................
  /// Disconnects from the unit; it sends nothing after, and [messages]
  /// ends.
  void close() {
    if (_closed) return;
    _closed = true;
    _disconnect(instance);
    _receiver.close();
    // The stream ends for a listener, also one that comes later; nobody
    // waits for it.
    unawaited(_messages.close());
  }

  // ...........................................................................
  final _ConnectDart _connect;
  final _SendDart _send;
  final _DisconnectDart _disconnect;
  final _FreeDart _free;
  late final NativeCallable<_ReceiverNative> _receiver;
  final _messages = StreamController<AudShellMessage>();
  bool _closed = false;

  void _receive(Pointer<Utf8> text) {
    final json = text.toDartString();
    _free(text);
    if (_closed) return;
    final message = jsonDecode(json);
    if (message is Map<String, Object?>) {
      _messages.add(AudShellMessage.fromJson(message));
    }
  }
}
