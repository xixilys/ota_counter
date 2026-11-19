import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'album_glare_service.dart';
import 'album_orientation_service.dart';
import 'record_scan_service.dart';

/// Luminance-only, edge-limited unsharp mask. Leaves RGB chroma differences,
/// alpha, pure white/black and the source buffer unchanged. No image synthesis.
Uint8List enhanceAlbumRgba(Uint8List source, int width, int height) {
  final output = Uint8List.fromList(source);
  final luminance = Uint8List(width * height);
  for (var p = 0, i = 0; p < luminance.length; p++, i += 4) {
    luminance[p] =
        (54 * source[i] + 183 * source[i + 1] + 19 * source[i + 2]) >> 8;
  }
  for (var y = 0; y < height; y++) {
    final up = (y - 2).clamp(0, height - 1) * width;
    final down = (y + 2).clamp(0, height - 1) * width;
    final row = y * width;
    for (var x = 0; x < width; x++) {
      final p = row + x, i = p * 4;
      if (source[i + 3] != 255) continue;
      final value = luminance[p].toDouble();
      final blurred = (value * 4 +
              luminance[row + (x - 2).clamp(0, width - 1)] +
              luminance[row + (x + 2).clamp(0, width - 1)] +
              luminance[up + x] +
              luminance[down + x]) /
          8;
      final detail = value - blurred;
      // A small dead band does not amplify flat-field sensor noise.
      final sharpen = detail.abs() <= 0.75
          ? 0.0
          : (detail.sign * (detail.abs() - 0.75) * 0.55).clamp(-6.0, 6.0);
      // Fade contrast at paper white; weaker lift above mid-grey keeps pale ink.
      final envelope = 4 * value * (255 - value) / 65025;
      final contrast = (value - 128) * (value < 128 ? 0.06 : 0.025) * envelope;
      final r = source[i], g = source[i + 1], b = source[i + 2];
      final minimum = r < g ? (r < b ? r : b) : (g < b ? g : b);
      final maximum = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final delta = (contrast + sharpen).round().clamp(-minimum, 255 - maximum);
      output[i] = r + delta;
      output[i + 1] = g + delta;
      output[i + 2] = b + delta;
    }
  }
  return output;
}

typedef _Pixels = (TransferableTypedData, int, int);

Future<(Uint8List, int, int)?> _rectifyScanRgba(
  Uint8List rgba,
  int width,
  int height,
  bool rectifyCut,
) async {
  final cropped = await compute(_rectifyScanWorker, (
    TransferableTypedData.fromList([rgba]),
    width,
    height,
    rectifyCut,
  ));
  if (cropped == null) return null;
  final (pixels, w, h) = cropped;
  return (pixels.materialize().asUint8List(), w, h);
}

_Pixels? _rectifyScanWorker((TransferableTypedData, int, int, bool) input) {
  final (transfer, width, height, rectifyCut) = input;
  final rgba = transfer.materialize().asUint8List();
  // Preserve the full frame of transparent artwork.
  for (var i = 3; i < rgba.length; i += 4) {
    if (rgba[i] != 255) return null;
  }
  final corrected = RecordScanService.rectifyDominantCardPreview(
    img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgba.buffer,
      numChannels: 4,
    ),
    alreadyProcessed: !rectifyCut,
  );
  if (corrected == null) return null;
  return (
    TransferableTypedData.fromList(
      [corrected.getBytes(order: img.ChannelOrder.rgba)],
    ),
    corrected.width,
    corrected.height,
  );
}

(Uint8List, Uint8List?, int, int) _enhanceWorker(
    (TransferableTypedData, int, int, int, bool) input) {
  final (transfer, width, height, turn, scan) = input;
  var rgba = transfer.materialize().asUint8List();
  var w = width, h = height;
  if (turn != 0) {
    final raw = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgba.buffer,
      numChannels: 4,
    );
    final rotated = img.copyRotate(raw, angle: turn);
    rgba = rotated.getBytes(order: img.ChannelOrder.rgba);
    w = rotated.width;
    h = rotated.height;
  }
  final clean = reduceAlbumGlareRgba(rgba, w, h);
  final result = img.Image.fromBytes(
    width: w,
    height: h,
    bytes: enhanceAlbumRgba(clean, w, h).buffer,
    numChannels: 4,
  );
  Uint8List? thumb;
  const edge = 720;
  final downsample = w > edge || h > edge;
  if (scan && math.max(w, h) >= 260) {
    final small = downsample
        ? img.copyResize(
            result,
            width: w >= h ? edge : null,
            height: h > w ? edge : null,
            interpolation: img.Interpolation.linear,
          )
        : result;
    final opaque = !small.any((pixel) => pixel.a != 255);
    if (opaque) {
      thumb = img.encodeJpg(small, quality: 90);
    } else if (downsample) {
      thumb = img.encodePng(small, level: 1);
    }
  }
  return (img.encodePng(result, level: 1), thumb, w, h);
}

/// Durable, replaceable album rendition. The media row always points at the
/// originally archived file, so backups, duplicate checks and face samples
/// retain their original meaning.
class AlbumPhotoFile {
  final File file;
  final bool rectified;
  final int width;
  final int height;
  final File thumbnail;

  const AlbumPhotoFile(this.file,
      {required this.rectified,
      required this.width,
      required this.height,
      required this.thumbnail});
}

typedef _AlbumJob = (String, bool, bool);

class AlbumPhotoFiles {
  static const _originalVersion = '.album-optimized-v1';
  static const _scanVersion = '.album-optimized-v4';
  static const maxEdge = 2560;
  static final _pending = <_AlbumJob, Future<AlbumPhotoFile?>>{};
  static final _visible = <_AlbumJob, Completer<void>>{};
  static final _background = <_AlbumJob, Completer<void>>{};
  static bool _working = false;
  static final _archive = <String, bool>{};
  static bool _warming = false;

  // A camera rescan has actual paper edges that a clipped archive cannot
  // supply. Keep it separate from ordinary enhancements, which may be rebuilt.
  static final _rescanned = StreamController<String>.broadcast();
  static Stream<String> get rescanned => _rescanned.stream;
  static final _revisions = <String, int>{};
  static File _cameraIndex(String path, FileStat stat) => File(p.join(
      p.dirname(path),
      '.album-camera-v1',
      p.basename(path),
      '${stat.modified.microsecondsSinceEpoch}-${stat.size}.current'));

  static Future<File?> _cameraFile(String path, FileStat stat) async {
    final index = _cameraIndex(path, stat);
    if (!await index.exists()) return null;
    final generation = int.tryParse(await index.readAsString());
    if (generation == null) return null;
    final file = File(p.join(index.parent.path, '$generation.png'));
    return await file.exists() ? file : null;
  }

  static Future<bool> hasCameraScan(String path) async =>
      await _cameraFile(path, await File(path).stat()) != null;

  static Future<void> withdrawCameraScan(String path, FileStat stat) async {
    final index = _cameraIndex(path, stat);
    if (!await index.exists()) return;
    await index.delete();
    await _cameraChanged(path);
  }

  static Future<void> saveCameraScan(
      String path, FileStat source, Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(buffer);
    late final ui.Image image;
    try {
      image = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
    final w = image.width, h = image.height;
    final rgba = await _rgba(image, straight: true);
    final turn = await AlbumOrientationService.detect(rgba, w, h);
    if (turn == null) throw StateError('无法核对原拍方向');
    final (full, thumb, _, _) = await compute(_enhanceWorker, (
      TransferableTypedData.fromList([rgba]),
      w,
      h,
      turn,
      true,
    ));
    final current = await File(path).stat();
    if (current.type != FileSystemEntityType.file ||
        current.size != source.size ||
        current.modified != source.modified) {
      return;
    }
    final index = _cameraIndex(path, source);
    final generation = DateTime.now().microsecondsSinceEpoch;
    final file = File(p.join(index.parent.path, '$generation.png'));
    await file.parent.create(recursive: true);
    if (thumb != null) await _writeRendition(File('${file.path}.thumb'), thumb);
    await _writeRendition(file, full);
    await _writeRendition(index, Uint8List.fromList('$generation'.codeUnits));
    await _cameraChanged(path);
  }

  static Future<void> _cameraChanged(String path) async {
    // A previously requested cache hit can still be in flight.
    for (final rectify in [true, false]) {
      await _pending[(path, true, rectify)];
    }
    _revisions[path] = (_revisions[path] ?? 0) + 1;
    _rescanned.add(path);
  }

  static Directory _directory(String path, bool scan) => Directory(p.join(
      p.dirname(path),
      scan ? _scanVersion : _originalVersion,
      p.basename(path)));

  static File _output(
      String path, FileStat source, bool scan, bool rectify, bool warped) {
    final key = '${source.modified.microsecondsSinceEpoch}-${source.size}';
    return File(p.join(_directory(path, scan).path,
        '$key-${rectify ? 'card' : 'photo'}-${warped ? 'aligned' : 'full'}.png'));
  }

  /// Bounded, serial work; multiple surfaces requesting the same photo share
  /// the result without cancelling other photos. A failure leaves the archived
  /// photo usable and can be retried when it is shown again.
  static Future<AlbumPhotoFile?> prepare(String path,
      {required bool rectifyCut,
      bool isScan = false,
      bool background = false}) {
    final key = (path, isScan || rectifyCut, rectifyCut);
    if (!background) {
      // A fast scroll or a tap can re-request an item already queued.
      final waiting = _visible.remove(key) ?? _background.remove(key);
      if (waiting != null) _visible[key] = waiting;
    }
    // Work is owned by the application-wide queue, never by a view's zone.
    return _pending.putIfAbsent(
      key,
      () => Zone.root.run(() async {
        try {
          return await _prepare(key, background);
        } catch (error) {
          debugPrint('切册照片成品生成失败: $error');
          return null;
        } finally {
          _pending.remove(key);
        }
      }),
    );
  }

  /// Warm the whole scan inventory after the visible row has mounted. Queue
  /// one background item at a time so visible requests can interleave, and
  /// continue while the user moves to another album view.
  static void warmScans(Iterable<(String, bool)> scans) {
    for (final (path, rectify) in scans) {
      _archive[path] = rectify;
    }
    if (_warming || _archive.isEmpty) return;
    _warming = true;
    unawaited(Zone.root.run(() async {
      try {
        while (_archive.isNotEmpty) {
          final item = _archive.entries.first;
          _archive.remove(item.key);
          await prepare(item.key,
              rectifyCut: item.value, isScan: true, background: true);
          await Future<void>.delayed(const Duration(milliseconds: 24));
        }
      } finally {
        _warming = false;
      }
    }));
  }

  static Future<AlbumPhotoFile?> _prepare(
      _AlbumJob key, bool background) async {
    final (path, scan, rectify) = key;
    final original = File(path);
    final stat = await original.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('照片文件不存在', path);
    }
    final aligned = _output(path, stat, scan, rectify, true);
    final full = _output(path, stat, scan, rectify, false);
    final camera = scan ? await _cameraFile(path, stat) : null;
    for (final target in [
      if (camera != null) camera,
      if (scan) aligned,
      full
    ]) {
      if (await target.exists()) {
        final file = await target.open();
        final header = await file.read(24);
        await file.close();
        if (header.length != 24) continue;
        final dimensions = ByteData.sublistView(header);
        final thumb = File('${target.path}.thumb');
        return AlbumPhotoFile(target,
            rectified: target != full,
            width: dimensions.getUint32(16),
            height: dimensions.getUint32(20),
            thumbnail: scan && await thumb.exists() ? thumb : target);
      }
    }
    if (_working) {
      final turn = Completer<void>();
      (background ? _background : _visible)[key] = turn;
      await turn.future;
    } else {
      _working = true;
    }
    try {
      final image = await _decode(path, maxSize: maxEdge);
      final width = image.width, height = image.height;
      final originalPixels = await _rgba(image, straight: true);
      final crop = scan
          ? await _rectifyScanRgba(originalPixels, width, height, rectify)
          : null;
      final (rgba, w, h) = crop ?? (originalPixels, width, height);
      final turn = scan ? await AlbumOrientationService.detect(rgba, w, h) : 0;
      // A failed native call may succeed next time. Don't leave an unturned
      // rendition on disk that would suppress the retry.
      if (turn == null) return null;
      final rectified = crop != null || turn != 0;
      final (bytes, thumbBytes, outWidth, outHeight) =
          await compute(_enhanceWorker, (
        TransferableTypedData.fromList([rgba]),
        w,
        h,
        turn,
        scan,
      ));
      final now = await original.stat();
      if (now.size != stat.size || now.modified != stat.modified) {
        throw FileSystemException('照片文件已变更', path);
      }
      final target = rectified ? aligned : full;
      await target.parent.create(recursive: true);
      final thumb = File('${target.path}.thumb');
      if (thumbBytes != null) await _writeRendition(thumb, thumbBytes);
      await _writeRendition(target, bytes);
      return AlbumPhotoFile(target,
          rectified: rectified,
          width: outWidth,
          height: outHeight,
          thumbnail: thumbBytes == null ? target : thumb);
    } finally {
      // The most recent rows are the ones still on screen after a fast
      // scroll. Do not make them wait for older offscreen work.
      if (_visible.isNotEmpty) {
        _visible.remove(_visible.keys.last)!.complete();
      } else if (_background.isNotEmpty) {
        _background.remove(_background.keys.first)!.complete();
      } else {
        _working = false;
      }
    }
  }

  static Future<void> _writeRendition(File target, Uint8List bytes) async {
    final temporary = File('${target.path}.tmp');
    try {
      await temporary.writeAsBytes(bytes);
      await temporary.rename(target.path);
    } on FileSystemException {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  static Future<void> deleteFor(String path) async {
    _archive.remove(path);
    for (final key in [
      (path, false, false),
      (path, true, false),
      (path, true, true)
    ]) {
      await _pending[key];
    }
    for (final directory in [
      _cameraIndex(path, await File(path).stat()).parent,
      _directory(path, false),
      _directory(path, true),
      Directory(
          p.join(p.dirname(path), '.album-optimized-v2', p.basename(path))),
    ]) {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }
}

Future<ui.Image> _decode(String path, {int? maxSize}) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  final codec =
      await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
    final longest = w > h ? w : h;
    if (maxSize == null || longest <= maxSize) {
      return const ui.TargetImageSize();
    }
    final ratio = maxSize / longest;
    return ui.TargetImageSize(
        width: (w * ratio).round().clamp(1, maxSize),
        height: (h * ratio).round().clamp(1, maxSize));
  });
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

Future<Uint8List> _rgba(ui.Image image, {bool straight = false}) async {
  try {
    final bytes = await image.toByteData(
      format: straight
          ? ui.ImageByteFormat.rawStraightRgba
          : ui.ImageByteFormat.rawRgba,
    );
    if (bytes == null) throw StateError('无法读取照片像素');
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
  }
}

/// Viewer-local decoded rendition with geometry for the zoom canvas.
class AlbumClarityImage extends ImageProvider<AlbumClarityImage> {
  final String sourcePath;
  final int width, height;
  final Uint8List rgba;
  final Duration decodeTime, enhanceTime;
  final bool rectified;
  const AlbumClarityImage._(this.sourcePath, this.width, this.height, this.rgba,
      this.decodeTime, this.enhanceTime, this.rectified);
  int get byteCount => rgba.length;

  @override
  Future<AlbumClarityImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
          AlbumClarityImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_frame());

  Future<ImageInfo> _frame() async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(buffer,
        width: width, height: height, pixelFormat: ui.PixelFormat.rgba8888);
    ui.Codec? codec;
    try {
      codec = await descriptor.instantiateCodec();
      return ImageInfo(image: (await codec.getNextFrame()).image);
    } finally {
      codec?.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }
}

/// Viewer-local LRU: at most two images / 32 MiB RGBA. Only one worker runs;
/// a new request supersedes queued older photos rather than processing a book.
class AlbumClarityService {
  static const maxEdge = AlbumPhotoFiles.maxEdge;
  static const maxCacheBytes = 32 * 1024 * 1024;
  static const maxEntries = 2;
  final _cache = <String, AlbumClarityImage>{};
  Future<void> _worker = Future.value();
  int _request = 0;
  bool _disposed = false;
  int get cachedBytes =>
      _cache.values.fold(0, (sum, image) => sum + image.byteCount);
  int get cachedImages => _cache.length;

  void cancelPending() => _request++;

  Future<AlbumClarityImage?> prepare(String path,
      {bool rectifyCut = false, bool isScan = false}) async {
    final request = ++_request;
    final stat = await File(path).stat();
    if (_disposed || request != _request) return null;
    final key =
        '$path|${stat.size}|${stat.modified.microsecondsSinceEpoch}|$rectifyCut|$isScan|${AlbumPhotoFiles._revisions[path] ?? 0}';
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit;
      return hit;
    }
    await _worker;
    if (_disposed || request != _request) return null;
    // The preceding worker may have been enhancing this very photo when the
    // user briefly switched to original and back. Reuse its completed result.
    final completed = _cache.remove(key);
    if (completed != null) {
      _cache[key] = completed;
      return completed;
    }
    // Publish into the cache before releasing the serialized worker. Waiting
    // re-selections must see this result, not start another decode of the file.
    final task =
        _render(path, rectifyCut, isScan).then<AlbumClarityImage?>((image) {
      if (_disposed) return null;
      _cache[key] = image;
      while (_cache.length > maxEntries || cachedBytes > maxCacheBytes) {
        final removed = _cache.remove(_cache.keys.first)!;
        PaintingBinding.instance.imageCache.evict(removed);
      }
      return image;
    });
    _worker = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  Future<AlbumClarityImage> _render(
      String path, bool rectifyCut, bool isScan) async {
    final watch = Stopwatch()..start();
    final file = await AlbumPhotoFiles.prepare(path,
        rectifyCut: rectifyCut, isScan: isScan);
    if (file == null) throw StateError('无法生成切册成品');
    final enhanceTime = watch.elapsed;
    watch.reset();
    final image = await _decode(file.file.path);
    final width = image.width, height = image.height;
    final bytes = await _rgba(image);
    return AlbumClarityImage._(
        path, width, height, bytes, watch.elapsed, enhanceTime, file.rectified);
  }

  void dispose() {
    _disposed = true;
    cancelPending();
    for (final provider in _cache.values) {
      PaintingBinding.instance.imageCache.evict(provider);
    }
    _cache.clear();
  }
}
