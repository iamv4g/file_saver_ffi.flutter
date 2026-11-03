import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Local HTTP server for network save tests.
///
/// Routes:
/// - `/file`  → [payload] with Content-Length
/// - `/chunked` → [payload] in 64 KiB chunks, without Content-Length
/// - `/gzip`  → [payload] gzip-encoded, with the Content-Length of the
///   encoded body
/// - `/auth`  → [payload] only if `X-Token: secret`, otherwise 401
/// - `/404`   → 404
/// - `/slow`  → first 64 KiB of [payload], then hangs until [close]
/// - `/no-headers` → accepts the request and sends nothing until [close]
class TestHttpServer {
  TestHttpServer._(this._server, this.payload);

  static Future<TestHttpServer> start(Uint8List payload) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final testServer = TestHttpServer._(server, payload);
    server.listen(testServer._handle);
    return testServer;
  }

  final HttpServer _server;
  final Uint8List payload;
  final _hang = Completer<void>();

  String url(String path) => 'http://127.0.0.1:${_server.port}$path';

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    switch (request.uri.path) {
      case '/file':
        response.contentLength = payload.length;
        response.add(payload);
      case '/chunked':
        for (var offset = 0; offset < payload.length; offset += 64 * 1024) {
          response.add(
            payload.sublist(offset, min(offset + 64 * 1024, payload.length)),
          );
          await response.flush();
        }
      case '/gzip':
        final encoded = gzip.encode(payload);
        response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        response.contentLength = encoded.length;
        response.add(encoded);
      case '/auth':
        if (request.headers.value('X-Token') != 'secret') {
          response.statusCode = HttpStatus.unauthorized;
        } else {
          response.contentLength = payload.length;
          response.add(payload);
        }
      case '/slow':
        response.contentLength = payload.length;
        response.add(payload.sublist(0, 64 * 1024));
        await response.flush();
        await _hang.future;
      case '/no-headers':
        await _hang.future;
      default:
        response.statusCode = HttpStatus.notFound;
    }
    try {
      await response.close();
    } catch (_) {
      // The client may have aborted the request.
    }
  }

  Future<void> close() async {
    if (!_hang.isCompleted) _hang.complete();
    await _server.close(force: true);
  }
}
