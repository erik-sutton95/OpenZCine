import 'dart:async';
import 'dart:typed_data';

/// Thrown when the underlying stream closes before a [SocketReader.readExact]
/// request could be satisfied.
class SocketReaderClosedException implements Exception {
  /// Creates the exception with a description of how many bytes were still needed.
  SocketReaderClosedException(this.message);

  /// Human-readable description.
  final String message;

  @override
  String toString() => message;
}

/// Buffers bytes from a byte stream (e.g. a `Socket`) and hands them out in
/// exact-length chunks. Subscribes once; callers `await readExact(n)` in order.
class SocketReader {
  /// Creates a [SocketReader] that subscribes to [stream] immediately.
  SocketReader(Stream<Uint8List> stream) {
    _sub = stream.listen(_onData, onError: _onError, onDone: _onDone);
  }

  late final StreamSubscription<Uint8List> _sub;
  final BytesBuilder _buffer = BytesBuilder();
  final List<_PendingRead> _pending = [];
  Object? _error;
  bool _done = false;

  void _onData(Uint8List chunk) {
    _buffer.add(chunk);
    _drain();
  }

  void _onError(Object error) {
    _error = error;
    for (final p in _pending) {
      p.completer.completeError(error);
    }
    _pending.clear();
  }

  void _onDone() {
    _done = true;
    _failPending();
  }

  void _drain() {
    while (_pending.isNotEmpty && _buffer.length >= _pending.first.count) {
      final pending = _pending.removeAt(0);
      final all = _buffer.takeBytes();
      pending.completer.complete(Uint8List.sublistView(all, 0, pending.count));
      _buffer.add(Uint8List.sublistView(all, pending.count));
    }
  }

  void _failPending() {
    for (final p in _pending) {
      p.completer.completeError(
        SocketReaderClosedException(
          'Stream closed before ${_pendingDescription(p)}',
        ),
      );
    }
    _pending.clear();
  }

  String _pendingDescription(_PendingRead p) => '${p.count} bytes arrived';

  /// Completes with exactly [count] bytes, or errors if the stream closes first.
  Future<Uint8List> readExact(int count) {
    if (_error != null) return Future.error(_error!);
    final completer = Completer<Uint8List>();
    _pending.add(_PendingRead(count, completer));
    if (_done) {
      _failPending();
    } else {
      _drain();
    }
    return completer.future;
  }

  /// Cancels the underlying subscription.
  Future<void> close() => _sub.cancel();
}

class _PendingRead {
  _PendingRead(this.count, this.completer);

  final int count;
  final Completer<Uint8List> completer;
}
