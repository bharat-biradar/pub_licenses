import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:tar/tar.dart';

void main() async {
  final packagesFile = File('pub.dev_packages.json');
  final client = http.Client();
  final packages = json.decode(packagesFile.readAsStringSync())['packages'];
  final size = packages.length;
  const String baseUrl = 'https://pub.dev/api/packages/';
  final logFile = File('log.json');
  var log = <String, List<String>>{};
  var bar = ProgressBar(' [:bar] :percent ', total: size + 1, );

  for (var i = 0; i < size; i++) {
    final package = packages[i];
    final packageJson = baseUrl + package;
    final response = await http.get(Uri.parse(packageJson));

    if (response.statusCode == 200) {
      final details = json.decode(response.body);
      final url = details['latest']['archive_url'];
      final tarUrl = Uri.parse(url);

      try {
        final bytes = gzip.decode(await client.readBytes(tarUrl));
        final reader = await TarReader(Stream.value(bytes));
        final result = await writeFile(reader, package);

        if (result) {
          await reader.cancel();
          log.putIfAbsent('done', () => []).add(package);
        }else{
        log.putIfAbsent('pending', () => []).add(package);
        }
      } on http.ClientException {
        log.putIfAbsent('pending', () => []).add(package);
      }
    }

    bar.tick();
  }

  await logFile.writeAsString(json.encode(log));
  bar.tick();
}

Future<bool> writeFile(TarReader reader, String name) async {
  while (true) {
    try {
      final val = await reader.moveNext();
      if (val) {
        final entry = reader.current;

        if (license.hasMatch(entry.header.name)) {
          final file = File('licenses/${name}_${entry.header.name}');
          file.create(recursive: false);
          await file.writeAsString(
              await entry.contents.transform(utf8.decoder).first);
          await reader.cancel();
          return true;
        }
      }
    } catch (_) {
      break;
    }
  }

  return false;
}

final license = RegExp(r'(license|licence)(\.md)?',caseSensitive: false);

class ProgressBar {
  String format;
  int total;
  int width;
  bool clear;
  String completeChar;
  String incompleteChar;
  Function? callback;
  int curr = 0;
  bool complete = false;
  late DateTime start;
  String? lastDraw;

  /**
   * Initialize a `ProgressBar` with the given `format` string and the `options` map.
   *
   * Format tokens:
   *
   *   - `:bar` the progress bar itself
   *   - `:current` current tick number
   *   - `:total` total ticks
   *   - `:elapsed` time elapsed in seconds
   *   - `:percent` completion percentage
   *   - `:eta` eta in seconds
   *
   * Options:
   *
   *   - `total` total number of ticks to complete
   *   - `width` the displayed width of the progress bar defaulting to total
   *   - `completeChar` completion character defaulting to "="
   *   - `incompleteChar` incomplete character defaulting to "-"
   *   - `callback` optional function to call when the progress bar completes
   *   - `clear` will clear the progress bar upon termination
   *
   */
  ProgressBar(
    this.format, {
    this.total = 0,
    this.width = 0,
    this.clear = false,
    this.completeChar = '=',
    this.incompleteChar = '-',
    this.callback,
  }) {
    if (width <= 0 && total > 0) {
      width = total;
    }
  }

  /**
   * "tick" the progress bar with optional `len` and optional `tokens`.
   */
  tick({int len: 1, Map<String, String>? tokens}) {
    if (this.curr == 0) {
      this.start = new DateTime.now();
    }

    this.curr += len;
    this.render(tokens);

    // progress complete
    if (this.curr >= this.total) {
      this.complete = true;
      this.terminate();
      if (this.callback != null && this.callback is Function) {
        // Function.apply(this.callback, [this.complete]);
      }
    }
  }

  /**
   * Method to render the progress bar with optional `tokens` to place in the
   * progress bar's `format` field.
   *
   */
  render(Map<String, String>? tokens) {
    if (!stdout.hasTerminal) return;

    var ratio = this.curr / this.total;
    ratio = min(max(ratio, 0.0), 1.0);

    var percent = ratio * 100;
    var elapsed = new DateTime.now().difference(this.start).inMilliseconds;
    var eta = (percent == 100) ? 0 : elapsed * (this.total / this.curr - 1);

    /* populate the bar template with percentages and timestamps */
    var str = this
        .format
        .replaceAll(':current', this.curr.toString())
        .replaceAll(':total', this.total.toString())
        .replaceAll(':elapsed',
            elapsed.isNaN ? '0.0' : (elapsed / 1000).toStringAsFixed(1))
        .replaceAll(
            ':eta',
            (eta.isNaN || !eta.isFinite)
                ? '0.0'
                : (eta / 1000).toStringAsFixed(1))
        .replaceAll(':percent', percent.toStringAsFixed(0) + '%');

    /* compute the available space (non-zero) for the bar */
    var availableSpace =
        max(0, stdout.terminalColumns - str.replaceAll(':bar', '').length);
    var width = min(this.width, availableSpace);

    /* the following assumes the user has one ':bar' token */
    var completeLength = (width * ratio).round();
    var completeStr =
        new List<String>.filled(completeLength, this.completeChar).join();
    var incompleteStr =
        new List<String>.filled(width - completeLength, this.incompleteChar)
            .join();

    /* fill in the actual progress bar */
    str = str.replaceAll(':bar', completeStr + incompleteStr);

    /* replace the extra tokens */
    if (tokens != null && tokens.isNotEmpty) {
      tokens.forEach((key, val) {
        str = str.replaceAll(':' + key, val);
      });
    }

    if (this.lastDraw != str) {
      stdout.writeCharCode(13); // output carriage return
      stdout.write(str);
      this.lastDraw = str;
    }
  }

  /**
   * "update" the progress bar to represent an exact percentage.
   * The ratio (between 0 and 1) specified will be multiplied by `total` and
   * floored, representing the closest available "tick." For example, if a
   * progress bar has a length of 3 and `update(0.5)` is called, the progress
   * will be set to 1.
   *
   * A ratio of 0.5 will attempt to set the progress to halfway.
   *
   */
  update(num ratio) {
    var goal = (ratio * this.total).floor();
    var delta = goal - this.curr;
    this.tick(len: delta);
  }

  /**
   * Terminates a progress bar.
   *
   */
  terminate() {
    if (this.clear) {
      for (int i = 0; i < stdout.terminalColumns; i++) {
        stdout.writeCharCode(8); // output backspace
      }
    } else {
      stdout.writeln();
    }
  }
}


