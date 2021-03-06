// Copyright 2018 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:convert';
import 'dart:io';

import 'package:charcode/charcode.dart';
import 'package:grinder/grinder.dart';
import 'package:meta/meta.dart';
import 'package:node_preamble/preamble.dart' as preamble;
import 'package:path/path.dart' as p;
import 'package:source_span/source_span.dart';

import 'utils.dart';

@Task('Compile to JS in dev mode.')
js() => _js(release: false);

@Task('Compile to JS in release mode.')
jsRelease() => _js(release: true);

/// Compiles Sass to JS.
///
/// If [release] is `true`, this compiles minified with
/// --trust-type-annotations. Otherwise, it compiles unminified with pessimistic
/// type checks.
void _js({@required bool release}) {
  ensureBuild();
  var destination = new File('build/sass.dart.js');

  var args = [
    '--categories=Server',
    '-Dnode=true',
    '-Dversion=$version',
    '-Ddart-version=$dartVersion',
  ];
  if (release) args..add("--minify")..add("--trust-type-annotations");

  Dart2js.compile(new File('bin/sass.dart'),
      outFile: destination, extraArgs: args);
  var text = destination.readAsStringSync();
  destination.writeAsStringSync(preamble.getPreamble() + text);
}

@Task('Build a pure-JS dev-mode npm package.')
@Depends(js)
npmPackage() => _npm(release: false);

@Task('Build a pure-JS release-mode npm package.')
@Depends(jsRelease)
npmReleasePackage() => _npm(release: true);

/// Builds a pure-JS npm package.
///
/// If [release] is `true`, this compiles minified with
/// --trust-type-annotations. Otherwise, it compiles unminified with pessimistic
/// type checks.
void _npm({@required bool release}) {
  var json = jsonDecode(new File('package/package.json').readAsStringSync())
      as Map<String, dynamic>;
  json['version'] = version;

  _writeNpmPackage('build/npm', json);
  if (release) {
    _writeNpmPackage('build/npm-old', json..addAll({"name": "dart-sass"}));
  }
}

/// Writes a Dart Sass NPM package to the directory at [destination].
///
/// The [json] will be used as the package's package.json.
void _writeNpmPackage(String destination, Map<String, dynamic> json) {
  var dir = new Directory(destination);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);

  log("copying package/package.json to $destination");
  new File(p.join(destination, 'package.json'))
      .writeAsStringSync(jsonEncode(json));

  copy(new File(p.join('package', 'sass.js')), dir);
  copy(new File(p.join('build', 'sass.dart.js')), dir);

  log("copying package/README.npm.md to $destination");
  new File(p.join(destination, 'README.md'))
      .writeAsStringSync(_readAndResolveMarkdown('package/README.npm.md'));
}

final _readAndResolveRegExp = new RegExp(
    r"^<!-- +#include +([^\s]+) +"
    '"([^"\n]+)"'
    r" +-->$",
    multiLine: true);

/// Reads a Markdown file from [path] and resolves include directives.
///
/// Include directives have the syntax `"<!-- #include" PATH HEADER "-->"`,
/// which must appear on its own line. PATH is a relative file: URL to another
/// Markdown file, and HEADER is the name of a header in that file whose
/// contents should be included as-is.
String _readAndResolveMarkdown(String path) => new File(path)
        .readAsStringSync()
        .replaceAllMapped(_readAndResolveRegExp, (match) {
      String included;
      try {
        included = new File(p.join(p.dirname(path), p.fromUri(match[1])))
            .readAsStringSync();
      } catch (error) {
        _matchError(match, error.toString(), url: p.toUri(path));
      }

      Match headerMatch;
      try {
        headerMatch = "# ${match[2]}\n".allMatches(included).first;
      } on StateError {
        _matchError(match, "Could not find header.", url: p.toUri(path));
      }

      var headerLevel = 0;
      var index = headerMatch.start;
      while (index >= 0 && included.codeUnitAt(index) == $hash) {
        headerLevel++;
        index--;
      }

      // The section goes until the next header of the same level, or the end
      // of the document.
      var sectionEnd = included.indexOf("#" * headerLevel, headerMatch.end);
      if (sectionEnd == -1) sectionEnd = included.length;

      return included.substring(headerMatch.end, sectionEnd).trim();
    });

/// Throws a nice [SourceSpanException] associated with [match].
void _matchError(Match match, String message, {url}) {
  var file = new SourceFile.fromString(match.input, url: url);
  throw new SourceSpanException(message, file.span(match.start, match.end));
}
