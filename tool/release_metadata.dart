import 'dart:io';

class ReleaseMetadata {
  final String versionName;
  final String versionCode;

  const ReleaseMetadata({
    required this.versionName,
    required this.versionCode,
  });

  String get versionLabel => 'v$versionName';

  String get tag => versionLabel;

  String get releaseTitle => 'OTA Counter $versionLabel';

  String get apkFileName => 'OTA-Counter-$versionLabel.apk';

  String get devBranch {
    final parts = versionName.split('.');
    if (parts.length < 2) {
      return 'codex/$versionLabel-prep';
    }
    return 'codex/v${parts[0]}.${parts[1]}-prep';
  }
}

void main(List<String> args) {
  final metadata = _loadReleaseMetadata();
  final field = _readFieldArgument(args);

  if (field != null) {
    stdout.writeln(_fieldValue(metadata, field));
    return;
  }

  stdout.writeln('versionName=${metadata.versionName}');
  stdout.writeln('versionCode=${metadata.versionCode}');
  stdout.writeln('versionLabel=${metadata.versionLabel}');
  stdout.writeln('tag=${metadata.tag}');
  stdout.writeln('releaseTitle=${metadata.releaseTitle}');
  stdout.writeln('apkFileName=${metadata.apkFileName}');
  stdout.writeln('devBranch=${metadata.devBranch}');
}

ReleaseMetadata _loadReleaseMetadata() {
  final pubspecFile = _findPubspecFile(Directory.current);
  final content = pubspecFile.readAsStringSync();
  final match = RegExp(
    r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$',
    multiLine: true,
  ).firstMatch(content);

  if (match == null) {
    throw StateError('无法从 ${pubspecFile.path} 读取版本号');
  }

  return ReleaseMetadata(
    versionName: match.group(1)!,
    versionCode: match.group(2)!,
  );
}

File _findPubspecFile(Directory start) {
  Directory current = start.absolute;
  while (true) {
    final candidate = File('${current.path}/pubspec.yaml');
    if (candidate.existsSync()) {
      return candidate;
    }

    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('未找到 pubspec.yaml，请在仓库目录内运行');
    }
    current = parent;
  }
}

String? _readFieldArgument(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--field=')) {
      return arg.substring('--field='.length);
    }
  }
  return null;
}

String _fieldValue(ReleaseMetadata metadata, String field) {
  switch (field) {
    case 'versionName':
      return metadata.versionName;
    case 'versionCode':
      return metadata.versionCode;
    case 'versionLabel':
      return metadata.versionLabel;
    case 'tag':
      return metadata.tag;
    case 'releaseTitle':
      return metadata.releaseTitle;
    case 'apkFileName':
      return metadata.apkFileName;
    case 'devBranch':
      return metadata.devBranch;
    default:
      throw ArgumentError(
        '不支持的 field: $field，可选值：versionName, versionCode, versionLabel, tag, releaseTitle, apkFileName, devBranch',
      );
  }
}
