# http2_client

[![pub package](https://img.shields.io/pub/v/http2_client.svg)](https://pub.dartlang.org/packages/http2_client)
[![Build Status](https://travis-ci.org/thosakwe/http2_client.svg?branch=master)](https://travis-ci.org/thosakwe/http2_client)

A `package:http` `BaseClient` that speaks HTTP/2, and can maintain connections between requests.

This can be dropped into any API that uses a
`BaseClient`, so you can seamlessly start working with
HTTP/2 right away.

It also can fallback to `HTTP/1.1` automatically.

## Installation

In your `pubspec.yaml`:

```yaml
dependencies:
  http2_client: ^1.0.0
```

## Example

Also see `example/main.dart`.

```dart
import 'dart:io';
import 'package:cli_repl/cli_repl.dart';
import 'package:http/http.dart';
import 'package:http2_client/http2_client.dart';

main() async {
  var client = Http2Client(maxOpenConnections: Platform.numberOfProcessors);
  var response = await client.get('https://example.com');
  print(response.body);
}
```
