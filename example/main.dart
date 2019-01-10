import 'dart:io';
import 'package:cli_repl/cli_repl.dart';
import 'package:http/http.dart';
import 'package:http2_client/http2_client.dart';

main() async {
  var client = Http2Client(maxOpenConnections: Platform.numberOfProcessors);
  var repl = Repl(prompt: 'Enter a URL, or "quit": ');

  client.onPush.listen((tuple) async {
    print('PUSH FROM ${tuple.item1}');
    dumpResponse(tuple.item1, await Response.fromStream(tuple.item2));
  });

  for (var url in repl.run()) {
    if (url == 'quit') break;
    var response = await client.get(url, headers: {
      'accept': 'text/html, application/json, text/*',
      'user-agent': 'dart-http2client-example'
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
