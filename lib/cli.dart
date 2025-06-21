import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart'; // 2.11.0
import 'package:dart_console/dart_console.dart'; // 4.1.2
import 'package:glob/glob.dart'; // 2.1.3
import 'package:path/path.dart'; // 1.9.1
import 'package:uuid/uuid.dart'; // 4.5.1

bool forceSilent = false;

class _EnvironmentVariables {
  final Map<String, String> _map0 = Platform.environment;
  Map<String, String> _map1 = {};

  String? operator [](String key) => _map1[key] ?? _map0[key];

  void operator []=(String key, String value) {
    if (_map0[key] != value) {
      _map1[key] = value;
    } else {
      _map1.remove(key);
    }
  }

  void unset(String key) {
    _map1.remove(key);
  }

  final pathSeparator = Platform.isWindows ? ';' : ':';

  void prependToPATH(String path) {
    env['PATH'] = '$path${env.pathSeparator}${env['PATH']}';
  }
}

final env = _EnvironmentVariables();

// Not thread-safe.
void set(Map<String, String> overrides, Function() toDo) {
  final saved = <String, String>{...env._map1};
  for (final MapEntry(:key, :value) in overrides.entries) {
    env[key] = value;
  }
  toDo();
  env._map1 = saved;
}

String? _workingDirectory;

// Not thread-safe.
void cd(String path, Function() toDo) {
  final saved = _workingDirectory;
  _workingDirectory = path;
  toDo();
  _workingDirectory = saved;
}

extension CommandParts on List<String> {
  ProcessResult run({
    String? at,
    bool showCommand = true,
    bool showMessages = true,
    bool runInShell = true,
  }) {
    if (isEmpty) {
      throw ArgumentError('The command can not be empty.');
    }
    if (!forceSilent && showCommand) {
      stdout.writeln(concatenate());
    }
    final r = Process.runSync(
      this[0],
      getRange(1, length).toList(),
      workingDirectory: at ?? _workingDirectory,
      environment: env._map1,
      runInShell: runInShell,
    );
    if (!forceSilent) {
      if (showMessages && r.stdout != '') {
        stdout.writeln(r.stdout);
      }
      if (showMessages && r.stderr != '') {
        stderr.writeln(r.stderr);
      }
    }
    return r;
  }

  /// Use of [interactive] with true must explicitly terminate itself at the end
  /// of [main]. (https://github.com/dart-lang/sdk/issues/45098)
  Future<ProcessResult> running({
    String? at,
    bool showCommand = true,
    bool showMessages = true,
    bool saveMessages = false,
    (StreamConsumer<String>?, StreamConsumer<String>?) redirectMessages = (
      null,
      null,
    ),
    bool runInShell = true,
    List<String> input = const [],
    bool interactive = false,
  }) async {
    if (isEmpty) {
      throw ArgumentError('The command can not be empty.');
    }
    if (!forceSilent && showCommand) {
      stdout.writeln(concatenate());
    }
    final p = await Process.start(
      this[0],
      getRange(1, length).toList(),
      workingDirectory: at ?? _workingDirectory,
      environment: env._map1,
      runInShell: runInShell,
    );
    for (final s in input) {
      p.stdin.writeln(s);
    }
    final outBuf = StringBuffer();
    final errBuf = StringBuffer();
    for (final e in [
      (p.stdout, stdout, redirectMessages.$1, outBuf),
      (p.stderr, stderr, redirectMessages.$2, errBuf),
    ]) {
      final (src, std, redirect, buf) = e;
      if (redirect == null && !saveMessages) {
        if (!forceSilent && showMessages) {
          src.listen((data) {
            std.add(data);
          });
        } else {
          src.drain();
        }
      } else {
        var s0 = src;
        if (!forceSilent && showMessages) {
          final [s00, s01] = StreamSplitter.splitFrom(s0);
          s00.listen((data) {
            std.add(data);
          });
          s0 = s01;
        }
        final s1 = s0.transform(utf8.decoder).transform(const LineSplitter());
        if (redirect != null && saveMessages) {
          final [s10, s11] = StreamSplitter.splitFrom(s1);
          s10.pipe(redirect);
          s11.listen((line) {
            buf.writeln(line);
          });
        } else if (redirect != null) {
          s1.pipe(redirect);
        } else {
          s1.listen((line) {
            buf.writeln(line);
          });
        }
      }
    }
    int exitCode;
    if (interactive) {
      final scription = _stdin.listen((List<int> data) {
        if (data.isNotEmpty) {
          p.stdin.add(data);
        }
      });
      exitCode = await p.exitCode;
      await scription.cancel();
    } else {
      exitCode = await p.exitCode;
    }
    return ProcessResult(p.pid, exitCode, outBuf.toString(), errBuf.toString());
  }

  String concatenate() {
    String quoteIfNecessary(String part) =>
        part.contains(' ') ? '"${part.replaceAll('"', '\\"')}"' : part;

    final sb = StringBuffer();
    for (var i = 0; i < length; i++) {
      if (i > 0) {
        sb.write(' ');
      }
      sb.write(quoteIfNecessary(this[i]));
    }
    return sb.toString();
  }
}

extension Command on String {
  ProcessResult run({
    String? at,
    bool showCommand = true,
    bool showMessages = true,
  }) {
    if (!forceSilent && showCommand) {
      stdout.writeln(this);
    }
    return [
      // We don't use cmd.exe in MSYS2.
      env['SHELL'] ?? 'cmd.exe',
      env['SHELL'] != null ? '-c' : '/c',
      this,
    ].run(
      at: at,
      showCommand: false,
      showMessages: showMessages,
      runInShell: false,
    );
  }

  /// Use of [interactive] with true must explicitly terminate itself at the end
  /// of [main]. (https://github.com/dart-lang/sdk/issues/45098)
  Future<ProcessResult> running({
    String? at,
    bool showCommand = true,
    bool showMessages = true,
    bool saveMessages = false,
    (StreamConsumer<String>?, StreamConsumer<String>?) redirectMessages = (
      null,
      null,
    ),
    List<String> input = const [],
    bool interactive = false,
  }) {
    if (!forceSilent && showCommand) {
      stdout.writeln(this);
    }
    return [
      // We don't use cmd.exe in MSYS2.
      env['SHELL'] ?? 'cmd.exe',
      env['SHELL'] != null ? '-c' : '/c',
      this,
    ].running(
      at: at,
      showCommand: false,
      showMessages: showMessages,
      saveMessages: saveMessages,
      redirectMessages: redirectMessages,
      runInShell: false,
      input: input,
      interactive: interactive,
    );
  }
}

List<String> separate(String command) {
  final list = <String>[];
  String? quote;
  var i = 0;
  int j;
  for (j = 0; j < command.length; j++) {
    final c = command[j];
    if (c == '\\') {
      j++;
    } else if (quote == null && (c == '\'' || c == '"')) {
      quote = c;
    } else if (c == quote) {
      quote = null;
    } else if (c == ' ') {
      if (quote == null) {
        list.add(command.substring(i, j));
        i = j + 1;
      }
    }
  }
  list.add(command.substring(i, j));
  list.retainWhere((s) => s.isNotEmpty);
  return list;
}

// In MSYS2, we use '\n' as the line terminator.
final _lineTerminator = Platform.isWindows && env['SHELL'] != null
    ? '\n'
    : Platform.lineTerminator;

final _fileCache = <String, File>{};

File _getFile(String path) {
  _fileCache[path] ??= File(path);
  return _fileCache[path]!;
}

extension Path on String {
  bool isDirectory() => FileSystemEntity.isDirectorySync(this);

  bool isFile() => FileSystemEntity.isFileSync(this);

  bool isLink() => FileSystemEntity.isLinkSync(this);

  bool exists() =>
      FileSystemEntity.typeSync(this) != FileSystemEntityType.notFound;

  void delete() {
    // deleteSync() throws an exception if the file does not exist.
    if (exists()) {
      // [deleteSync] works on all [FileSystemEntity] types when [recursive] is true.
      _getFile(this).deleteSync(recursive: true);
    }
  }

  List<String> readLines() => _getFile(this).readAsLinesSync();

  void copyTo(String path) {
    if (isFile() || isLink()) {
      _getFile(this).copySync(path);
    } else if (isDirectory()) {
      _copyDirectory(Directory(this), Directory(path));
    }
  }

  void _copyDirectory(Directory srcDir, Directory destDir) {
    if (!destDir.existsSync()) {
      destDir.createSync(recursive: true);
    }

    srcDir.listSync(recursive: false).forEach((entity) {
      final newPath = join(destDir.path, basename(entity.path));
      if (entity is File) {
        entity.copySync(newPath);
      } else if (entity is Directory) {
        _copyDirectory(entity, Directory(newPath));
      }
    });
  }

  void moveTo(String path) {
    try {
      _getFile(this).renameSync(path);
    } on FileSystemException {
      // This will work even when [path] is at a different drive.
      if (isFile()) {
        copyTo(path);
        delete();
      } else if (isDirectory()) {
        _copyDirectory(Directory(this), Directory(path));
        delete();
      }
    }
  }

  void clear() {
    if (isFile() || isLink()) {
      _getFile(this).writeAsStringSync('', flush: true);
    } else if (isDirectory()) {
      Directory(this).listSync(recursive: true).forEach((entity) {
        // [deleteSync] works on all [FileSystemEntity] types when [recursive] is true.
        entity.deleteSync(recursive: true);
      });
    }
  }

  void write(String s, {bool flush = false}) =>
      _getFile(this).writeAsStringSync(s, mode: FileMode.append, flush: flush);

  void writeln(String s, {String? newLine, bool flush = false}) =>
      _getFile(this).writeAsStringSync(
        '$s${newLine ?? _lineTerminator}',
        mode: FileMode.append,
        flush: flush,
      );

  void flush() => _getFile(this).flush();

  List<String> find(String glob) {
    final r = <String>[];
    final d = Directory(this);
    final g = Glob(glob);
    if (d.existsSync()) {
      for (final e in d.listSync(recursive: true)) {
        final s = relative(e.path, from: d.path);
        if (g.matches(s)) {
          r.add(join(this, s));
        }
      }
    }
    return r;
  }

  bool touch() {
    final file = _getFile(this);
    if (Platform.isWindows) {
      try {
        if (file.existsSync()) {
          final now = DateTime.timestamp();
          file.setLastAccessedSync(now);
          file.setLastModifiedSync(now);
        } else {
          if (file.parent.existsSync()) {
            file.createSync();
          }
        }
      } catch (e) {
        stderr.writeln(e);
        return false;
      }
      return true;
    } else {
      return ['touch', this].run(showCommand: false, showMessages: false).ok;
    }
  }

  DateTime get lastModified => _getFile(this).lastModifiedSync();

  bool isNewerThan(String other) => lastModified.isAfter(other.lastModified);

  bool isOlderThan(String other) => lastModified.isBefore(other.lastModified);

  void create() {
    _getFile(this).createSync(recursive: true);
  }

  void createDir() {
    Directory(this).createSync(recursive: true);
  }

  String get parent => dirname(this);
}

Stream<List<int>> _stdin = stdin.asBroadcastStream();

// Also good for tear-off
void delete(String path) {
  path.delete();
}

// Also good for tear-off
bool touch(String path) {
  return path.touch();
}

String? which(String program) {
  final pr = [
    Platform.isWindows ? 'where' : 'which',
    program,
  ].run(showCommand: false, showMessages: false);
  return pr.ok ? pr.output : null;
}

extension FileExt on File {
  void clear() => writeAsStringSync('');

  void write(String s, {bool flush = false}) =>
      writeAsStringSync(s, mode: FileMode.append, flush: flush);

  void writeln(String s, {String? newLine, bool flush = false}) =>
      writeAsStringSync(
        '$s${newLine ?? _lineTerminator}',
        mode: FileMode.append,
        flush: flush,
      );

  void flush() {
    writeAsStringSync('', mode: FileMode.append, flush: true);
  }
}

final _lineTerminatorRegExp = RegExp('(?:\n|\r\n)');

extension ProcessResultExt on ProcessResult {
  List<String> get outputs {
    if (this.stdout == null) {
      return [];
    }
    final s = this.stdout as String;
    return s.isEmpty ? [] : s.split(_lineTerminatorRegExp)
      ..removeLast();
  }

  List<String> get errors {
    final s = this.stderr as String;
    return s.isEmpty ? [] : s.split(_lineTerminatorRegExp)
      ..removeLast();
  }

  String get output {
    final list = outputs;
    return list.isEmpty ? '' : list[0];
  }

  String get error {
    final list = errors;
    return list.isEmpty ? '' : list[0];
  }

  bool get ok => this.exitCode == 0;
}

final _uuid = Uuid();
final _tempFiles = <String>[];

String createTempFile({String? suffix}) {
  final f =
      '${join(Directory.systemTemp.path, _uuid.v4())}${suffix != null && suffix[0] != '.' ? '.' : ''}${suffix ?? ''}';
  _tempFiles.add(f);
  _getFile(f).createSync();
  return f;
}

void deleteTempFiles() {
  _tempFiles.forEach(delete);
}

class AnsiSpinner {
  final _console = Console();
  int _ticks = 0;
  Timer? _timer;
  final List<String> _animation;

  AnsiSpinner()
    : _animation = Platform.isWindows
          ? <String>[r'-', r'\', r'|', r'/']
          : <String>['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷'];

  void start() {
    _console.hideCursor();
    stdout.write(' ');
    _timer = Timer.periodic(const Duration(milliseconds: 100), _advance);
    _advance(_timer!);
  }

  void print() {
    stdout.write('\x1b[38;5;1m${_animation[_ticks]}\x1b[0m');
  }

  void _advance(Timer timer) {
    _console.cursorLeft();
    print();
    _ticks = (_ticks + 1) % _animation.length;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _console.cursorLeft();
    _console
        .eraseCursorToEnd(); // Erase from the cursor position to the end of the line.
    _console.showCursor();
  }
}

// If this is an executable named "program" and is executed through PATH,
// [Platform.script.path] will be `'${Directory.current.path}/program'` but not
// the correct one in PATH.
String get scriptPath {
  var p = Platform.script.path;
  if (Platform.isWindows) {
    // [Platform.script.path] is something like "/C:/msys64/home/..." on
    // Windows. It might be a bug.
    if (RegExp(r'^/\S:/').hasMatch(p)) {
      p = p.substring(1);
    }
  }
  if (!p.isFile()) {
    p = which(basename(p)) ?? p;
  }
  return p;
}

final pwd = Directory.current.path;

String ask(
  String question, {
  List<String> options = const [],
  List<String> descriptions = const [],
  String? defaultAnswer,
  bool Function(String)? check,
}) {
  assert(descriptions.isEmpty || descriptions.length == options.length);
  assert(
    options.isEmpty || defaultAnswer == null || options.contains(defaultAnswer),
  );
  while (true) {
    final detailedOptions = <String>[];
    if (options.isNotEmpty) {
      for (var i = 0; i < options.length; i++) {
        detailedOptions.add(
          '(\u001B[1m${options[i]}\u001B[0m)${i < descriptions.length ? descriptions[i] : ''}',
        );
      }
    }
    stdout.write(
      '$question '
      '${options.isNotEmpty ? '[${detailedOptions.join('/')}] ' : ''}'
      '${defaultAnswer != null ? '($defaultAnswer) ' : ''}',
    );
    String? answer = stdin.readLineSync();
    if (answer == null || answer.isEmpty) {
      if (defaultAnswer != null) {
        return defaultAnswer;
      }
    } else {
      if (options.isEmpty) {
        if (check == null || check(answer)) {
          return answer.trim();
        }
      } else {
        if (options.any((o) => o.toLowerCase() == answer.toLowerCase())) {
          return answer.trim();
        }
      }
    }
  }
}
