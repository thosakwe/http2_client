import 'dart:async';
import 'dart:io';
import 'package:cli_repl/cli_repl.dart';
import 'package:http/http.dart';
import 'package:http2_client/http2_client.dart';

Future<void> main() async {
  var client = Http2Client(maxOpenConnections: Platform.numberOfProcessors);
  var repl = Repl(prompt: 'Enter a URL, or "quit": ');

  client.onPush.listen((tuple) async {
    print('PUSH FROM ${tuple.item1}');
    dumpResponse(tuple.item1, await Response.fromStream(tuple.item2));
  });

  for (var url in repl.run()) {
    if (url == 'quit') break;
    var response = await client.get(url, headers: {
      'accept': '*/*',
      'accept-encoding': 'gzip, deflate',
      'user-agent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/71.0.3578.98 Safari/537.36'
    });
    dumpResponse(url, response);
  }

  client.close();
}

void dumpResponse(url, Response response) {
  print('Response from $url: ${response.statusCode} ${response.reasonPhrase}');
  print('Headers:');
  response.headers.forEach((k, v) {
    print('$k: $v');
  });
  print('\n${response.body}');
}
