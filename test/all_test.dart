import 'dart:convert';
import 'dart:io';
import 'package:angel_framework/angel_framework.dart';
import 'package:angel_framework/http.dart';
import 'package:angel_framework/http2.dart';
import 'package:http/http.dart';
import 'package:http2_client/http2_client.dart';
import 'package:test/test.dart';

void main() {
  Angel app;
  AngelHttp http;
  AngelHttp2 http2;
  Http2Client client;
  Uri baseUrl, httpUrl;

  setUp(() async {
    app = Angel();

    app.get('/', (req, res) => 'Hello!');

    app.get('/headers', (req, res) => req.headers.value('x-foo'));

    app.post('/body', (req, res) {
      return req.parseBody().then((_) {
        var body = req.bodyAsMap;
        print('Incoming body: $body');
        return body;
      });
    });

    app.get('/redirect', (req, res) => res.redirect('/'));

    app.get('/compress', (req, res) {
      res.encoders['gzip'] = gzip.encoder;
      res.encoders['deflate'] = zlib.encoder;
      return 'Yes';
    });

    var ctx = SecurityContext()
      ..useCertificateChain('dev.pem')
      ..usePrivateKey('dev.key', password: 'dartdart')
      ..setAlpnProtocols(['h2'], true);
    http = AngelHttp(app);
    http2 = AngelHttp2(app, ctx)..onHttp1.listen(http.handleRequest);
    await http.startServer();
    await http2.startServer();
    baseUrl = http2.uri;
    httpUrl = http.uri;
    print('Listening at $baseUrl');

    client = Http2Client(
      onBadCertificate: (_) => true,
    );
  });

  tearDown(() async {
    await app.close();
    await http.close();
    await http2.close();
    client.close();
  });

  test('can send and complete', () async {
    var response = await client.get(baseUrl);
    expect(response.body, json.encode('Hello!'));
  });

  test('sends headers', () async {
    var response = await client
        .get(baseUrl.replace(path: 'headers'), headers: {'x-foo': 'bar'});
    expect(response.body, json.encode('bar'));
  });

  test('sends body', () async {
    var response = await client
        .post(baseUrl.replace(path: 'body'), body: {'x-foo': 'bar'});
    expect(response.body, json.encode({'x-foo': 'bar'}));
  });

  test('can fallback to http', () async {
    var response = await client.get(httpUrl);
    expect(response.body, json.encode('Hello!'));
  });

  test('follow redirects', () async {
    var response = await client.get(baseUrl.replace(path: 'redirect'));
    expect(response.body, json.encode('Hello!'));
  });

  test('max redirects', () async {
    var rq = Request('GET', baseUrl.replace(path: 'redirect'))
      ..maxRedirects = 0;

    try {
      await client.send(rq);
      throw StateError('Should have thrown RedirectException');
    } on RedirectException {
      // success
    }
  });

  test('http/1 site fallback test', () async {
    var response = await client.get('https://naver.com');
    expect(response.statusCode, 200);
    expect(response.body, isNotEmpty);
  });

  group('uncompress', () {
    test('gzip', () async {
      var response = await client.get(baseUrl.replace(path: 'compress'),
          headers: {'accept-encoding': 'gzip'});
      expect(response.headers['content-encoding'], 'gzip');
      expect(response.body, json.encode('Yes'));
    });

    test('deflate', () async {
      var response = await client.get(baseUrl.replace(path: 'compress'),
          headers: {'accept-encoding': 'deflate'});
      expect(response.headers['content-encoding'], 'deflate');
      expect(response.body, json.encode('Yes'));
    });
  });
}
