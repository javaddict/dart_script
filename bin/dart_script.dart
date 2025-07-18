import 'dart:io';
import 'dart:convert';

import 'package:args/args.dart';
import 'package:dart_cli/dart_cli.dart';
import 'package:path/path.dart';

final _sources = <String>{};
final _sourceMap = <String, String>{};
final _packages = <(String, String, String)>{};

final dartSdkVersion = [
  'dart',
  '--version',
].run(showCommand: false, showMessages: false).output.split(' ')[3];

void main(List<String> arguments) async {
  final parser = ArgParser(allowTrailingOptions: false)
    ..addOption(
      'offline',
      help: 'Run in offline mode with specified pub cache path',
    )
    ..addOption(
      'cache',
      help: 'Where .dart_script is stored. The default is \$HOME.',
    )
    ..addOption(
      'command-output',
      help: 'Path to the file where the command output will be written',
    )
    ..addFlag(
      'reset',
      abbr: 'r',
      help: 'Clear the cache (of the script instead specified)',
    );

  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } catch (e) {
    stderr.writeln('Error parsing arguments: $e');
    stderr.writeln(parser.usage);
    exit(1);
  }

  final localPubCache = results['offline'] as String?;
  final isReset = results['reset'] as bool;
  final positionalArgs = List<String>.from(results.rest);

  final dartScriptDir = join(
    results['cache'] ?? env['HOME'] ?? env['USERPROFILE'] ?? '',
    '.dart_script',
  );
  if (positionalArgs.isEmpty) {
    if (isReset) {
      dartScriptDir.clear();
    } else {
      stderr.writeln(
        'Usage: dart_script [--offline <path>] [--command-output <path>] [--reset/-r] <script.dart>',
      );
    }
    exit(1);
  }

  final script = positionalArgs.removeAt(0);
  if (!script.exists()) {
    stderr.writeln('"$script" does not exist.');
    exit(1);
  }
  if (!script.isFile()) {
    stderr.writeln('"$script" is not a file.');
    exit(1);
  }
  if (!script.endsWith('.dart')) {
    stderr.writeln('"$script" is not a Dart file.');
    exit(1);
  }
  final mainSource = canonicalize(script);

  final shadowProject = join(
    dartScriptDir,
    basenameWithoutExtension(
      mainSource.replaceAll(separator, '_').replaceAll(':', ''),
    ),
  );

  if (isReset) {
    shadowProject.delete();
    exit(0);
  }

  if (!shadowProject.exists()) {
    shadowProject.createDir();
  }
  final sourceMapFile = join(shadowProject, 'source_map.json');
  final pubspec = join(shadowProject, 'pubspec.yaml');

  bool isRebuild = false;
  bool projectRebuilt = false;
  bool packagesChanged = false;
  void createProject() {
    print('[dart_script] ${isRebuild ? 'Re-build' : 'Build'} the environment.');
    shadowProject.find('*.aot').forEach(delete);

    _getProjectInfo(mainSource);
    _checkPackages();

    // Copy sources and build the source map
    var nearestRoot = dirname(mainSource);
    for (final source in _sources) {
      while (!isWithin(nearestRoot, source)) {
        nearestRoot = dirname(nearestRoot);
      }
    }
    _sourceMap.clear();
    for (final source in _sources) {
      final rp = relative(source, from: nearestRoot);
      final shadowSource = join(shadowProject, rp);
      dirname(shadowSource).createDir();
      if (!shadowSource.exists() || source.isNewerThan(shadowSource)) {
        source.copyTo(shadowSource);
      }
      _sourceMap[source] = rp;
    }
    sourceMapFile.write(jsonEncode(_sourceMap), clearFirst: true);
    // TODO: sources may not have a common root. In Windows, we use the drive letter as the root.

    final oldPackages = <(String, String)>{};
    if (pubspec.isFile()) {
      final lines = pubspec.readLines();
      var i = 0;
      for (; i < lines.length && lines[i] != 'dependencies:'; i++) {}
      for (++i; i < lines.length; i++) {
        var line = lines[i];
        while (i + 1 < lines.length && lines[i + 1].startsWith('    ')) {
          line += '\n${lines[i + 1]}';
          lines.removeAt(i + 1);
        }
        line = line.replaceAll('\n      ', '>>').replaceAll('\n    ', '>');
        final j = line.indexOf(': ');
        oldPackages.add((line.substring(2, j), line.substring(j + 2)));
      }
    }

    // Compare packages and update pubspec.yaml only if changed
    final newPackages = _packages.map((e) => (e.$1, e.$2)).toSet();
    if (!(newPackages.length == oldPackages.length &&
        newPackages.containsAll(oldPackages) &&
        oldPackages.containsAll(newPackages))) {
      pubspec.clear();
      pubspec.writeln('''name: ${basenameWithoutExtension(mainSource)}
environment:
  sdk: ^$dartSdkVersion
dependencies:''');
      for (final (name, version) in newPackages) {
        pubspec.writeln(
          '  $name: ${version.replaceAll('>>', '\n      ').replaceAll('>', '\n    ')}',
        );
      }
      packagesChanged = true;
    }

    projectRebuilt = true;
  }

  if (!sourceMapFile.isFile()) {
    print('[dart_script] First-time execution.');
    createProject();
  }
  final jsonContent = sourceMapFile.readLines().join();
  _sourceMap.addAll(Map<String, String>.from(jsonDecode(jsonContent)));

  final shadow = _sourceMap[mainSource]!;
  if (mainSource.isNewerThan(join(shadowProject, shadow))) {
    print('[dart_script] The script had changed.');
    isRebuild = true;
    createProject();
  }

  for (final MapEntry(key: source, value: shadow) in _sourceMap.entries) {
    if (source == mainSource) {
      continue;
    }
    if (!source.isFile() || source.isNewerThan(join(shadowProject, shadow))) {
      print('[dart_script] Related scripts had changed.');
      isRebuild = true;
      createProject();
      break;
    }
  }

  final snapshot = join(
    shadowProject,
    '${basename(mainSource)}-$dartSdkVersion.aot',
  );
  if (!snapshot.isFile()) {
    if (!projectRebuilt) {
      print('[dart_script] Dart SDK had changed.');
    }

    if (packagesChanged) {
      print('[dart_script] Import packages.');
      if (localPubCache != null) {
        env['PUB_CACHE'] = localPubCache;
      }
      final r = [
        'dart',
        'pub',
        'get',
        if (localPubCache != null) '--offline',
      ].run(at: shadowProject, showCommand: false, showMessages: false);
      if (!r.ok) {
        stderr.writeln('[dart_script] Failed to import packages.');
        r.errors.forEach(stderr.writeln);
        exit(r.exitCode);
      }
    }

    print('[dart_script] Compile the script.');
    final r = [
      'dart',
      'compile',
      'aot-snapshot',
      shadow,
      '-o',
      snapshot,
    ].run(at: shadowProject, showCommand: false, showMessages: false);
    if (!r.ok) {
      stderr.writeln('[dart_script] Failed to compile the script.');
      r.errors.forEach(stderr.writeln);
      exit(r.exitCode);
    }
  }

  final commandOutputPath = results['command-output'] as String?;
  if (commandOutputPath != null) {
    final cmdFile = commandOutputPath;
    cmdFile.write(
      'dartaotruntime $snapshot ${positionalArgs.concatenate()}',
      clearFirst: true,
    );
  } else {
    final r = await [
      'dartaotruntime',
      snapshot,
      ...positionalArgs,
    ].running(showCommand: false, interactive: true);
    exit(r.exitCode); // This is necessary if interactive is true
  }
}

final _import1 = RegExp('^import ["\']dart:.+["\'];\$');

final _import2 = RegExp(
  '^import ["\']package:(.+)/.+\\.dart["\'].*;(?:\\s*//\\s*(.+))?\$',
);

final _import3 = RegExp('^import ["\'](.+)["\'];\$');

void _getProjectInfo(String file) {
  final source = canonicalize(file);
  _sources.add(source);
  for (final line in source.readLines()) {
    if (_import1.hasMatch(line)) {
      continue;
    }
    var m = _import2.firstMatch(line);
    if (m != null) {
      final name = m[1]!;
      final version = m[2] ?? '';
      _packages.add((name, version, source));
      continue;
    }
    m = _import3.firstMatch(line);
    if (m != null) {
      final anotherSource = canonicalize(join(dirname(source), m[1]!));
      if (!_sources.contains(anotherSource)) {
        _getProjectInfo(anotherSource);
      }
    }
  }
}

void _checkPackages() {
  final map = <String, (String, String)>{};
  for (final (name, version, source) in _packages) {
    if (map.containsKey(name)) {
      final (currentVersion, currentSource) = map[name]!;
      if (version != currentVersion) {
        final resolved = _resolveVersions(
          version,
          source,
          currentVersion,
          currentSource,
        );
        if (resolved == null) {
          stderr.writeln(
            '[dart_script] Found conflicting versions for "$name":',
          );
          stderr.writeln('  $currentVersion in $currentSource');
          stderr.writeln('  $version in $source');
          exit(1);
        } else {
          map[name] = resolved;
        }
      }
    } else {
      map[name] = (version, source);
    }
  }
  _packages.clear();
  for (final MapEntry(key: name, value: version) in map.entries) {
    _packages.add((name, version.$1, version.$2));
  }
}

(String, String)? _resolveVersions(
  String versionA,
  String sourceA,
  String versionB,
  String sourceB,
) {
  // TODO: should resolve those with versions like "^1.5.9" and "^1.6.3"
  return null;
}
