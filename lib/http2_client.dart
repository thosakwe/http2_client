import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart';
import 'package:http/io_client.dart';
import 'package:http2/http2.dart';
import 'package:http_parser/http_parser.dart';
import 'package:tuple/tuple.dart';

/// A [BaseClient] implementation that speaks both HTTP/2 and HTTP/1,
/// and supports maintaining connections across requests.
class Http2Client extends BaseClient {
  /// A [BaseClient] that will handle connections to servers which do not
  /// support HTTP/2.
  ///
  /// Defaults to [IOClient].
  final BaseClient http1Client;

  /// If `true` (default), automatically decodes `gzip` and `deflate` bodies.
  final bool autoUncompress;

  /// Whether to keep sockets used for HTTP/2 connections open.
  ///
  /// If `true` (default), then all created [SecureSocket]s will remain
  /// open, until [close] is called.
  final bool maintainOpenConnections;

  /// The maximum number of connections to keep open at a time,
  /// or `-1`, in which case there will be no limit.
  ///
  /// Defaults to `-1`.
  final int maxOpenConnections;

  /// Handler triggered when an attempt to connect a [SecureSocket] encounters
  /// an invalid [X509Certificate].
  final bool Function(X509Certificate) onBadCertificate;

  /// A [SecurityContext] to be passed to every [SecureSocket].
  final SecurityContext context;

  /// An optional timeout to limit the time spent on connections.
  final Duration timeout;

  final Map<String, ClientTransportConnection> _sockets = {};
  final StreamController<Tuple2<Uri, StreamedResponse>> _onPush =
      StreamController();

  Http2Client(
      {BaseClient http1Client,
      this.autoUncompress = true,
      this.maintainOpenConnections = true,
      this.maxOpenConnections = -1,
      this.onBadCertificate,
      this.context,
      this.timeout})
      : http1Client = http1Client ?? IOClient() {
    assert(maxOpenConnections == -1 || maxOpenConnections > 0,
        'maxOpenConnections must be -1, or > 0.');
  }

  /// Fires whenever the server pushes content to the client that
  /// was not explicitly requested.
  Stream<Tuple2<Uri, StreamedResponse>> get onPush => _onPush.stream;

  @override
  Future<StreamedResponse> send(BaseRequest request) {
    return _send(request, []);
  }

  Future<SecureSocket> _connect(BaseRequest request) async {
    try {
      var secureSocket =
          await SecureSocket.connect(request.url.host, request.url.port,
              supportedProtocols: [
                'h2',
                'http/1.1',
                'http/1.0',
              ],
              onBadCertificate: onBadCertificate,
              context: context,
              timeout: timeout);
      if (secureSocket.selectedProtocol != 'h2') {
        //'Failed to negogiate http/2 via alpn. Maybe server
        //    doesn't support http/2.;
        await secureSocket.close();
        return null;
      }
      return secureSocket;
    } catch (e) {
      return null;
    }
  }

  Future<StreamedResponse> _send(
      BaseRequest request, List<RedirectInfo> redirects) async {
    if (request.url.scheme != 'https') {
      return http1Client.send(request);
    } else {
      ClientTransportConnection connection;

      if (maintainOpenConnections && _sockets.containsKey(request.url.host)) {
        // If this transport is closed, form a new connection.
        connection = _sockets[request.url.host];
        if (!connection.isOpen) {
          connection = null;
          _sockets.remove(request.url.host);
        }
      }

      if (connection == null) {
        var socket = await _connect(request);
        if (socket == null) {
          // This isn't HTTP/2, fall back to HTTP/1.x
          return http1Client.send(request);
        } else {
          // Close any connections that have overstayed their welcome.
          if (maxOpenConnections > -1) {
            while (_sockets.length >= maxOpenConnections) {
              var transport = _sockets.remove(_sockets.keys.first);
              await transport.finish();
            }
          }

          var transport = ClientTransportConnection.viaSocket(socket);

          if (maintainOpenConnections) {
            _sockets[request.url.host] = transport;

            // If the socket closes before another use, remove it from
            // memory.
            // transport.
          }

          connection = transport;
        }
      }

      var transport = connection;
      if (transport == null) {
        // Use HTTP/1.1 instead.
        return await http1Client.send(request);
      }

      var headers = [
        Header.ascii(':authority', request.url.authority),
        Header.ascii(':method', request.method),
        Header.ascii(
          ':path',
          Uri(
            fragment: !request.url.hasFragment ? null : request.url.fragment,
            query: !request.url.hasQuery ? null : request.url.query,
            path: request.url.path,
          ).toString(),
        ),
        Header.ascii(':scheme', request.url.scheme),
      ];

      request.headers.forEach((k, v) {
        headers.add(Header.ascii(k.toLowerCase(), v));
      });

      var stream = transport.makeRequest(headers, endStream: false);

      stream.peerPushes.listen((push) {
        _fromStream(request, push.stream, redirects, push.requestHeaders)
            .then(_onPush.add);
      });

      await request
          .finalize()
          .forEach(stream.sendData)
          .then((_) => stream.outgoingMessages.close());

      var t = await _fromStream(request, stream, redirects);
      var response = t.item2;
      if (maintainOpenConnections) response;
      return transport.finish().then((_) => response);
    }
  }

  /// Taken from `dart:_http`. Finds the HTTP reason phrase for a given [statusCode].
  static String findReasonPhrase(int statusCode) {
    switch (statusCode) {
      case HttpStatus.continue_:
        return 'Continue';
      case HttpStatus.switchingProtocols:
        return 'Switching Protocols';
      case HttpStatus.ok:
        return 'OK';
      case HttpStatus.created:
        return 'Created';
      case HttpStatus.accepted:
        return 'Accepted';
      case HttpStatus.nonAuthoritativeInformation:
        return 'Non-Authoritative Information';
      case HttpStatus.noContent:
        return 'No Content';
      case HttpStatus.resetContent:
        return 'Reset Content';
      case HttpStatus.partialContent:
        return 'Partial Content';
      case HttpStatus.multipleChoices:
        return 'Multiple Choices';
      case HttpStatus.movedPermanently:
        return 'Moved Permanently';
      case HttpStatus.found:
        return 'Found';
      case HttpStatus.seeOther:
        return 'See Other';
      case HttpStatus.notModified:
        return 'Not Modified';
      case HttpStatus.useProxy:
        return 'Use Proxy';
      case HttpStatus.temporaryRedirect:
        return 'Temporary Redirect';
      case HttpStatus.badRequest:
        return 'Bad Request';
      case HttpStatus.unauthorized:
        return 'Unauthorized';
      case HttpStatus.paymentRequired:
        return 'Payment Required';
      case HttpStatus.forbidden:
        return 'Forbidden';
      case HttpStatus.notFound:
        return 'Not Found';
      case HttpStatus.methodNotAllowed:
        return 'Method Not Allowed';
      case HttpStatus.notAcceptable:
        return 'Not Acceptable';
      case HttpStatus.proxyAuthenticationRequired:
        return 'Proxy Authentication Required';
      case HttpStatus.requestTimeout:
        return 'Request Time-out';
      case HttpStatus.conflict:
        return 'Conflict';
      case HttpStatus.gone:
        return 'Gone';
      case HttpStatus.lengthRequired:
        return 'Length Required';
      case HttpStatus.preconditionFailed:
        return 'Precondition Failed';
      case HttpStatus.requestEntityTooLarge:
        return 'Request Entity Too Large';
      case HttpStatus.requestUriTooLong:
        return 'Request-URI Too Long';
      case HttpStatus.unsupportedMediaType:
        return 'Unsupported Media Type';
      case HttpStatus.requestedRangeNotSatisfiable:
        return 'Requested range not satisfiable';
      case HttpStatus.expectationFailed:
        return 'Expectation Failed';
      case HttpStatus.internalServerError:
        return 'Internal Server Error';
      case HttpStatus.notImplemented:
        return 'Not Implemented';
      case HttpStatus.badGateway:
        return 'Bad Gateway';
      case HttpStatus.serviceUnavailable:
        return 'Service Unavailable';
      case HttpStatus.gatewayTimeout:
        return 'Gateway Time-out';
      case HttpStatus.httpVersionNotSupported:
        return 'Http Version not supported';
      default:
        return 'Status $statusCode';
    }
  }

  @override
  void close() {
    super.close();
    http1Client.close();
    _onPush.close();
    _sockets.values.forEach((c) => c.finish());
  }

  Future<Tuple2<Uri, StreamedResponse>> _fromStream(BaseRequest request,
      ClientTransportStream stream, List<RedirectInfo> redirects,
      [List<Header> requestHeaders = const []]) {
    var url = request.url;
    var headers = CaseInsensitiveMap<String>();

    void applyHeader(Header h) {
      var name = utf8.decode(h.name), value = utf8.decode(h.value);
      headers[name] = value;
    }

    var c = Completer<Tuple2<Uri, StreamedResponse>>();
    var body = StreamController<List<int>>();
    requestHeaders.forEach(applyHeader);

    void complete() {
      var statusCode = int.tryParse(headers.remove(':status').toString());

      if (statusCode == null) {
        if (!c.isCompleted) {
          c.completeError(
              StateError('Server $url did not send a response status code.'));
        }
      }

      if (!c.isCompleted) {
        if (request.followRedirects && headers.containsKey('location')) {
          var location = request.url.resolve(headers['location']);
          if (redirects.length >= request.maxRedirects) {
            if (!c.isCompleted) {
              c.completeError(RedirectException(
                  'max redirect count of ${request.maxRedirects} exceeded',
                  redirects));
            }
          }

          // Follow the redirect...
          var newRedirects = List<RedirectInfo>.from(redirects)
            ..add(_RedirectInfo(request.method, statusCode, location));
          var rq = Request(statusCode == 307 ? request.method : 'GET', location)
            ..followRedirects = request.followRedirects
            ..headers.addAll(request.headers)
            ..maxRedirects = request.maxRedirects;

          if (request is Request) {
            rq.encoding = request.encoding;
            if (statusCode == 307) {
              rq.bodyBytes = request.bodyBytes;
            }
          }

          if (request.contentLength != null) {
            rq.headers['content-length'] = request.contentLength.toString();
          }

          if (!c.isCompleted) {
            c.complete(
                _send(rq, newRedirects).then((r) => Tuple2(location, r)));
          }
        } else {
          var stream = body.stream;

          if (autoUncompress && headers['content-encoding'] == 'gzip') {
            stream = stream.transform(gzip.decoder);
          } else if (autoUncompress &&
              headers['content-encoding'] == 'deflate') {
            stream = stream.transform(zlib.decoder);
          }

          c.complete(Tuple2(
            url,
            StreamedResponse(
              stream,
              statusCode,
              contentLength: int.tryParse(headers['content-length'].toString()),
              headers: headers,
              request: request,
              reasonPhrase: findReasonPhrase(statusCode),
              isRedirect: headers.containsKey('location'),
            ),
          ));
        }
      }
    }

    stream.incomingMessages.listen(
      (message) {
        if (message is HeadersStreamMessage) {
          message.headers.forEach(applyHeader);
        } else if (message is DataStreamMessage) {
          body.add(message.bytes);
        } else {
          if (!c.isCompleted) {
            c.completeError(ArgumentError.value(message, 'message',
                'must be HeadersStreamMessage or DataStreamMessage'));
          }
        }
      },
      cancelOnError: true,
      onDone: () {
        complete();
        body.close();
      },
      onError: (e, StackTrace st) {
        if (!c.isCompleted) c.completeError(e, st);
      },
    );

    return c.future;
  }
}

class _RedirectInfo implements RedirectInfo {
  @override
  final String method;
  @override
  final int statusCode;
  @override
  final Uri location;

  _RedirectInfo(this.method, this.statusCode, this.location);
}
