import 'dart:io';

import 'package:dart_cli/dart_cli.dart';
import 'package:path/path.dart';

void main(List<String> args) {
  final tempDir = Directory.systemTemp.createTempSync('dart_temp_project');
  final pubspec = join(tempDir.path, 'pubspec.yaml');
  final dartSdkVersion = [
    'dart',
    '--version',
  ].run(showCommand: false, showMessages: false).output.split(' ')[3];

  for (final arg in args) {
    pubspec.writeln('''name: temp
environment:
  sdk: ^$dartSdkVersion
dependencies:
  ${arg.replaceAll('>>', '\n      ').replaceAll('>', '\n    ')}
''', clearFirst: true);
    [
      'dart',
      'pub',
      'get',
    ].run(at: tempDir.path, showCommand: false, showMessages: false);
  }
  tempDir.deleteSync(recursive: true);
}
