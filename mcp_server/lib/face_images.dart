import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const maxFaceImageBytes = 15 * 1024 * 1024;
const maxFaceBase64EncodedBytes = 8 * 1024 * 1024;
const faceFetchTimeout = Duration(seconds: 20);

/// Reject loopback, LAN, link-local, CGNAT, multicast and reserved ranges so
/// a chat-supplied URL cannot probe the server's own network.
bool isPublicFaceAddress(InternetAddress address) {
  final raw = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    if (raw.length != 4) return false;
    final a = raw[0], b = raw[1];
    if (a == 0 || a == 10 || a == 127) return false;
    if (a == 100 && b >= 64 && b <= 127) return false;
    if (a == 169 && b == 254) return false;
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 0) return false;
    if (a == 192 && b == 168) return false;
    if (a == 198 && (b == 18 || b == 19)) return false;
    if (a >= 224) return false;
    return true;
  }
  if (raw.length != 16) return false;
  if (raw.sublist(0, 15).every((byte) => byte == 0) &&
      (raw[15] == 0 || raw[15] == 1)) {
    return false; // :: and ::1
  }
  if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) return false; // fe80::/10
  if (raw[0] == 0xfc || raw[0] == 0xfd) return false; // fc00::/7
  if (raw[0] == 0xff) return false; // ff00::/8
  final mappedV4 = raw.sublist(0, 10).every((byte) => byte == 0) &&
      raw[10] == 0xff &&
      raw[11] == 0xff;
  if (mappedV4) {
    return isPublicFaceAddress(
        InternetAddress.fromRawAddress(Uint8List.fromList(raw.sublist(12))));
  }
  return true;
}

Future<void> _ensurePublicHost(Uri uri) async {
  final host = uri.host;
  final literal = InternetAddress.tryParse(host);
  if (literal != null) {
    if (!isPublicFaceAddress(literal)) {
      throw FaceImageException('图片地址不能指向本机、内网或保留网段');
    }
    return;
  }
  List<InternetAddress> addresses;
  try {
    addresses =
        await InternetAddress.lookup(host).timeout(const Duration(seconds: 5));
  } catch (_) {
    throw FaceImageException('图片域名无法解析');
  }
  if (addresses.isEmpty) {
    throw FaceImageException('图片域名无法解析');
  }
  if (addresses.any((address) => !isPublicFaceAddress(address))) {
    throw FaceImageException('图片地址不能指向本机、内网或保留网段');
  }
}

bool _isSvgMime(String mime) => mime == 'image/svg+xml' || mime == 'image/svg';

bool isJpegBytes(List<int> bytes) =>
    bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8;

bool isPngBytes(List<int> bytes) {
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (bytes.length < signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  return true;
}

String faceRandomId() {
  final random = Random.secure();
  return base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

class FaceImageException implements Exception {
  FaceImageException(this.message, {this.status = 400});
  final String message;
  final int status;
  @override
  String toString() => message;
}

/// Image bytes never enter state.json, snapshots or MCP responses.
class FaceImages {
  FaceImages(this.dataDir);
  final String dataDir;
  Directory get directory => Directory('$dataDir/face-images');
  late final Future<void> _ready = _prepareDirectory();

  Future<void> _prepareDirectory() async {
    await directory.create(recursive: true);
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['700', directory.path]);
      if (result.exitCode != 0) {
        throw FaceImageException('图片目录权限设置失败，请联系服务管理员', status: 500);
      }
    }
  }

  File file(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(id)) {
      throw FaceImageException('图片不存在', status: 404);
    }
    return File('${directory.path}/$id');
  }

  Future<String> save(Stream<List<int>> stream, String? contentType,
      {int contentLength = -1, bool drainOversize = false}) async {
    ContentType? parsed;
    try {
      if (contentType != null) parsed = ContentType.parse(contentType);
    } on FormatException {/* Report invalid MIME below. */}
    if (parsed == null ||
        parsed.primaryType.toLowerCase() != 'image' ||
        parsed.subType.isEmpty ||
        parsed.subType == '*') {
      throw FaceImageException('请选择 Content-Type 为 image/* 的图片', status: 415);
    }
    final mime = parsed.mimeType.toLowerCase();
    if (_isSvgMime(mime)) {
      throw FaceImageException('不接受 SVG 图片，请使用 JPEG 或 PNG', status: 415);
    }
    if (contentLength > maxFaceImageBytes) {
      throw FaceImageException('图片不能超过 15 MB', status: 413);
    }
    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in stream) {
      length += chunk.length;
      if (length > maxFaceImageBytes && !drainOversize) {
        throw FaceImageException('图片不能超过 15 MB', status: 413);
      }
      if (length <= maxFaceImageBytes) builder.add(chunk);
    }
    if (length > maxFaceImageBytes) {
      throw FaceImageException('图片不能超过 15 MB', status: 413);
    }
    if (length == 0) throw FaceImageException('图片不能为空');
    await _ready;
    final id = faceRandomId();
    await file(id).writeAsBytes(builder.takeBytes(), flush: true);
    await File('${file(id).path}.json')
        .writeAsString(jsonEncode({'mime': mime}));
    return id;
  }

  Future<String> saveBytes(List<int> bytes, String mime) => save(
        Stream.value(bytes),
        mime,
        contentLength: bytes.length,
      );

  Future<String> mime(String id) async {
    final value =
        jsonDecode(await File('${file(id).path}.json').readAsString());
    return value['mime'] as String;
  }

  Future<void> delete(String id) async {
    for (final entry in [file(id), File('${file(id).path}.json')]) {
      if (await entry.exists()) await entry.delete();
    }
  }

  Future<int> sweep({DateTime? now}) async {
    if (!await directory.exists()) return 0;
    final cutoff = (now ?? DateTime.now()).subtract(const Duration(days: 7));
    var removed = 0;
    await for (final entry in directory.list()) {
      if (entry is File &&
          RegExp(r'^[A-Za-z0-9_-]{43}$')
              .hasMatch(entry.uri.pathSegments.last) &&
          (await entry.lastModified()).isBefore(cutoff)) {
        await delete(entry.uri.pathSegments.last);
        removed++;
      }
    }
    return removed;
  }

  Future<String> fetch(String url) async {
    var uri = Uri.tryParse(url);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw FaceImageException('图片 URL 必须是无账号密码的 HTTP 或 HTTPS 地址');
    }
    final client = HttpClient();
    Future<String> download() async {
      for (var redirects = 0; redirects <= 3; redirects++) {
        final request = await client.getUrl(uri!);
        request.followRedirects = false;
        final response = await request.close();
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) break;
          uri = uri!.resolve(location);
          if (!{'http', 'https'}.contains(uri!.scheme) ||
              uri!.userInfo.isNotEmpty ||
              uri!.host.isEmpty) {
            throw FaceImageException('图片重定向地址不安全');
          }
          await _ensurePublicHost(uri!);
          continue;
        }
        if (response.statusCode != 200) {
          throw FaceImageException('图片下载失败（HTTP ${response.statusCode}）');
        }
        return save(
            response, response.headers.value(HttpHeaders.contentTypeHeader),
            contentLength: response.contentLength);
      }
      throw FaceImageException('图片重定向次数过多');
    }

    try {
      return await (() async {
        await _ensurePublicHost(uri!);
        return download();
      })()
          .timeout(faceFetchTimeout);
    } on FaceImageException {
      rethrow;
    } on TimeoutException {
      throw FaceImageException('图片下载超过 20 秒，请改用上传链接');
    } catch (_) {
      // Network errors can contain signed URLs: never echo them to clients/logs.
      throw FaceImageException('图片下载失败，请检查图片链接或改用上传链接');
    } finally {
      client.close(force: true);
    }
  }
}
