import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/activity_record_media_model.dart';

class RecordScanOutput {
  final List<int> bytes;
  final String fileExtension;
  final ActivityRecordMediaProcessingMode processingMode;

  const RecordScanOutput({
    required this.bytes,
    required this.fileExtension,
    required this.processingMode,
  });
}

class RecordScanQuad {
  final double topLeftX;
  final double topLeftY;
  final double topRightX;
  final double topRightY;
  final double bottomLeftX;
  final double bottomLeftY;
  final double bottomRightX;
  final double bottomRightY;

  const RecordScanQuad({
    required this.topLeftX,
    required this.topLeftY,
    required this.topRightX,
    required this.topRightY,
    required this.bottomLeftX,
    required this.bottomLeftY,
    required this.bottomRightX,
    required this.bottomRightY,
  });

  factory RecordScanQuad._fromRect(_IntRect rect) {
    return RecordScanQuad(
      topLeftX: rect.left.toDouble(),
      topLeftY: rect.top.toDouble(),
      topRightX: rect.right.toDouble(),
      topRightY: rect.top.toDouble(),
      bottomLeftX: rect.left.toDouble(),
      bottomLeftY: rect.bottom.toDouble(),
      bottomRightX: rect.right.toDouble(),
      bottomRightY: rect.bottom.toDouble(),
    );
  }

  RecordScanQuad copyWith({
    double? topLeftX,
    double? topLeftY,
    double? topRightX,
    double? topRightY,
    double? bottomLeftX,
    double? bottomLeftY,
    double? bottomRightX,
    double? bottomRightY,
  }) {
    return RecordScanQuad(
      topLeftX: topLeftX ?? this.topLeftX,
      topLeftY: topLeftY ?? this.topLeftY,
      topRightX: topRightX ?? this.topRightX,
      topRightY: topRightY ?? this.topRightY,
      bottomLeftX: bottomLeftX ?? this.bottomLeftX,
      bottomLeftY: bottomLeftY ?? this.bottomLeftY,
      bottomRightX: bottomRightX ?? this.bottomRightX,
      bottomRightY: bottomRightY ?? this.bottomRightY,
    );
  }

  /// A clockwise, convex selection in screen coordinates. Reject crossed,
  /// collapsed and non-finite handles before passing them to copyRectify.
  bool isUsable({double minimumEdge = 1}) {
    final points = [
      math.Point(topLeftX, topLeftY),
      math.Point(topRightX, topRightY),
      math.Point(bottomRightX, bottomRightY),
      math.Point(bottomLeftX, bottomLeftY),
    ];
    for (var i = 0; i < points.length; i++) {
      final a = points[i];
      final b = points[(i + 1) % 4];
      final c = points[(i + 2) % 4];
      if (!a.x.isFinite ||
          !a.y.isFinite ||
          a.distanceTo(b) < minimumEdge ||
          (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) <= 0) {
        return false;
      }
    }
    return true;
  }

  RecordScanQuad clampToBounds({
    required int imageWidth,
    required int imageHeight,
  }) {
    final maxX = math.max(0, imageWidth - 1).toDouble();
    final maxY = math.max(0, imageHeight - 1).toDouble();
    return RecordScanQuad(
      topLeftX: topLeftX.clamp(0.0, maxX),
      topLeftY: topLeftY.clamp(0.0, maxY),
      topRightX: topRightX.clamp(0.0, maxX),
      topRightY: topRightY.clamp(0.0, maxY),
      bottomLeftX: bottomLeftX.clamp(0.0, maxX),
      bottomLeftY: bottomLeftY.clamp(0.0, maxY),
      bottomRightX: bottomRightX.clamp(0.0, maxX),
      bottomRightY: bottomRightY.clamp(0.0, maxY),
    );
  }
}

class RecordScanManualDraft {
  final Uint8List sourceBytes;
  final int imageWidth;
  final int imageHeight;
  final RecordScanQuad suggestedQuad;
  final bool usedFallback;

  const RecordScanManualDraft({
    required this.sourceBytes,
    required this.imageWidth,
    required this.imageHeight,
    required this.suggestedQuad,
    required this.usedFallback,
  });
}

/// 拍立得尺寸类别，按卡片外框（含白边）的短边/长边之比判断。
///
/// 依据富士官方胶片规格（instax.com 各机型规格页）：
/// - instax mini（俗称三寸）：胶片 86×54mm（画面 62×46mm），54/86 ≈ 0.628。
/// - instax WIDE（俗称五寸）：胶片 86×108mm（画面 62×99mm），86/108 ≈ 0.796；
///   横放时 108/86 ≈ 1.26，取短/长后是同一个数，所以横竖放都按 0.796 比较。
///
/// 只看比例分不出绝对大小：instax SQUARE（约 86×72mm，≈0.84）这类接近
/// 0.8 的卡片会落在五寸区间边缘或「不确定」，这里不再细分。
enum RecordScanCardSize {
  /// 三寸（instax mini）。
  mini,

  /// 五寸（instax WIDE）。
  wide,

  /// 长宽比不在上面两类附近。
  uncertain;

  String get label => switch (this) {
        RecordScanCardSize.mini => '三寸',
        RecordScanCardSize.wide => '五寸',
        RecordScanCardSize.uncertain => '不确定',
      };
}

/// 多张模式下对整张照片的提示，UI 可直接展示 [message]。
enum RecordScanMultiWarning {
  lightBackground('背景太浅，可能和拍立得连成一片；建议换深色背景重拍'),
  possiblyMerged('疑似多张拍立得贴在一起或互相压住；已尽量拆开，请逐张核对'),
  noneDetected('没有找到拍立得；请换深色背景，并在每张之间留出空隙');

  const RecordScanMultiWarning(this.message);

  final String message;
}

class RecordScanMultiCard {
  /// 校正、润色后的 JPEG。
  final Uint8List bytes;
  final String fileExtension;
  final ActivityRecordMediaProcessingMode processingMode;

  /// 裁切区域在原图（按 EXIF 方向摆正后、未缩放）中的四个角。
  /// 可以和原图字节一起交给 [RecordScanService.createManualScan] 微调。
  final RecordScanQuad quad;
  final RecordScanCardSize sizeClass;

  /// 检测到的外框短边/长边之比。
  final double aspectRatio;

  /// 0–1，越高越像一张完整的拍立得。
  final double confidence;

  /// 是从「贴在一起」的一大块里按比例拆出来的。
  final bool splitFromMerged;

  const RecordScanMultiCard({
    required this.bytes,
    required this.fileExtension,
    required this.processingMode,
    required this.quad,
    required this.sizeClass,
    required this.aspectRatio,
    required this.confidence,
    required this.splitFromMerged,
  });
}

class RecordScanMultiResult {
  /// 按阅读顺序（从上到下、每行从左到右）排列。
  final List<RecordScanMultiCard> cards;
  final List<RecordScanMultiWarning> warnings;

  /// 原图（EXIF 摆正后）尺寸，[RecordScanMultiCard.quad] 以它为坐标系。
  final int sourceWidth;
  final int sourceHeight;

  /// 各阶段耗时（毫秒），用于排查性能：decode / detect / refine /
  /// polish / encode / total。
  final Map<String, int> stageMilliseconds;

  const RecordScanMultiResult({
    required this.cards,
    required this.warnings,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.stageMilliseconds,
  });
}

class RecordScanService {
  static const int _maxInputDimension = 1800;
  static const int _previewMaxSide = 320;
  static const double _polaroidAspectRatio = 0.8;
  static const int _targetLongSide = 1360;
  static const int _fusionFrameLimit = 4;
  static const double _defaultLuminanceThreshold = 150;
  static const int _maxNeutralChroma = 78;

  // Decode, resize, detect and JPEG encode are CPU-heavy. An async method
  // alone does not move these loops off Flutter's UI isolate.
  static Future<RecordScanOutput> createBasicScan({required File sourceFile}) =>
      Isolate.run(() => _createBasicScan(sourceFile: sourceFile));

  static Future<RecordScanManualDraft> prepareManualDraft({
    required File sourceFile,
  }) =>
      Isolate.run(() => _prepareManualDraft(sourceFile: sourceFile));

  static Future<RecordScanOutput> createManualScan({
    required Uint8List sourceBytes,
    required RecordScanQuad quad,
  }) =>
      Isolate.run(
          () => _createManualScan(sourceBytes: sourceBytes, quad: quad));

  static Future<RecordScanOutput> createFusionScan({
    required List<File> sourceFiles,
  }) =>
      Isolate.run(() => _createFusionScan(sourceFiles: sourceFiles));

  /// Finds every polaroid laid out in one photo and crops each separately.
  /// Each card goes through the single-card deskew/polish pipeline on its own
  /// neighbourhood, so cards may have different rotations.
  static Future<RecordScanMultiResult> createMultiScan({
    required File sourceFile,
  }) =>
      Isolate.run(() => _createMultiScan(sourceFile: sourceFile));

  static Future<RecordScanOutput> _createBasicScan({
    required File sourceFile,
  }) async {
    final prepared = await _prepareWorkingSource(sourceFile);
    final processed = _buildQuickScanImage(
      image: prepared.image,
      cropRect: prepared.cropRect,
    );
    return RecordScanOutput(
      bytes: img.encodeJpg(processed, quality: 94),
      fileExtension: '.jpg',
      processingMode: ActivityRecordMediaProcessingMode.antiGlareBasic,
    );
  }

  static Future<RecordScanManualDraft> _prepareManualDraft({
    required File sourceFile,
  }) async {
    final prepared = await _prepareWorkingSource(sourceFile);
    final encoded = Uint8List.fromList(
      img.encodeJpg(prepared.image, quality: 96),
    );
    return RecordScanManualDraft(
      sourceBytes: encoded,
      imageWidth: prepared.image.width,
      imageHeight: prepared.image.height,
      suggestedQuad: RecordScanQuad._fromRect(prepared.cropRect),
      usedFallback: prepared.usedFallback,
    );
  }

  static Future<RecordScanOutput> _createManualScan({
    required Uint8List sourceBytes,
    required RecordScanQuad quad,
  }) async {
    if (!quad.isUsable()) {
      throw const FormatException('请按顺序框选四个角，避免交叉或重叠');
    }
    // Manual handles refer to the pixels displayed by the draft. Deskewing
    // may have expanded that canvas beyond 1800; resizing it again here
    // would shift every selected corner.
    final working = _decodeAndNormalize(sourceBytes, resize: false);
    final clampedQuad = quad.clampToBounds(
      imageWidth: working.width,
      imageHeight: working.height,
    );
    if (!clampedQuad.isUsable()) {
      throw const FormatException('框选范围过小或超出图片');
    }
    var targetWidth = math.max(
      2,
      ((_distance(
                    clampedQuad.topLeftX,
                    clampedQuad.topLeftY,
                    clampedQuad.topRightX,
                    clampedQuad.topRightY,
                  ) +
                  _distance(
                    clampedQuad.bottomLeftX,
                    clampedQuad.bottomLeftY,
                    clampedQuad.bottomRightX,
                    clampedQuad.bottomRightY,
                  )) /
              2)
          .round(),
    );
    var targetHeight = math.max(
      2,
      ((_distance(
                    clampedQuad.topLeftX,
                    clampedQuad.topLeftY,
                    clampedQuad.bottomLeftX,
                    clampedQuad.bottomLeftY,
                  ) +
                  _distance(
                    clampedQuad.topRightX,
                    clampedQuad.topRightY,
                    clampedQuad.bottomRightX,
                    clampedQuad.bottomRightY,
                  )) /
              2)
          .round(),
    );

    // Bound the rectified intermediate even for callers passing original
    // camera bytes. Keep source coordinates untouched while limiting output.
    final longestTargetSide = math.max(targetWidth, targetHeight);
    if (longestTargetSide > _maxInputDimension) {
      final scale = _maxInputDimension / longestTargetSide;
      targetWidth = math.max(2, (targetWidth * scale).round());
      targetHeight = math.max(2, (targetHeight * scale).round());
    }

    final rectified = img.copyRectify(
      working,
      topLeft: img.Point(
        clampedQuad.topLeftX,
        clampedQuad.topLeftY,
      ),
      topRight: img.Point(
        clampedQuad.topRightX,
        clampedQuad.topRightY,
      ),
      bottomLeft: img.Point(
        clampedQuad.bottomLeftX,
        clampedQuad.bottomLeftY,
      ),
      bottomRight: img.Point(
        clampedQuad.bottomRightX,
        clampedQuad.bottomRightY,
      ),
      interpolation: img.Interpolation.linear,
      toImage: img.Image(width: targetWidth, height: targetHeight),
    );

    final processed = _applyQuickAntiGlare(_resizeToTargetFrame(rectified));
    return RecordScanOutput(
      bytes: img.encodeJpg(processed, quality: 94),
      fileExtension: '.jpg',
      processingMode: ActivityRecordMediaProcessingMode.manualAssist,
    );
  }

  static Future<RecordScanOutput> _createFusionScan({
    required List<File> sourceFiles,
  }) async {
    final usableFiles = sourceFiles
        .where((file) => file.path.trim().isNotEmpty)
        .take(_fusionFrameLimit)
        .toList(growable: false);
    if (usableFiles.isEmpty) {
      throw const FormatException('没有可用的扫描图片');
    }

    final candidates = <_ScanCandidate>[];
    for (final file in usableFiles) {
      candidates.add(await _prepareCandidate(file));
    }
    if (candidates.length == 1) {
      return RecordScanOutput(
        bytes: img.encodeJpg(_applyLegacyFusionPolish(candidates.first.image),
            quality: 94),
        fileExtension: '.jpg',
        processingMode: ActivityRecordMediaProcessingMode.antiGlareFusion,
      );
    }

    candidates.sort((a, b) => a.rankScore.compareTo(b.rankScore));
    final base = candidates.first;
    final alignments = <_AlignedCandidate>[
      _AlignedCandidate(candidate: base, shiftX: 0, shiftY: 0, difference: 0),
    ];

    for (final candidate in candidates.skip(1)) {
      final alignment = _alignToBase(base.image, candidate.image);
      if (alignment.difference <= 12) {
        alignments.add(
          _AlignedCandidate(
            candidate: candidate,
            shiftX: alignment.shiftX,
            shiftY: alignment.shiftY,
            difference: alignment.difference,
          ),
        );
      }
    }

    final fused = alignments.length >= 2
        ? _fuseAlignedCandidates(alignments)
        : _applyLegacyFusionPolish(base.image);

    return RecordScanOutput(
      bytes: img.encodeJpg(fused, quality: 94),
      fileExtension: '.jpg',
      processingMode: ActivityRecordMediaProcessingMode.antiGlareFusion,
    );
  }

  static Future<_ScanCandidate> _prepareCandidate(File sourceFile) async {
    final prepared = await _prepareWorkingSource(sourceFile);
    final processed = _buildLegacyCandidateImage(
      image: prepared.image,
      cropRect: prepared.cropRect,
    );

    return _ScanCandidate(
      image: processed,
      glareScore: _estimateGlareScore(processed),
      detectionScore: prepared.detectionScore,
      usedFallback: prepared.usedFallback,
    );
  }

  static img.Image _buildQuickScanImage({
    required img.Image image,
    required _IntRect cropRect,
  }) {
    final cropped = img.copyCrop(
      image,
      x: cropRect.left,
      y: cropRect.top,
      width: cropRect.width,
      height: cropRect.height,
    );

    return _applyQuickAntiGlare(_resizeToTargetFrame(cropped));
  }

  static img.Image _buildLegacyCandidateImage({
    required img.Image image,
    required _IntRect cropRect,
  }) {
    final cropped = img.copyCrop(
      image,
      x: cropRect.left,
      y: cropRect.top,
      width: cropRect.width,
      height: cropRect.height,
    );

    final normalized = _resizeToTargetFrame(cropped);
    _applyGrayWorldWhiteBalance(normalized);
    return normalized;
  }

  static Future<_PreparedScanSource> _prepareWorkingSource(
      File sourceFile) async {
    return _prepareWorkingImage(
        _decodeAndNormalize(await sourceFile.readAsBytes()));
  }

  /// The single-card pipeline: detect, deskew, re-detect and pick the crop.
  /// Multi-card scans call this on each card's neighbourhood so every card
  /// gets its own rotation; the defaults reproduce the single-card scan.
  static _PreparedScanSource _prepareWorkingImage(
    img.Image source, {
    double aspectRatio = _polaroidAspectRatio,
    double luminanceThreshold = _defaultLuminanceThreshold,
  }) {
    var working = source;
    var rotationDegrees = 0.0;
    var detection =
        _detectPolaroid(working, luminanceThreshold: luminanceThreshold);

    if (detection != null &&
        detection.confidence >= 0.32 &&
        detection.rotationDegrees.abs() >= 1.5 &&
        detection.rotationDegrees.abs() <= 28) {
      rotationDegrees = detection.rotationDegrees;
      working = img.copyRotate(
        working,
        angle: rotationDegrees,
        interpolation: img.Interpolation.linear,
      );
      // A rectangle from before rotation refers to a different coordinate
      // system. Use the fallback if detection fails on the rotated image.
      detection =
          _detectPolaroid(working, luminanceThreshold: luminanceThreshold);
    }

    final cropRect = detection != null
        ? _expandedPolaroidRect(
            rect: detection.rect,
            imageWidth: working.width,
            imageHeight: working.height,
            aspectRatio: aspectRatio,
          )
        : _fallbackCropRect(working);

    return _PreparedScanSource(
      image: working,
      cropRect: cropRect,
      detectionScore: detection?.confidence ?? 0,
      usedFallback: detection == null,
      rotationDegrees: rotationDegrees,
      sourceWidth: source.width,
      sourceHeight: source.height,
    );
  }

  static img.Image _decodeAndNormalize(List<int> bytes, {bool resize = true}) {
    final oriented = _decodeOriented(bytes);
    return resize ? _limitInputSize(oriented) : oriented;
  }

  static img.Image _decodeOriented(List<int> bytes) {
    img.Image? decoded;
    try {
      decoded = img.decodeImage(
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      );
    } on RangeError {
      throw const FormatException('图片数据不完整或无法识别');
    } on FormatException {
      throw const FormatException('图片数据不完整或无法识别');
    }
    if (decoded == null) {
      throw const FormatException('图片无法识别');
    }

    return img.bakeOrientation(decoded);
  }

  static img.Image _limitInputSize(img.Image image) {
    var normalized = image;
    final longestSide = math.max(normalized.width, normalized.height);
    if (longestSide > _maxInputDimension) {
      final scale = _maxInputDimension / longestSide;
      normalized = img.copyResize(
        normalized,
        width: math.max(1, (normalized.width * scale).round()),
        height: math.max(1, (normalized.height * scale).round()),
        interpolation: img.Interpolation.cubic,
      );
    }
    return normalized;
  }

  static _DetectedPolaroid? _detectPolaroid(
    img.Image image, {
    double luminanceThreshold = _defaultLuminanceThreshold,
  }) {
    final preview = _buildPreview(image);
    final width = preview.width;
    final height = preview.height;
    final previewArea = width * height;
    final mask = Uint8List(previewArea);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final pixel = preview.getPixel(x, y);
        final red = pixel.r.toInt();
        final green = pixel.g.toInt();
        final blue = pixel.b.toInt();
        final luminance = _luminance(red, green, blue);
        final chroma = _chroma(red, green, blue);
        if (luminance >= luminanceThreshold && chroma <= _maxNeutralChroma) {
          mask[(y * width) + x] = 1;
        }
      }
    }

    final visited = Uint8List(previewArea);
    final queue = <int>[];
    _DetectedPolaroid? bestCandidate;
    var bestScore = 0.0;

    for (var index = 0; index < previewArea; index++) {
      if (mask[index] == 0 || visited[index] == 1) {
        continue;
      }

      queue
        ..clear()
        ..add(index);
      visited[index] = 1;
      final component = _ComponentStats();
      var queueIndex = 0;

      while (queueIndex < queue.length) {
        final current = queue[queueIndex++];
        final x = current % width;
        final y = current ~/ width;
        component.add(x, y);

        for (var deltaY = -1; deltaY <= 1; deltaY++) {
          for (var deltaX = -1; deltaX <= 1; deltaX++) {
            if (deltaX == 0 && deltaY == 0) {
              continue;
            }
            final nextX = x + deltaX;
            final nextY = y + deltaY;
            if (nextX < 0 || nextY < 0 || nextX >= width || nextY >= height) {
              continue;
            }
            final nextIndex = (nextY * width) + nextX;
            if (mask[nextIndex] == 0 || visited[nextIndex] == 1) {
              continue;
            }
            visited[nextIndex] = 1;
            queue.add(nextIndex);
          }
        }
      }

      if (component.count < previewArea * 0.003) {
        continue;
      }

      final bboxWidth = component.width;
      final bboxHeight = component.height;
      final bboxArea = bboxWidth * bboxHeight;
      if (bboxWidth < width * 0.12 ||
          bboxHeight < height * 0.12 ||
          bboxArea < previewArea * 0.028) {
        continue;
      }

      final density = component.count / bboxArea;
      if (density < 0.018 || density > 0.82) {
        continue;
      }

      final normalizedRatio =
          math.min(bboxWidth / bboxHeight, bboxHeight / bboxWidth);
      final ratioScore =
          1 - (((normalizedRatio - _polaroidAspectRatio).abs()) / 0.35);
      if (ratioScore <= 0) {
        continue;
      }

      final edgeCoverage = _edgeCoverage(
        mask: mask,
        previewWidth: width,
        rect: component.rect,
      );
      final centerScore = _centerScore(
        rect: component.rect,
        imageWidth: width,
        imageHeight: height,
      );
      final sizeScore = math.sqrt(bboxArea / previewArea).clamp(0.0, 1.0);
      final densityScore =
          1 - (((density - 0.18).abs()) / 0.22).clamp(0.0, 1.0);
      final score = (sizeScore * 0.34) +
          (ratioScore * 0.24) +
          (edgeCoverage * 0.2) +
          (centerScore * 0.16) +
          (densityScore * 0.06);

      if (score <= bestScore) {
        continue;
      }

      bestScore = score;
      bestCandidate = _DetectedPolaroid(
        rect: _scaleRectToImage(component.rect, image, preview),
        confidence: score,
        rotationDegrees: _rotationToNearestAxis(
          component.angleDegrees,
          portrait: bboxHeight >= bboxWidth,
        ),
      );
    }

    return bestCandidate;
  }

  static img.Image _buildPreview(
    img.Image image, {
    int maxSide = _previewMaxSide,
  }) {
    final longestSide = math.max(image.width, image.height);
    if (longestSide <= maxSide) {
      return img.Image.from(image);
    }
    final scale = maxSide / longestSide;
    return img.copyResize(
      image,
      width: math.max(1, (image.width * scale).round()),
      height: math.max(1, (image.height * scale).round()),
      interpolation: img.Interpolation.linear,
    );
  }

  static _IntRect _scaleRectToImage(
    _IntRect rect,
    img.Image fullImage,
    img.Image preview,
  ) {
    final scaleX = fullImage.width / preview.width;
    final scaleY = fullImage.height / preview.height;
    return _IntRect(
      left: math.max(0, (rect.left * scaleX).floor()),
      top: math.max(0, (rect.top * scaleY).floor()),
      width: math.max(1, (rect.width * scaleX).ceil()),
      height: math.max(1, (rect.height * scaleY).ceil()),
    );
  }

  static double _edgeCoverage({
    required Uint8List mask,
    required int previewWidth,
    required _IntRect rect,
  }) {
    final thickness = math.max(1, math.min(rect.width, rect.height) ~/ 14);
    var sampled = 0;
    var matched = 0;

    void sample(int x, int y) {
      if (x < rect.left || x > rect.right || y < rect.top || y > rect.bottom) {
        return;
      }
      sampled += 1;
      if (mask[(y * previewWidth) + x] == 1) {
        matched += 1;
      }
    }

    for (var x = rect.left; x <= rect.right; x++) {
      for (var offset = 0; offset < thickness; offset++) {
        sample(x, rect.top + offset);
        sample(x, rect.bottom - offset);
      }
    }
    for (var y = rect.top; y <= rect.bottom; y++) {
      for (var offset = 0; offset < thickness; offset++) {
        sample(rect.left + offset, y);
        sample(rect.right - offset, y);
      }
    }

    if (sampled == 0) {
      return 0;
    }
    return matched / sampled;
  }

  static double _centerScore({
    required _IntRect rect,
    required int imageWidth,
    required int imageHeight,
  }) {
    final centerX = rect.left + (rect.width / 2);
    final centerY = rect.top + (rect.height / 2);
    final dx = centerX - (imageWidth / 2);
    final dy = centerY - (imageHeight / 2);
    final distance = math.sqrt((dx * dx) + (dy * dy));
    final maxDistance = math.sqrt(
      ((imageWidth / 2) * (imageWidth / 2)) +
          ((imageHeight / 2) * (imageHeight / 2)),
    );
    return (1 - (distance / maxDistance)).clamp(0.0, 1.0);
  }

  static double _rotationToNearestAxis(
    double angleDegrees, {
    required bool portrait,
  }) {
    var normalized = angleDegrees % 180;
    if (normalized < 0) {
      normalized += 180;
    }
    final target = portrait ? 90.0 : 0.0;
    var rotation = target - normalized;
    if (rotation > 90) {
      rotation -= 180;
    }
    if (rotation < -90) {
      rotation += 180;
    }
    return rotation;
  }

  static _IntRect _expandedPolaroidRect({
    required _IntRect rect,
    required int imageWidth,
    required int imageHeight,
    double aspectRatio = _polaroidAspectRatio,
  }) {
    var left = rect.left;
    var right = rect.right;
    var top = rect.top;
    var bottom = rect.bottom;

    var width = (right - left) + 1;
    var height = (bottom - top) + 1;
    final targetRatio = height >= width ? aspectRatio : (1 / aspectRatio);
    final currentRatio = width / height;

    if (currentRatio < targetRatio) {
      final desiredWidth = (height * targetRatio).round();
      final extra = desiredWidth - width;
      left -= extra ~/ 2;
      right += extra - (extra ~/ 2);
    } else if (currentRatio > targetRatio) {
      final desiredHeight = (width / targetRatio).round();
      final extra = desiredHeight - height;
      top -= (extra * 0.35).round();
      bottom += extra - (extra * 0.35).round();
    }

    if (left < 0) {
      right -= left;
      left = 0;
    }
    if (top < 0) {
      bottom -= top;
      top = 0;
    }
    if (right >= imageWidth) {
      final overflow = right - imageWidth + 1;
      left = math.max(0, left - overflow);
      right = imageWidth - 1;
    }
    if (bottom >= imageHeight) {
      final overflow = bottom - imageHeight + 1;
      top = math.max(0, top - overflow);
      bottom = imageHeight - 1;
    }

    return _IntRect(
      left: left,
      top: top,
      width: math.max(1, (right - left) + 1).toInt(),
      height: math.max(1, (bottom - top) + 1).toInt(),
    );
  }

  static _IntRect _fallbackCropRect(img.Image image) {
    final portrait = image.height >= image.width;
    final targetRatio =
        portrait ? _polaroidAspectRatio : (1 / _polaroidAspectRatio);
    var cropWidth = (image.width * 0.84).round();
    var cropHeight = (image.height * 0.84).round();
    final currentRatio = cropWidth / cropHeight;

    if (currentRatio < targetRatio) {
      cropHeight = (cropWidth / targetRatio).round();
    } else {
      cropWidth = (cropHeight * targetRatio).round();
    }

    final left = ((image.width - cropWidth) / 2).round().clamp(0, image.width);
    final top =
        ((image.height - cropHeight) / 2).round().clamp(0, image.height);
    return _IntRect(
      left: left,
      top: top,
      width: cropWidth.clamp(1, image.width - left),
      height: cropHeight.clamp(1, image.height - top),
    );
  }

  static img.Image _resizeToTargetFrame(
    img.Image image, {
    double aspectRatio = _polaroidAspectRatio,
  }) {
    final portrait = image.height >= image.width;
    final targetHeight =
        portrait ? _targetLongSide : (_targetLongSide * aspectRatio).round();
    final targetWidth =
        portrait ? (_targetLongSide * aspectRatio).round() : _targetLongSide;
    final upscaling = targetWidth > image.width || targetHeight > image.height;
    return img.copyResize(
      image,
      width: targetWidth,
      height: targetHeight,
      // A crop taken from a desk photo is often only a few hundred pixels
      // wide; cubic keeps it from looking like a stretched thumbnail.
      interpolation:
          upscaling ? img.Interpolation.cubic : img.Interpolation.linear,
    );
  }

  /// Mild unsharp mask for small crops that had to be enlarged.
  static img.Image _sharpenFrame(img.Image source) {
    if (source.width < 2 || source.height < 2) {
      return source;
    }
    return img.convolution(
      source,
      filter: const [0, -0.5, 0, -0.5, 3, -0.5, 0, -0.5, 0],
      div: 1,
      amount: 0.35,
    );
  }

  static img.Image _applyQuickAntiGlare(img.Image source) {
    final working = img.Image.from(source);
    _applyGrayWorldWhiteBalance(working);
    _softenHighlights(working);
    return working;
  }

  static img.Image _applyLegacyFusionPolish(img.Image source) {
    final working = img.Image.from(source);
    _softenHighlights(working);
    _normalizePolaroidBorder(working);
    _applyContrastCurve(working);
    return working;
  }

  static void _applyGrayWorldWhiteBalance(img.Image image) {
    var pixelCount = 0;
    var redSum = 0.0;
    var greenSum = 0.0;
    var blueSum = 0.0;

    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        final red = pixel.r.toInt();
        final green = pixel.g.toInt();
        final blue = pixel.b.toInt();
        if (red < 8 && green < 8 && blue < 8) {
          continue;
        }
        redSum += red;
        greenSum += green;
        blueSum += blue;
        pixelCount += 1;
      }
    }

    if (pixelCount == 0) {
      return;
    }

    final averageRed = redSum / pixelCount;
    final averageGreen = greenSum / pixelCount;
    final averageBlue = blueSum / pixelCount;
    final target = (averageRed + averageGreen + averageBlue) / 3;

    final redScale = _clampDouble(target / averageRed, 0.88, 1.16);
    final greenScale = _clampDouble(target / averageGreen, 0.88, 1.16);
    final blueScale = _clampDouble(target / averageBlue, 0.88, 1.16);

    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        image.setPixelRgba(
          x,
          y,
          _clampChannel(pixel.r * redScale),
          _clampChannel(pixel.g * greenScale),
          _clampChannel(pixel.b * blueScale),
          pixel.a.toInt(),
        );
      }
    }
  }

  static void _softenHighlights(img.Image image) {
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        final alpha = pixel.a.toInt();
        final red = pixel.r.toInt();
        final green = pixel.g.toInt();
        final blue = pixel.b.toInt();
        final luminance = _luminance(red, green, blue);
        if (luminance < 208) {
          continue;
        }

        final chroma = _chroma(red, green, blue);
        final highlightLevel = _clampDouble((luminance - 208) / 46, 0, 1);
        final specularWeight = chroma < 44 ? 0.72 : 0.36;
        final blend = highlightLevel * specularWeight;
        final gray = (red + green + blue) / 3;
        final target = 214 + ((luminance - 208) * 0.12);

        image.setPixelRgba(
          x,
          y,
          _clampChannel(_mix(red, target, blend * 0.95)),
          _clampChannel(_mix(green, target, blend)),
          _clampChannel(_mix(blue, target, blend * 0.92)),
          alpha,
        );

        if (chroma < 58) {
          final softened = image.getPixel(x, y);
          image.setPixelRgba(
            x,
            y,
            _clampChannel(_mix(softened.r, gray, blend * 0.55)),
            _clampChannel(_mix(softened.g, gray, blend * 0.55)),
            _clampChannel(_mix(softened.b, gray, blend * 0.55)),
            alpha,
          );
        }
      }
    }
  }

  static void _normalizePolaroidBorder(img.Image image) {
    final sideBand = math.max(10, (image.width * 0.08).round());
    final topBand = math.max(10, (image.height * 0.08).round());
    final bottomBand = math.max(16, (image.height * 0.16).round());

    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final inBorder = x < sideBand ||
            x >= image.width - sideBand ||
            y < topBand ||
            y >= image.height - bottomBand;
        if (!inBorder) {
          continue;
        }

        final pixel = image.getPixel(x, y);
        final red = pixel.r.toInt();
        final green = pixel.g.toInt();
        final blue = pixel.b.toInt();
        final luminance = _luminance(red, green, blue);
        final chroma = _chroma(red, green, blue);
        if (luminance < 155 || chroma > 78) {
          continue;
        }

        final edgeDistance = math.min(
          math.min(x, image.width - 1 - x),
          math.min(y, image.height - 1 - y),
        );
        final borderSize =
            y >= image.height - bottomBand ? bottomBand : sideBand;
        final edgeWeight = (1 - (edgeDistance / borderSize)).clamp(0.0, 1.0);
        final brighten = _clampDouble((luminance - 155) / 80, 0, 1);
        final blend =
            (0.18 + (edgeWeight * 0.22) + (brighten * 0.22)).clamp(0.0, 0.52);

        image.setPixelRgba(
          x,
          y,
          _clampChannel(_mix(red, 246, blend)),
          _clampChannel(_mix(green, 246, blend)),
          _clampChannel(_mix(blue, 246, blend)),
          pixel.a.toInt(),
        );
      }
    }
  }

  static void _applyContrastCurve(img.Image image) {
    final curve = List<int>.generate(256, _curveChannel);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        image.setPixelRgba(
          x,
          y,
          curve[pixel.r.toInt()],
          curve[pixel.g.toInt()],
          curve[pixel.b.toInt()],
          pixel.a.toInt(),
        );
      }
    }
  }

  static double _estimateGlareScore(img.Image image) {
    var glareScore = 0.0;
    final totalPixels = image.width * image.height;

    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        glareScore += _glarePenalty(
          pixel.r.toInt(),
          pixel.g.toInt(),
          pixel.b.toInt(),
        );
      }
    }

    return glareScore / totalPixels;
  }

  static _FrameAlignment _alignToBase(img.Image base, img.Image other) {
    final thumbWidth = 96;
    final thumbHeight = (thumbWidth / _polaroidAspectRatio).round();
    final baseThumb = img.copyResize(
      base,
      width: thumbWidth,
      height: thumbHeight,
      interpolation: img.Interpolation.linear,
    );
    final otherThumb = img.copyResize(
      other,
      width: thumbWidth,
      height: thumbHeight,
      interpolation: img.Interpolation.linear,
    );

    final baseLuma = Float64List(thumbWidth * thumbHeight);
    final otherLuma = Float64List(thumbWidth * thumbHeight);
    for (var y = 0; y < thumbHeight; y++) {
      for (var x = 0; x < thumbWidth; x++) {
        final a = baseThumb.getPixel(x, y);
        final b = otherThumb.getPixel(x, y);
        baseLuma[y * thumbWidth + x] =
            _luminance(a.r.toInt(), a.g.toInt(), a.b.toInt());
        otherLuma[y * thumbWidth + x] =
            _luminance(b.r.toInt(), b.g.toInt(), b.b.toInt());
      }
    }

    var bestDiff = double.infinity;
    var bestShiftX = 0;
    var bestShiftY = 0;
    const searchRange = 5;
    const margin = 8;

    for (var shiftY = -searchRange; shiftY <= searchRange; shiftY++) {
      for (var shiftX = -searchRange; shiftX <= searchRange; shiftX++) {
        var compared = 0;
        var diff = 0.0;

        for (var y = margin; y < thumbHeight - margin; y++) {
          final otherY = y + shiftY;
          if (otherY < margin || otherY >= thumbHeight - margin) {
            continue;
          }
          for (var x = margin; x < thumbWidth - margin; x++) {
            final otherX = x + shiftX;
            if (otherX < margin || otherX >= thumbWidth - margin) {
              continue;
            }

            final baseValue = baseLuma[y * thumbWidth + x];
            final otherValue = otherLuma[otherY * thumbWidth + otherX];
            // Moving glare is precisely why multiple frames were captured;
            // it must not count as a mismatch in the underlying photograph.
            if (baseValue >= 218 || otherValue >= 218) continue;
            diff += (baseValue - otherValue).abs();
            compared += 1;
          }
        }

        if (compared <
            (thumbWidth - margin * 2) * (thumbHeight - margin * 2) * 0.25) {
          continue;
        }

        final averageDiff = diff / compared;
        if (averageDiff < bestDiff ||
            (averageDiff == bestDiff &&
                shiftX * shiftX + shiftY * shiftY <
                    bestShiftX * bestShiftX + bestShiftY * bestShiftY)) {
          bestDiff = averageDiff;
          bestShiftX = shiftX;
          bestShiftY = shiftY;
        }
      }
    }

    final fullShiftX = (bestShiftX * (base.width / thumbWidth)).round();
    final fullShiftY = (bestShiftY * (base.height / thumbHeight)).round();
    return _FrameAlignment(
      shiftX: fullShiftX,
      shiftY: fullShiftY,
      difference: bestDiff,
    );
  }

  static img.Image _fuseAlignedCandidates(
    List<_AlignedCandidate> alignedCandidates,
  ) {
    final base = alignedCandidates.first.candidate.image;
    final fused = img.Image.from(base);

    for (var y = 0; y < fused.height; y++) {
      for (var x = 0; x < fused.width; x++) {
        var chosenPixel = base.getPixel(x, y);
        var chosenPenalty = _glarePenalty(
          chosenPixel.r.toInt(),
          chosenPixel.g.toInt(),
          chosenPixel.b.toInt(),
        );

        for (final aligned in alignedCandidates.skip(1)) {
          final sampleX = x + aligned.shiftX;
          final sampleY = y + aligned.shiftY;
          if (!aligned.candidate.image.isBoundsSafe(sampleX, sampleY)) {
            continue;
          }

          final pixel = aligned.candidate.image.getPixel(sampleX, sampleY);
          final penalty = _glarePenalty(
            pixel.r.toInt(),
            pixel.g.toInt(),
            pixel.b.toInt(),
          );
          if (penalty + 0.06 < chosenPenalty) {
            chosenPixel = pixel;
            chosenPenalty = penalty;
          }
        }

        fused.setPixel(x, y, chosenPixel);
      }
    }

    _softenHighlights(fused);
    _normalizePolaroidBorder(fused);
    _applyContrastCurve(fused);
    return fused;
  }

  // ---------------------------------------------------------------------
  // Multi-card scan
  // ---------------------------------------------------------------------

  /// Detection runs on a larger thumbnail than the single-card scan so a
  /// 3×3 layout still leaves each card well over 100 preview pixels wide.
  static const int _multiPreviewMaxSide = 640;

  /// Card outer-frame ratios (short / long). See [RecordScanCardSize].
  static const double _miniCardRatio = 54 / 86;
  static const double _wideCardRatio = 86 / 108;
  static const double _miniRatioTolerance = 0.05;
  // Narrower so instax SQUARE (≈0.84) does not count as WIDE.
  static const double _wideRatioTolerance = 0.035;
  // With a mini-shaped window the outline may be off by foreshortening.
  static const double _miniRatioPerspectiveTolerance = 0.13;
  static const double _miniWindowAspectMax = 0.9;

  /// Above this, the crop is pre-rotated before the single-card flow (which
  /// itself only deskews between 1.5° and 28°).
  static const double _steepTiltDegrees = 20;

  static Future<RecordScanMultiResult> _createMultiScan({
    required File sourceFile,
  }) async {
    final total = Stopwatch()..start();
    final stage = Stopwatch()..start();
    final timings = <String, int>{};

    final oriented = _decodeOriented(await sourceFile.readAsBytes());
    final source = _Rgb.of(oriented);
    // Area averaging on raw bytes; copyResize(cubic) takes seconds on a
    // 12 MP phone photo.
    var working = math.max(oriented.width, oriented.height) > _maxInputDimension
        ? source.downscale(_maxInputDimension).toImage()
        : oriented;
    timings['decode'] = stage.elapsedMilliseconds;
    stage.reset();

    final detection = _detectMultiplePolaroids(working);
    final preview = source.downscale(_WindowCardDetector.previewMaxSide);
    final windowCards = _WindowCardDetector(preview).detect();
    final plan = _mergeMultiDetections(
      detection: detection,
      windowCards: windowCards,
      workingToSource: oriented.width / working.width,
      previewToSourceX: oriented.width / preview.width,
      previewToSourceY: oriented.height / preview.height,
    );
    timings['detect'] = stage.elapsedMilliseconds;
    stage.reset();

    final scaleX = oriented.width / working.width;
    final scaleY = oriented.height / working.height;
    final cards = <RecordScanMultiCard>[];
    var refineMs = 0;
    var polishMs = 0;
    var encodeMs = 0;

    // One clean card: run exactly the basic scan so the result matches
    // createBasicScan byte for byte.
    final single = plan.cards.length == 1 &&
            plan.cards.single.candidate != null &&
            !plan.cards.single.splitFromMerged
        ? plan.cards.single.candidate!
        : null;
    if (single != null) {
      if (!identical(working, oriented)) {
        working = _limitInputSize(oriented);
      }
      final refined = _refineWithSingleFlow(
            working,
            single.box,
            aspectRatio: _polaroidAspectRatio,
            luminanceThreshold: _defaultLuminanceThreshold,
            wholeImage: true,
          ) ??
          _rectifyOrientedBox(working, single.box);
      refineMs += stage.elapsedMilliseconds;
      stage.reset();
      final processed = _applyQuickAntiGlare(
        _resizeToTargetFrame(refined.image, aspectRatio: _polaroidAspectRatio),
      );
      polishMs += stage.elapsedMilliseconds;
      stage.reset();
      final bytes = Uint8List.fromList(img.encodeJpg(processed, quality: 94));
      encodeMs += stage.elapsedMilliseconds;
      final ratio = single.box.ratio;
      cards.add(_multiCard(
        bytes: bytes,
        quad: [
          for (final p in refined.quad) math.Point(p.x * scaleX, p.y * scaleY),
        ],
        sourceWidth: oriented.width,
        sourceHeight: oriented.height,
        ratio: ratio,
        confidence: single.confidence,
        splitFromMerged: false,
      ));
    } else {
      for (final planned in plan.cards) {
        stage.reset();
        var quad = planned.sourceQuad;
        final candidate = planned.candidate;
        var ratio = candidate?.box.ratio ?? _quadRatio(quad!);
        if (candidate != null) {
          final sizeClass =
              _classifyCardRatio(ratio, windowAspect: planned.windowAspect);
          final aspectRatio = switch (sizeClass) {
            RecordScanCardSize.mini => _miniCardRatio,
            RecordScanCardSize.wide => _polaroidAspectRatio,
            RecordScanCardSize.uncertain => ratio,
          };
          final refined = (candidate.splitFromMerged
                  ? null
                  : _refineWithSingleFlow(
                      working,
                      candidate.box,
                      aspectRatio: aspectRatio,
                      luminanceThreshold: detection.luminanceThreshold,
                      wholeImage: false,
                    )) ??
              _rectifyOrientedBox(working, candidate.box);
          quad = [
            for (final p in refined.quad)
              math.Point(p.x * scaleX, p.y * scaleY),
          ];
        }
        final sizeClass =
            _classifyCardRatio(ratio, windowAspect: planned.windowAspect);
        final aspectRatio = switch (sizeClass) {
          RecordScanCardSize.mini => _miniCardRatio,
          RecordScanCardSize.wide => _polaroidAspectRatio,
          RecordScanCardSize.uncertain => ratio,
        };
        final crop = _cropFromSource(source, quad!, aspectRatio);
        refineMs += stage.elapsedMilliseconds;
        stage.reset();

        crop.applyQuickAntiGlare();
        final rawCrop = crop.toImage();
        final framed = _resizeToTargetFrame(
          rawCrop,
          aspectRatio: aspectRatio,
        );
        // Only sharpen crops that really were enlarged; a full-resolution
        // close-up is already sharp and the 3×3 pass would cost time.
        final polished = math.max(rawCrop.width, rawCrop.height) * 10 <
                _targetLongSide * 7
            ? _sharpenFrame(framed)
            : framed;
        polishMs += stage.elapsedMilliseconds;
        stage.reset();

        final bytes = Uint8List.fromList(img.encodeJpg(polished, quality: 94));
        encodeMs += stage.elapsedMilliseconds;
        cards.add(_multiCard(
          bytes: bytes,
          quad: quad,
          sourceWidth: oriented.width,
          sourceHeight: oriented.height,
          ratio: ratio,
          confidence: planned.confidence,
          splitFromMerged: planned.splitFromMerged,
          sizeClass: sizeClass,
        ));
      }
    }

    timings['refine'] = refineMs;
    timings['polish'] = polishMs;
    timings['encode'] = encodeMs;
    timings['total'] = total.elapsedMilliseconds;

    return RecordScanMultiResult(
      cards: _sortReadingOrder(cards),
      warnings: plan.warnings,
      sourceWidth: oriented.width,
      sourceHeight: oriented.height,
      stageMilliseconds: timings,
    );
  }

  static RecordScanMultiCard _multiCard({
    required Uint8List bytes,
    required List<math.Point<double>> quad,
    required int sourceWidth,
    required int sourceHeight,
    required double ratio,
    required double confidence,
    required bool splitFromMerged,
    RecordScanCardSize? sizeClass,
  }) {
    return RecordScanMultiCard(
      bytes: bytes,
      fileExtension: '.jpg',
      processingMode: ActivityRecordMediaProcessingMode.antiGlareBasic,
      quad: RecordScanQuad(
        topLeftX: quad[0].x,
        topLeftY: quad[0].y,
        topRightX: quad[1].x,
        topRightY: quad[1].y,
        bottomRightX: quad[2].x,
        bottomRightY: quad[2].y,
        bottomLeftX: quad[3].x,
        bottomLeftY: quad[3].y,
      ).clampToBounds(imageWidth: sourceWidth, imageHeight: sourceHeight),
      sizeClass: sizeClass ?? _classifyCardRatio(ratio),
      aspectRatio: ratio,
      confidence: confidence,
      splitFromMerged: splitFromMerged,
    );
  }

  /// Short / long side of a quad, from the mean of opposite sides.
  static double _quadRatio(List<math.Point<double>> q) {
    final w = (q[0].distanceTo(q[1]) + q[2].distanceTo(q[3])) / 2;
    final h = (q[1].distanceTo(q[2]) + q[3].distanceTo(q[0])) / 2;
    final long = math.max(w, h);
    return long <= 0 ? 0 : math.min(w, h) / long;
  }

  /// Rectifies [quad] from the full-resolution source at its natural size
  /// (long side capped at [_targetLongSide]), with the card's aspect ratio.
  static _Rgb _cropFromSource(
    _Rgb source,
    List<math.Point<double>> quad,
    double aspectRatio,
  ) {
    final w = (quad[0].distanceTo(quad[1]) + quad[2].distanceTo(quad[3])) / 2;
    final h = (quad[1].distanceTo(quad[2]) + quad[3].distanceTo(quad[0])) / 2;
    final long = math.min(_targetLongSide.toDouble(), math.max(w, h));
    final short = math.max(2, (long * aspectRatio).round());
    final portrait = h >= w;
    return source.rectify(
      quad,
      portrait ? short : math.max(2, long.round()),
      portrait ? math.max(2, long.round()) : short,
    );
  }

  /// Combines the white-component detector with the window detector.
  /// Clean single components from the former are kept where both agree
  /// (they were tuned on clean layouts); window cards replace blobs that
  /// hold several cards and fill in cards the former missed.
  static _MultiPlan _mergeMultiDetections({
    required _MultiDetection detection,
    required List<_WindowCard> windowCards,
    required double workingToSource,
    required double previewToSourceX,
    required double previewToSourceY,
  }) {
    final windows = [
      for (final card in windowCards)
        [
          for (final p in card.outer)
            math.Point(p.x * previewToSourceX, p.y * previewToSourceY),
        ],
    ];
    final windowUsed = List<bool>.filled(windows.length, true);
    final planned = <_PlannedCard>[];
    for (final candidate in detection.candidates) {
      final poly = [
        for (final p in candidate.box.corners)
          math.Point(p.x * workingToSource, p.y * workingToSource),
      ];
      final area = _polygonArea(poly).abs();
      final overlapping = <int>[];
      for (var i = 0; i < windows.length; i++) {
        final inter = _polygonIntersectionArea(poly, windows[i]);
        final small = math.min(area, _polygonArea(windows[i]).abs());
        if (small > 0 && inter / small > 0.3) {
          overlapping.add(i);
        }
      }
      if (overlapping.isEmpty) {
        planned.add(_PlannedCard.fromCandidate(candidate));
        continue;
      }
      if (overlapping.length >= 2) {
        continue; // One blob holding several cards.
      }
      final i = overlapping.single;
      final iou = _polygonIoU(poly, windows[i]);
      final trustCandidate = iou >= 0.8 ||
          (!candidate.splitFromMerged &&
              candidate.confidence >= 0.7 &&
              windowCards[i].seenSides < 4);
      if (trustCandidate) {
        planned.add(_PlannedCard.fromCandidate(candidate,
            windowAspect: windowCards[i].windowAspect));
        windowUsed[i] = false;
      }
    }
    var usedWindows = false;
    for (var i = 0; i < windows.length; i++) {
      if (!windowUsed[i]) continue;
      // Two window cards never claim the same area; keep the first.
      final clash = planned.any((p) =>
          p.sourceQuad != null &&
          _polygonIntersectionArea(p.sourceQuad!, windows[i]) >
              0.5 * _polygonArea(windows[i]).abs());
      if (clash) continue;
      usedWindows = true;
      planned.add(_PlannedCard(
        candidate: null,
        sourceQuad: windows[i],
        confidence: windowCards[i].confidence,
        splitFromMerged: windowCards[i].seenSides < 4,
        windowAspect: windowCards[i].windowAspect,
      ));
    }

    final warnings = [...detection.warnings];
    if (usedWindows) {
      warnings
        ..remove(RecordScanMultiWarning.lightBackground)
        ..remove(RecordScanMultiWarning.noneDetected);
    }
    if (planned.any((p) => p.splitFromMerged) &&
        !warnings.contains(RecordScanMultiWarning.possiblyMerged)) {
      warnings.add(RecordScanMultiWarning.possiblyMerged);
    }
    if (planned.isEmpty &&
        !warnings.contains(RecordScanMultiWarning.noneDetected) &&
        warnings.isEmpty) {
      warnings.add(RecordScanMultiWarning.noneDetected);
    }
    return _MultiPlan(cards: planned, warnings: warnings);
  }

  /// [windowAspect] (see [_WindowCard.windowAspect]) settles cards whose
  /// outline is foreshortened by a slanted shot: a window clearly taller
  /// than wide along the thick border only occurs on instax mini.
  static RecordScanCardSize _classifyCardRatio(
    double ratio, {
    double? windowAspect,
  }) {
    if ((ratio - _miniCardRatio).abs() <= _miniRatioTolerance) {
      return RecordScanCardSize.mini;
    }
    if ((ratio - _wideCardRatio).abs() <= _wideRatioTolerance) {
      return RecordScanCardSize.wide;
    }
    if (windowAspect != null &&
        windowAspect <= _miniWindowAspectMax &&
        (ratio - _miniCardRatio).abs() <= _miniRatioPerspectiveTolerance) {
      return RecordScanCardSize.mini;
    }
    return RecordScanCardSize.uncertain;
  }

  /// Crops the card's neighbourhood and hands it to the single-card
  /// pipeline. Returns null when that pipeline loses the card or its box
  /// disagrees with the detected outline, so the caller can rectify the
  /// detected outline instead.
  static _RefinedCard? _refineWithSingleFlow(
    img.Image working,
    _OrientedBox box, {
    required double aspectRatio,
    required double luminanceThreshold,
    required bool wholeImage,
  }) {
    var left = 0;
    var top = 0;
    var source = working;
    if (!wholeImage) {
      final corners = box.corners;
      final minX = corners.map((p) => p.x).reduce(math.min);
      final maxX = corners.map((p) => p.x).reduce(math.max);
      final minY = corners.map((p) => p.y).reduce(math.min);
      final maxY = corners.map((p) => p.y).reduce(math.max);
      // Narrower than the single-card size gate (12%), so slivers of
      // neighbouring cards inside the margin are ignored by detection.
      final margin = (math.max(maxX - minX, maxY - minY) * 0.08).round() + 4;
      left = math.max(0, minX.floor() - margin);
      top = math.max(0, minY.floor() - margin);
      final right = math.min(working.width - 1, maxX.ceil() + margin);
      final bottom = math.min(working.height - 1, maxY.ceil() + margin);
      if (right - left < 8 || bottom - top < 8) {
        return null;
      }
      source = img.copyCrop(
        working,
        x: left,
        y: top,
        width: right - left + 1,
        height: bottom - top + 1,
      );
    }

    // The single-card flow only deskews up to 28°. For steeper cards, turn
    // the crop by the detected angle first; the full-resolution flow then
    // corrects whatever small error the thumbnail angle had.
    var preRotation = 0.0;
    final cropWidth = source.width;
    final cropHeight = source.height;
    final tilt = math.atan2(box.uy, box.ux) * 180 / math.pi;
    if (!wholeImage && tilt.abs() > _steepTiltDegrees) {
      preRotation = -tilt;
      source = img.copyRotate(
        source,
        angle: preRotation,
        interpolation: img.Interpolation.linear,
      );
    }

    final prepared = _prepareWorkingImage(
      source,
      aspectRatio: aspectRatio,
      luminanceThreshold: luminanceThreshold,
    );
    if (prepared.usedFallback) {
      return null;
    }
    final rect = prepared.cropRect;
    math.Point<double> toWorking(int x, int y) {
      final inSource = _rotatedToSource(
        prepared.rotationDegrees,
        prepared.sourceWidth,
        prepared.sourceHeight,
        x,
        y,
      );
      final inCrop = _rotatedToSource(
        preRotation,
        cropWidth,
        cropHeight,
        inSource.x,
        inSource.y,
      );
      return math.Point(inCrop.x + left, inCrop.y + top);
    }

    final quad = [
      toWorking(rect.left, rect.top),
      toWorking(rect.right, rect.top),
      toWorking(rect.right, rect.bottom),
      toWorking(rect.left, rect.bottom),
    ];
    if (_polygonIoU(quad, box.corners) < 0.75) {
      return null;
    }
    return _RefinedCard(
      image: img.copyCrop(
        prepared.image,
        x: rect.left,
        y: rect.top,
        width: rect.width,
        height: rect.height,
      ),
      quad: quad,
    );
  }

  /// Inverse of img.copyRotate's pixel mapping (image 4.x, generic angle):
  /// a pixel in the rotated canvas back to the pre-rotation image.
  static math.Point<double> _rotatedToSource(
    double rotationDegrees,
    int w,
    int h,
    num x,
    num y,
  ) {
    if (rotationDegrees % 90.0 == 0) {
      // copyRotate takes other code paths for right angles; callers only
      // rotate by 0 or by non-right angles.
      return math.Point(x.toDouble(), y.toDouble());
    }
    final rad = (rotationDegrees % 360.0) * math.pi / 180.0;
    final ca = math.cos(rad);
    final sa = math.sin(rad);
    final dw2 = 0.5 * ((w * ca).abs() + (h * sa).abs());
    final dh2 = 0.5 * ((w * sa).abs() + (h * ca).abs());
    return math.Point(
      0.5 * w + (x - dw2) * ca + (y - dh2) * sa,
      0.5 * h - (x - dw2) * sa + (y - dh2) * ca,
    );
  }

  static _RefinedCard _rectifyOrientedBox(img.Image working, _OrientedBox box) {
    final maxX = (working.width - 1).toDouble();
    final maxY = (working.height - 1).toDouble();
    final corners = box.corners
        .map((p) =>
            math.Point<double>(p.x.clamp(0.0, maxX), p.y.clamp(0.0, maxY)))
        .toList(growable: false);
    var targetWidth = math.max(2, (box.halfWidth * 2).round());
    var targetHeight = math.max(2, (box.halfHeight * 2).round());
    final longest = math.max(targetWidth, targetHeight);
    if (longest > _maxInputDimension) {
      final scale = _maxInputDimension / longest;
      targetWidth = math.max(2, (targetWidth * scale).round());
      targetHeight = math.max(2, (targetHeight * scale).round());
    }
    final rectified = img.copyRectify(
      working,
      topLeft: img.Point(corners[0].x, corners[0].y),
      topRight: img.Point(corners[1].x, corners[1].y),
      bottomRight: img.Point(corners[2].x, corners[2].y),
      bottomLeft: img.Point(corners[3].x, corners[3].y),
      interpolation: img.Interpolation.linear,
      toImage: img.Image(width: targetWidth, height: targetHeight),
    );
    return _RefinedCard(image: rectified, quad: corners);
  }

  static List<RecordScanMultiCard> _sortReadingOrder(
    List<RecordScanMultiCard> cards,
  ) {
    if (cards.length < 2) {
      return cards;
    }
    math.Point<double> center(RecordScanMultiCard card) {
      final q = card.quad;
      return math.Point(
        (q.topLeftX + q.topRightX + q.bottomLeftX + q.bottomRightX) / 4,
        (q.topLeftY + q.topRightY + q.bottomLeftY + q.bottomRightY) / 4,
      );
    }

    double shortSide(RecordScanMultiCard card) {
      final q = card.quad;
      return math.min(
        _distance(q.topLeftX, q.topLeftY, q.topRightX, q.topRightY),
        _distance(q.topLeftX, q.topLeftY, q.bottomLeftX, q.bottomLeftY),
      );
    }

    final byY = [...cards]..sort((a, b) => center(a).y.compareTo(center(b).y));
    final sides = cards.map(shortSide).toList()..sort();
    final rowTolerance = sides[sides.length ~/ 2] * 0.5;
    final rows = <List<RecordScanMultiCard>>[];
    var rowStartY = double.negativeInfinity;
    for (final card in byY) {
      final y = center(card).y;
      if (rows.isEmpty || y - rowStartY > rowTolerance) {
        rows.add([]);
        rowStartY = y;
      }
      rows.last.add(card);
    }
    return [
      for (final row in rows)
        ...(row..sort((a, b) => center(a).x.compareTo(center(b).x))),
    ];
  }

  /// Finds every bright, neutral, roughly rectangular blob (a polaroid's
  /// white frame) on a 640px thumbnail. Unlike [_detectPolaroid] it keeps
  /// all candidates, has no centre preference and a much smaller size gate.
  static _MultiDetection _detectMultiplePolaroids(img.Image image) {
    final preview = _buildPreview(image, maxSide: _multiPreviewMaxSide);
    final width = preview.width;
    final height = preview.height;
    final area = width * height;
    final luma = Uint8List(area);
    final chroma = Uint8List(area);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final pixel = preview.getPixel(x, y);
        final red = pixel.r.toInt();
        final green = pixel.g.toInt();
        final blue = pixel.b.toInt();
        final index = (y * width) + x;
        luma[index] = _clampChannel(_luminance(red, green, blue));
        chroma[index] = _chroma(red, green, blue);
      }
    }

    final warnings = <RecordScanMultiWarning>[];
    var threshold = _defaultLuminanceThreshold;
    var components = _labelBrightComponents(
      luma: luma,
      chroma: chroma,
      width: width,
      height: height,
      threshold: threshold,
    );
    // A component covering half the image border is background, not a
    // card. Retry with a threshold between background and card white; if
    // they are too close, warn instead of cutting arbitrary pieces.
    bool hasBackground(_BrightLabeling labeling) =>
        labeling.components.any((c) => c.borderFraction >= 0.5);
    if (hasBackground(components)) {
      final adaptive = _adaptiveBrightThreshold(luma, chroma, width, height);
      if (adaptive != null) {
        final retry = _labelBrightComponents(
          luma: luma,
          chroma: chroma,
          width: width,
          height: height,
          threshold: adaptive,
        );
        if (!hasBackground(retry)) {
          components = retry;
          threshold = adaptive;
        }
      }
      if (hasBackground(components)) {
        warnings.add(RecordScanMultiWarning.lightBackground);
      }
    }

    final minSide = math.max(width, height) * 0.05;
    final raw = <_MultiCandidate>[];
    var mergedSuspected = false;
    for (final component in components.components) {
      if (component.borderFraction >= 0.5) {
        continue;
      }
      final hull = _convexHull(component.hullPoints());
      if (hull.length < 3) {
        continue;
      }
      final box = _minAreaBox(hull);
      final boxArea = box.area;
      if (box.shortSide < minSide || boxArea <= 0) {
        continue;
      }
      final rectangularity = _polygonArea(hull).abs() / boxArea;
      final density = component.count / boxArea;
      if (density < 0.12 || density > 0.9) {
        continue;
      }
      if (rectangularity < 0.85) {
        // Large frame-like blob that is not a rectangle: overlapping or
        // touching cards at different angles. Do not guess a cut.
        if (boxArea >= area * 0.02) {
          mergedSuspected = true;
        }
        continue;
      }
      final holes = _findHoles(components.labels, width, component)
          .where((hole) => hole.area >= boxArea * 0.04)
          .toList(growable: false);
      if (holes.length >= 2) {
        mergedSuspected = true;
        final pieces = _splitMergedBox(box, holes);
        if (pieces == null) {
          continue;
        }
        for (final piece in pieces) {
          raw.add(_MultiCandidate(
            box: piece,
            confidence: _multiConfidence(
                  ratio: piece.ratio,
                  rectangularity: rectangularity,
                  density: density,
                  holeCount: 1,
                ) *
                0.85,
            splitFromMerged: true,
          ));
        }
        continue;
      }
      if (box.ratio < 0.5) {
        continue;
      }
      raw.add(_MultiCandidate(
        box: box,
        confidence: _multiConfidence(
          ratio: box.ratio,
          rectangularity: rectangularity,
          density: density,
          holeCount: holes.length,
        ),
        splitFromMerged: false,
      ));
    }
    if (mergedSuspected) {
      warnings.add(RecordScanMultiWarning.possiblyMerged);
    }

    // Non-maximum suppression. Components are disjoint, so this mainly
    // drops white stickers inside a card's photo and duplicate split pieces.
    raw
      ..removeWhere((c) => c.confidence < 0.4)
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final kept = <_MultiCandidate>[];
    for (final candidate in raw) {
      final suppressed = kept.any((other) {
        final iou = _polygonIoU(candidate.box.corners, other.box.corners);
        final contained =
            _polygonIntersectionArea(candidate.box.corners, other.box.corners) /
                math.min(candidate.box.area, other.box.area);
        return iou > 0.3 || contained > 0.6;
      });
      if (!suppressed) {
        kept.add(candidate);
      }
    }

    final scaleX = image.width / width;
    final scaleY = image.height / height;
    final scaled = kept
        .map((c) => _MultiCandidate(
              box: c.box.scaled(scaleX, scaleY),
              confidence: c.confidence,
              splitFromMerged: c.splitFromMerged,
            ))
        .toList(growable: false);
    if (scaled.isEmpty) {
      warnings.add(RecordScanMultiWarning.noneDetected);
    }
    return _MultiDetection(
      candidates: scaled,
      warnings: warnings,
      luminanceThreshold: threshold,
    );
  }

  static double _multiConfidence({
    required double ratio,
    required double rectangularity,
    required double density,
    required int holeCount,
  }) {
    final classFit = math.max(
      1 - (ratio - _miniCardRatio).abs() / 0.12,
      1 - (ratio - _wideCardRatio).abs() / 0.12,
    );
    final ratioScore = _clampDouble(classFit, 0.3, 1);
    final rectScore = _clampDouble((rectangularity - 0.85) / 0.13, 0, 1);
    final densityScore = 1 - _clampDouble((density - 0.38).abs() / 0.4, 0, 1);
    final holeScore = holeCount == 1 ? 1.0 : 0.5;
    return (rectScore * 0.35) +
        (ratioScore * 0.25) +
        (densityScore * 0.15) +
        (holeScore * 0.25);
  }

  /// Splits a merged block along its long axis into one piece per photo
  /// window when every piece has a card-like ratio and holds exactly one
  /// window. Returns null when that does not fit (e.g. a 2×2 block).
  static List<_OrientedBox>? _splitMergedBox(
    _OrientedBox box,
    List<_Hole> holes,
  ) {
    final count = holes.length;
    if (count > 4) {
      return null;
    }
    final alongWidth = box.halfWidth >= box.halfHeight;
    final longSide = box.longSide;
    final pieceLong = longSide / count;
    final pieceRatio =
        math.min(pieceLong, box.shortSide) / math.max(pieceLong, box.shortSide);
    if (pieceRatio < 0.5) {
      return null;
    }
    final axisX = alongWidth ? box.ux : -box.uy;
    final axisY = alongWidth ? box.uy : box.ux;
    final used = List<bool>.filled(count, false);
    for (final hole in holes) {
      final t =
          ((hole.centerX - box.cx) * axisX) + ((hole.centerY - box.cy) * axisY);
      final index = ((t + longSide / 2) / pieceLong).floor();
      if (index < 0 || index >= count || used[index]) {
        return null;
      }
      used[index] = true;
    }
    return [
      for (var i = 0; i < count; i++)
        _OrientedBox(
          cx: box.cx + axisX * (-longSide / 2 + pieceLong * (i + 0.5)),
          cy: box.cy + axisY * (-longSide / 2 + pieceLong * (i + 0.5)),
          ux: box.ux,
          uy: box.uy,
          halfWidth: alongWidth ? pieceLong / 2 : box.halfWidth,
          halfHeight: alongWidth ? box.halfHeight : pieceLong / 2,
        ),
    ];
  }

  static double? _adaptiveBrightThreshold(
    Uint8List luma,
    Uint8List chroma,
    int width,
    int height,
  ) {
    final borderHistogram = List<int>.filled(256, 0);
    var borderCount = 0;
    final neutralHistogram = List<int>.filled(256, 0);
    var neutralCount = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final index = (y * width) + x;
        if (x == 0 || y == 0 || x == width - 1 || y == height - 1) {
          borderHistogram[luma[index]] += 1;
          borderCount += 1;
        }
        if (chroma[index] <= _maxNeutralChroma) {
          neutralHistogram[luma[index]] += 1;
          neutralCount += 1;
        }
      }
    }
    int percentile(List<int> histogram, int total, double fraction) {
      final target = total * fraction;
      var seen = 0;
      for (var value = 0; value < 256; value++) {
        seen += histogram[value];
        if (seen >= target) {
          return value;
        }
      }
      return 255;
    }

    if (borderCount == 0 || neutralCount == 0) {
      return null;
    }
    final background = percentile(borderHistogram, borderCount, 0.5);
    final white = percentile(neutralHistogram, neutralCount, 0.99);
    if (white - background < 40) {
      return null;
    }
    final threshold = (background + white) / 2;
    return threshold > _defaultLuminanceThreshold + 10 ? threshold : null;
  }

  static _BrightLabeling _labelBrightComponents({
    required Uint8List luma,
    required Uint8List chroma,
    required int width,
    required int height,
    required double threshold,
  }) {
    final area = width * height;
    final mask = Uint8List(area);
    for (var i = 0; i < area; i++) {
      if (luma[i] >= threshold && chroma[i] <= _maxNeutralChroma) {
        mask[i] = 1;
      }
    }
    final labels = Int32List(area);
    final queue = Int32List(area);
    final minCount = math.max(24, (area * 0.0015).round());
    final borderLength = math.max(1, (2 * width) + (2 * height) - 4);
    final components = <_BrightComponent>[];
    var nextLabel = 1;

    for (var start = 0; start < area; start++) {
      if (mask[start] == 0 || labels[start] != 0) {
        continue;
      }
      final label = nextLabel++;
      var head = 0;
      var tail = 0;
      queue[tail++] = start;
      labels[start] = label;
      while (head < tail) {
        final current = queue[head++];
        final x = current % width;
        final y = current ~/ width;
        for (var dy = -1; dy <= 1; dy++) {
          final ny = y + dy;
          if (ny < 0 || ny >= height) {
            continue;
          }
          for (var dx = -1; dx <= 1; dx++) {
            final nx = x + dx;
            if (nx < 0 || nx >= width || (dx == 0 && dy == 0)) {
              continue;
            }
            final next = (ny * width) + nx;
            if (mask[next] == 1 && labels[next] == 0) {
              labels[next] = label;
              queue[tail++] = next;
            }
          }
        }
      }
      if (tail < minCount) {
        continue;
      }

      var minX = width;
      var minY = height;
      var maxX = -1;
      var maxY = -1;
      var onBorder = 0;
      for (var i = 0; i < tail; i++) {
        final x = queue[i] % width;
        final y = queue[i] ~/ width;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        if (x == 0 || y == 0 || x == width - 1 || y == height - 1) {
          onBorder += 1;
        }
      }
      final rows = maxY - minY + 1;
      final rowMin = Int32List(rows)..fillRange(0, rows, width);
      final rowMax = Int32List(rows)..fillRange(0, rows, -1);
      for (var i = 0; i < tail; i++) {
        final x = queue[i] % width;
        final row = (queue[i] ~/ width) - minY;
        if (x < rowMin[row]) rowMin[row] = x;
        if (x > rowMax[row]) rowMax[row] = x;
      }
      components.add(_BrightComponent(
        label: label,
        count: tail,
        borderFraction: onBorder / borderLength,
        minX: minX,
        minY: minY,
        maxX: maxX,
        maxY: maxY,
        rowMin: rowMin,
        rowMax: rowMax,
      ));
    }
    return _BrightLabeling(labels: labels, components: components);
  }

  /// Photo windows: regions inside the component's bounding box that are
  /// not part of the component and cannot reach the box edge.
  static List<_Hole> _findHoles(
    Int32List labels,
    int width,
    _BrightComponent component,
  ) {
    final boxWidth = component.maxX - component.minX + 1;
    final boxHeight = component.maxY - component.minY + 1;
    final cells = Uint8List(boxWidth * boxHeight); // 0 free, 1 wall, 2 seen
    for (var y = 0; y < boxHeight; y++) {
      final rowOffset = (component.minY + y) * width + component.minX;
      for (var x = 0; x < boxWidth; x++) {
        if (labels[rowOffset + x] == component.label) {
          cells[(y * boxWidth) + x] = 1;
        }
      }
    }
    final queue = Int32List(cells.length);

    // Returns (area, sumX, sumY) of the free region containing [start].
    (int, double, double) flood(int start) {
      var head = 0;
      var tail = 0;
      var sumX = 0.0;
      var sumY = 0.0;
      queue[tail++] = start;
      cells[start] = 2;
      while (head < tail) {
        final current = queue[head++];
        final x = current % boxWidth;
        final y = current ~/ boxWidth;
        sumX += x;
        sumY += y;
        void visit(int nx, int ny) {
          if (nx < 0 || ny < 0 || nx >= boxWidth || ny >= boxHeight) {
            return;
          }
          final next = (ny * boxWidth) + nx;
          if (cells[next] == 0) {
            cells[next] = 2;
            queue[tail++] = next;
          }
        }

        visit(x - 1, y);
        visit(x + 1, y);
        visit(x, y - 1);
        visit(x, y + 1);
      }
      return (tail, sumX, sumY);
    }

    for (var x = 0; x < boxWidth; x++) {
      for (final y in [0, boxHeight - 1]) {
        if (cells[(y * boxWidth) + x] == 0) flood((y * boxWidth) + x);
      }
    }
    for (var y = 0; y < boxHeight; y++) {
      for (final x in [0, boxWidth - 1]) {
        if (cells[(y * boxWidth) + x] == 0) flood((y * boxWidth) + x);
      }
    }
    final holes = <_Hole>[];
    for (var i = 0; i < cells.length; i++) {
      if (cells[i] != 0) {
        continue;
      }
      final (count, sumX, sumY) = flood(i);
      holes.add(_Hole(
        area: count,
        // +0.5: pixel centres, matching the hull's pixel-corner coordinates.
        centerX: component.minX + (sumX / count) + 0.5,
        centerY: component.minY + (sumY / count) + 0.5,
      ));
    }
    return holes;
  }

  /// Andrew's monotone chain; returns the hull counter-clockwise in a
  /// y-up sense (clockwise on screen), without the closing point.
  static List<math.Point<double>> _convexHull(List<math.Point<double>> input) {
    final points = [...input]..sort((a, b) {
        final byX = a.x.compareTo(b.x);
        return byX != 0 ? byX : a.y.compareTo(b.y);
      });
    if (points.length < 3) {
      return points;
    }
    double cross(
            math.Point<double> o, math.Point<double> a, math.Point<double> b) =>
        ((a.x - o.x) * (b.y - o.y)) - ((a.y - o.y) * (b.x - o.x));
    final lower = <math.Point<double>>[];
    for (final p in points) {
      while (lower.length >= 2 &&
          cross(lower[lower.length - 2], lower.last, p) <= 0) {
        lower.removeLast();
      }
      lower.add(p);
    }
    final upper = <math.Point<double>>[];
    for (final p in points.reversed) {
      while (upper.length >= 2 &&
          cross(upper[upper.length - 2], upper.last, p) <= 0) {
        upper.removeLast();
      }
      upper.add(p);
    }
    lower.removeLast();
    upper.removeLast();
    return [...lower, ...upper];
  }

  /// Minimum-area enclosing rectangle: one side is collinear with a hull
  /// edge, so trying every edge direction is exact.
  static _OrientedBox _minAreaBox(List<math.Point<double>> hull) {
    _OrientedBox? best;
    for (var i = 0; i < hull.length; i++) {
      final a = hull[i];
      final b = hull[(i + 1) % hull.length];
      final length = a.distanceTo(b);
      if (length <= 1e-9) {
        continue;
      }
      final ex = (b.x - a.x) / length;
      final ey = (b.y - a.y) / length;
      var minE = double.infinity;
      var maxE = double.negativeInfinity;
      var minN = double.infinity;
      var maxN = double.negativeInfinity;
      for (final p in hull) {
        final e = (p.x * ex) + (p.y * ey);
        final n = (-p.x * ey) + (p.y * ex);
        minE = math.min(minE, e);
        maxE = math.max(maxE, e);
        minN = math.min(minN, n);
        maxN = math.max(maxN, n);
      }
      final boxArea = (maxE - minE) * (maxN - minN);
      if (best != null && boxArea >= best.area) {
        continue;
      }
      final midE = (minE + maxE) / 2;
      final midN = (minN + maxN) / 2;
      best = _OrientedBox.normalized(
        cx: (midE * ex) - (midN * ey),
        cy: (midE * ey) + (midN * ex),
        ux: ex,
        uy: ey,
        halfAlongU: (maxE - minE) / 2,
        halfAlongV: (maxN - minN) / 2,
      );
    }
    return best!;
  }

  static double _polygonArea(List<math.Point<double>> polygon) {
    var sum = 0.0;
    for (var i = 0; i < polygon.length; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % polygon.length];
      sum += (a.x * b.y) - (b.x * a.y);
    }
    return sum / 2;
  }

  /// Sutherland–Hodgman clipping; both polygons must be convex.
  static double _polygonIntersectionArea(
    List<math.Point<double>> subject,
    List<math.Point<double>> clip,
  ) {
    final orientation = _polygonArea(clip).sign;
    var output = subject;
    for (var i = 0; i < clip.length && output.isNotEmpty; i++) {
      final a = clip[i];
      final b = clip[(i + 1) % clip.length];
      double side(math.Point<double> p) =>
          orientation *
          (((b.x - a.x) * (p.y - a.y)) - ((b.y - a.y) * (p.x - a.x)));
      final input = output;
      output = <math.Point<double>>[];
      for (var j = 0; j < input.length; j++) {
        final current = input[j];
        final previous = input[(j + input.length - 1) % input.length];
        final currentSide = side(current);
        final previousSide = side(previous);
        if (currentSide >= 0) {
          if (previousSide < 0) {
            final t = previousSide / (previousSide - currentSide);
            output.add(previous + (current - previous) * t);
          }
          output.add(current);
        } else if (previousSide >= 0) {
          final t = previousSide / (previousSide - currentSide);
          output.add(previous + (current - previous) * t);
        }
      }
    }
    return output.length < 3 ? 0 : _polygonArea(output).abs();
  }

  static double _polygonIoU(
    List<math.Point<double>> a,
    List<math.Point<double>> b,
  ) {
    final intersection = _polygonIntersectionArea(a, b);
    final union = _polygonArea(a).abs() + _polygonArea(b).abs() - intersection;
    return union <= 0 ? 0 : intersection / union;
  }

  static double _luminance(int red, int green, int blue) {
    return (red * 0.2126) + (green * 0.7152) + (blue * 0.0722);
  }

  static int _chroma(int red, int green, int blue) {
    return math.max(red, math.max(green, blue)) -
        math.min(red, math.min(green, blue));
  }

  static double _glarePenalty(int red, int green, int blue) {
    final luminance = _luminance(red, green, blue);
    if (luminance < 218) {
      return 0;
    }
    final chroma = _chroma(red, green, blue);
    final intensity = ((luminance - 218) / 42).clamp(0.0, 1.0);
    final neutrality = (1 - (chroma / 72)).clamp(0.0, 1.0);
    return intensity * (0.35 + (neutrality * 0.65));
  }

  static int _curveChannel(int value) {
    final normalized = value / 255.0;
    final gammaCorrected = math.pow(normalized, 0.96).toDouble();
    final contrasted = ((gammaCorrected - 0.5) * 1.08 + 0.5).clamp(0.0, 1.0);
    return _clampChannel(contrasted * 255);
  }

  static double _mix(num from, num to, double amount) {
    return from + ((to - from) * amount);
  }

  static double _distance(double ax, double ay, double bx, double by) {
    final dx = ax - bx;
    final dy = ay - by;
    return math.sqrt((dx * dx) + (dy * dy));
  }

  static int _clampChannel(num value) {
    return value.round().clamp(0, 255).toInt();
  }

  static double _clampDouble(num value, num min, num max) {
    return value.clamp(min, max).toDouble();
  }
}

class _ScanCandidate {
  final img.Image image;
  final double glareScore;
  final double detectionScore;
  final bool usedFallback;

  const _ScanCandidate({
    required this.image,
    required this.glareScore,
    required this.detectionScore,
    required this.usedFallback,
  });

  double get rankScore =>
      glareScore + (usedFallback ? 0.35 : 0) - (detectionScore * 0.18);
}

class _PreparedScanSource {
  final img.Image image;
  final _IntRect cropRect;
  final double detectionScore;
  final bool usedFallback;

  /// Angle passed to copyRotate (0 when the source was not rotated) and the
  /// size of the image before that rotation, so crop corners can be mapped
  /// back into source coordinates.
  final double rotationDegrees;
  final int sourceWidth;
  final int sourceHeight;

  const _PreparedScanSource({
    required this.image,
    required this.cropRect,
    required this.detectionScore,
    required this.usedFallback,
    required this.rotationDegrees,
    required this.sourceWidth,
    required this.sourceHeight,
  });
}

class _AlignedCandidate {
  final _ScanCandidate candidate;
  final int shiftX;
  final int shiftY;
  final double difference;

  const _AlignedCandidate({
    required this.candidate,
    required this.shiftX,
    required this.shiftY,
    required this.difference,
  });
}

class _FrameAlignment {
  final int shiftX;
  final int shiftY;
  final double difference;

  const _FrameAlignment({
    required this.shiftX,
    required this.shiftY,
    required this.difference,
  });
}

class _DetectedPolaroid {
  final _IntRect rect;
  final double confidence;
  final double rotationDegrees;

  const _DetectedPolaroid({
    required this.rect,
    required this.confidence,
    required this.rotationDegrees,
  });

  _DetectedPolaroid copyWith({
    _IntRect? rect,
    double? confidence,
    double? rotationDegrees,
  }) {
    return _DetectedPolaroid(
      rect: rect ?? this.rect,
      confidence: confidence ?? this.confidence,
      rotationDegrees: rotationDegrees ?? this.rotationDegrees,
    );
  }
}

class _ComponentStats {
  int count = 0;
  int minX = 1 << 30;
  int minY = 1 << 30;
  int maxX = -1;
  int maxY = -1;
  double sumX = 0;
  double sumY = 0;
  double sumXX = 0;
  double sumYY = 0;
  double sumXY = 0;

  void add(int x, int y) {
    count += 1;
    minX = math.min(minX, x);
    minY = math.min(minY, y);
    maxX = math.max(maxX, x);
    maxY = math.max(maxY, y);
    sumX += x;
    sumY += y;
    sumXX += x * x;
    sumYY += y * y;
    sumXY += x * y;
  }

  int get width => (maxX - minX) + 1;

  int get height => (maxY - minY) + 1;

  _IntRect get rect => _IntRect(
        left: minX,
        top: minY,
        width: width,
        height: height,
      );

  double get angleDegrees {
    if (count <= 1) {
      return 0;
    }
    final meanX = sumX / count;
    final meanY = sumY / count;
    final mu20 = (sumXX / count) - (meanX * meanX);
    final mu02 = (sumYY / count) - (meanY * meanY);
    final mu11 = (sumXY / count) - (meanX * meanY);
    return 0.5 * math.atan2(2 * mu11, mu20 - mu02) * 180 / math.pi;
  }
}

class _IntRect {
  final int left;
  final int top;
  final int width;
  final int height;

  const _IntRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  int get right => left + width - 1;

  int get bottom => top + height - 1;
}

class _RefinedCard {
  final img.Image image;

  /// TL, TR, BR, BL in working-image coordinates.
  final List<math.Point<double>> quad;

  const _RefinedCard({required this.image, required this.quad});
}

class _MultiCandidate {
  final _OrientedBox box;
  final double confidence;
  final bool splitFromMerged;

  const _MultiCandidate({
    required this.box,
    required this.confidence,
    required this.splitFromMerged,
  });
}

class _PlannedCard {
  /// From the white-component detector, refined by the single-card flow.
  final _MultiCandidate? candidate;

  /// From the window detector: outer frame in source pixels.
  final List<math.Point<double>>? sourceQuad;
  final double confidence;
  final bool splitFromMerged;

  /// See [_WindowCard.windowAspect]; null when no window was found.
  final double? windowAspect;

  const _PlannedCard({
    required this.candidate,
    required this.sourceQuad,
    required this.confidence,
    required this.splitFromMerged,
    this.windowAspect,
  });

  factory _PlannedCard.fromCandidate(
    _MultiCandidate candidate, {
    double? windowAspect,
  }) =>
      _PlannedCard(
        candidate: candidate,
        sourceQuad: null,
        confidence: candidate.confidence,
        splitFromMerged: candidate.splitFromMerged,
        windowAspect: windowAspect,
      );
}

class _MultiPlan {
  final List<_PlannedCard> cards;
  final List<RecordScanMultiWarning> warnings;

  const _MultiPlan({required this.cards, required this.warnings});
}

class _MultiDetection {
  final List<_MultiCandidate> candidates;
  final List<RecordScanMultiWarning> warnings;
  final double luminanceThreshold;

  const _MultiDetection({
    required this.candidates,
    required this.warnings,
    required this.luminanceThreshold,
  });
}

class _BrightLabeling {
  final Int32List labels;
  final List<_BrightComponent> components;

  const _BrightLabeling({required this.labels, required this.components});
}

class _BrightComponent {
  final int label;
  final int count;

  /// Share of the image's outermost pixel ring covered by this component.
  final double borderFraction;
  final int minX;
  final int minY;
  final int maxX;
  final int maxY;

  /// Leftmost / rightmost pixel of each row from [minY]; enough for the
  /// convex hull.
  final Int32List rowMin;
  final Int32List rowMax;

  const _BrightComponent({
    required this.label,
    required this.count,
    required this.borderFraction,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
    required this.rowMin,
    required this.rowMax,
  });

  /// Pixel-square corners of each row's extremes, so the hull covers whole
  /// pixels rather than pixel centres.
  List<math.Point<double>> hullPoints() {
    final points = <math.Point<double>>[];
    for (var row = 0; row < rowMin.length; row++) {
      if (rowMax[row] < 0) {
        continue;
      }
      final y = (minY + row).toDouble();
      final left = rowMin[row].toDouble();
      final right = rowMax[row] + 1.0;
      points
        ..add(math.Point(left, y))
        ..add(math.Point(right, y))
        ..add(math.Point(left, y + 1))
        ..add(math.Point(right, y + 1));
    }
    return points;
  }
}

class _Hole {
  final int area;
  final double centerX;
  final double centerY;

  const _Hole({
    required this.area,
    required this.centerX,
    required this.centerY,
  });
}

/// A rotated rectangle. (ux, uy) is the unit "width" axis, kept within
/// ±45° of horizontal; the "height" axis (-uy, ux) points down the screen.
class _OrientedBox {
  final double cx;
  final double cy;
  final double ux;
  final double uy;
  final double halfWidth;
  final double halfHeight;

  const _OrientedBox({
    required this.cx,
    required this.cy,
    required this.ux,
    required this.uy,
    required this.halfWidth,
    required this.halfHeight,
  });

  factory _OrientedBox.normalized({
    required double cx,
    required double cy,
    required double ux,
    required double uy,
    required double halfAlongU,
    required double halfAlongV,
  }) {
    var angle = math.atan2(uy, ux);
    var halfWidth = halfAlongU;
    var halfHeight = halfAlongV;
    // Turning the axis by 90° swaps which extent lies along it.
    while (angle > math.pi / 4) {
      angle -= math.pi / 2;
      final swap = halfWidth;
      halfWidth = halfHeight;
      halfHeight = swap;
    }
    while (angle <= -math.pi / 4) {
      angle += math.pi / 2;
      final swap = halfWidth;
      halfWidth = halfHeight;
      halfHeight = swap;
    }
    return _OrientedBox(
      cx: cx,
      cy: cy,
      ux: math.cos(angle),
      uy: math.sin(angle),
      halfWidth: halfWidth,
      halfHeight: halfHeight,
    );
  }

  double get area => 4 * halfWidth * halfHeight;

  double get shortSide => 2 * math.min(halfWidth, halfHeight);

  double get longSide => 2 * math.max(halfWidth, halfHeight);

  double get ratio => longSide <= 0 ? 0 : shortSide / longSide;

  /// TL, TR, BR, BL — clockwise on screen.
  List<math.Point<double>> get corners {
    final wx = ux * halfWidth;
    final wy = uy * halfWidth;
    final hx = -uy * halfHeight;
    final hy = ux * halfHeight;
    return [
      math.Point(cx - wx - hx, cy - wy - hy),
      math.Point(cx + wx - hx, cy + wy - hy),
      math.Point(cx + wx + hx, cy + wy + hy),
      math.Point(cx - wx + hx, cy - wy + hy),
    ];
  }

  /// Preview → full image. The two scales differ only by rounding, so
  /// their mean is used for the extents.
  _OrientedBox scaled(double scaleX, double scaleY) {
    final scale = (scaleX + scaleY) / 2;
    return _OrientedBox(
      cx: cx * scaleX,
      cy: cy * scaleY,
      ux: ux,
      uy: uy,
      halfWidth: halfWidth * scale,
      halfHeight: halfHeight * scale,
    );
  }
}

// ---------------------------------------------------------------------
// Window-anchored multi-card detection
// ---------------------------------------------------------------------

/// Packed 8-bit RGB pixels, three bytes each, no row padding.
class _Rgb {
  final int width;
  final int height;
  final Uint8List data;

  const _Rgb(this.width, this.height, this.data);

  static _Rgb of(img.Image image) {
    if (!image.hasPalette &&
        image.format == img.Format.uint8 &&
        image.numChannels == 3 &&
        image.rowStride == image.width * 3) {
      return _Rgb(image.width, image.height, image.toUint8List());
    }
    if (!image.hasPalette &&
        image.format == img.Format.uint8 &&
        image.numChannels == 4 &&
        image.rowStride == image.width * 4) {
      final source = image.toUint8List();
      final out = Uint8List(image.width * image.height * 3);
      for (var i = 0, j = 0; j < out.length; i += 4, j += 3) {
        out[j] = source[i];
        out[j + 1] = source[i + 1];
        out[j + 2] = source[i + 2];
      }
      return _Rgb(image.width, image.height, out);
    }
    // Palette, 16-bit, float or gray images: rare, so the slow path is fine.
    final out = Uint8List(image.width * image.height * 3);
    var j = 0;
    for (final pixel in image) {
      out[j++] = (pixel.rNormalized * 255).round().clamp(0, 255);
      out[j++] = (pixel.gNormalized * 255).round().clamp(0, 255);
      out[j++] = (pixel.bNormalized * 255).round().clamp(0, 255);
    }
    return _Rgb(image.width, image.height, out);
  }

  img.Image toImage() => img.Image.fromBytes(
        width: width,
        height: height,
        bytes: data.buffer,
        bytesOffset: data.offsetInBytes,
        numChannels: 3,
      );

  /// Area-average downscale so the longest side is at most [maxSide].
  _Rgb downscale(int maxSide) {
    final longest = math.max(width, height);
    if (longest <= maxSide) {
      return this;
    }
    final scale = maxSide / longest;
    final dw = math.max(1, (width * scale).round());
    final dh = math.max(1, (height * scale).round());
    final x0 = Int32List(dw + 1);
    for (var x = 0; x <= dw; x++) {
      x0[x] = math.min(width, (x * width / dw).floor());
    }
    final y0 = Int32List(dh + 1);
    for (var y = 0; y <= dh; y++) {
      y0[y] = math.min(height, (y * height / dh).floor());
    }
    final out = Uint8List(dw * dh * 3);
    final acc = Int32List(dw * 3);
    for (var dy = 0; dy < dh; dy++) {
      acc.fillRange(0, acc.length, 0);
      final syEnd = math.max(y0[dy] + 1, y0[dy + 1]);
      for (var sy = y0[dy]; sy < syEnd && sy < height; sy++) {
        final row = sy * width * 3;
        for (var dx = 0; dx < dw; dx++) {
          final sxEnd = math.max(x0[dx] + 1, x0[dx + 1]);
          var r = 0;
          var g = 0;
          var b = 0;
          for (var sx = x0[dx]; sx < sxEnd && sx < width; sx++) {
            final i = row + sx * 3;
            r += data[i];
            g += data[i + 1];
            b += data[i + 2];
          }
          acc[dx * 3] += r;
          acc[dx * 3 + 1] += g;
          acc[dx * 3 + 2] += b;
        }
      }
      final rows = math.max(1, math.min(height, syEnd) - y0[dy]);
      for (var dx = 0; dx < dw; dx++) {
        final cols = math.max(
            1, math.min(width, math.max(x0[dx] + 1, x0[dx + 1])) - x0[dx]);
        final n = rows * cols;
        final o = (dy * dw + dx) * 3;
        out[o] = (acc[dx * 3] / n).round();
        out[o + 1] = (acc[dx * 3 + 1] / n).round();
        out[o + 2] = (acc[dx * 3 + 2] / n).round();
      }
    }
    return _Rgb(dw, dh, out);
  }

  /// Perspective-correct crop of [quad] (TL, TR, BR, BL in this raster's
  /// pixel coordinates) into a [outWidth]×[outHeight] image, bilinear.
  _Rgb rectify(List<math.Point<double>> quad, int outWidth, int outHeight) {
    final h = _homographyUnitSquareTo(quad);
    final out = Uint8List(outWidth * outHeight * 3);
    final maxX = width - 1;
    final maxY = height - 1;
    var o = 0;
    for (var y = 0; y < outHeight; y++) {
      final v = (y + 0.5) / outHeight;
      for (var x = 0; x < outWidth; x++) {
        final u = (x + 0.5) / outWidth;
        final w = h[6] * u + h[7] * v + 1;
        // Pixel centres sit at +0.5; quad corners are pixel-edge positions.
        var sx = (h[0] * u + h[1] * v + h[2]) / w - 0.5;
        var sy = (h[3] * u + h[4] * v + h[5]) / w - 0.5;
        if (sx < 0) sx = 0;
        if (sy < 0) sy = 0;
        if (sx > maxX) sx = maxX.toDouble();
        if (sy > maxY) sy = maxY.toDouble();
        final ix = sx.floor();
        final iy = sy.floor();
        final fx = sx - ix;
        final fy = sy - iy;
        final ix1 = ix < maxX ? ix + 1 : ix;
        final iy1 = iy < maxY ? iy + 1 : iy;
        final i00 = (iy * width + ix) * 3;
        final i10 = (iy * width + ix1) * 3;
        final i01 = (iy1 * width + ix) * 3;
        final i11 = (iy1 * width + ix1) * 3;
        for (var c = 0; c < 3; c++) {
          final top = data[i00 + c] + (data[i10 + c] - data[i00 + c]) * fx;
          final bottom = data[i01 + c] + (data[i11 + c] - data[i01 + c]) * fx;
          out[o++] = (top + (bottom - top) * fy).round().clamp(0, 255);
        }
      }
    }
    return _Rgb(outWidth, outHeight, out);
  }

  /// Same arithmetic as RecordScanService._applyQuickAntiGlare (gray-world
  /// white balance, then highlight softening), on packed bytes.
  void applyQuickAntiGlare() {
    var count = 0;
    var rSum = 0.0;
    var gSum = 0.0;
    var bSum = 0.0;
    for (var i = 0; i < data.length; i += 3) {
      final r = data[i];
      final g = data[i + 1];
      final b = data[i + 2];
      if (r < 8 && g < 8 && b < 8) {
        continue;
      }
      rSum += r;
      gSum += g;
      bSum += b;
      count++;
    }
    if (count > 0) {
      final ar = rSum / count;
      final ag = gSum / count;
      final ab = bSum / count;
      final target = (ar + ag + ab) / 3;
      final rs = (target / ar).clamp(0.88, 1.16);
      final gs = (target / ag).clamp(0.88, 1.16);
      final bs = (target / ab).clamp(0.88, 1.16);
      for (var i = 0; i < data.length; i += 3) {
        data[i] = (data[i] * rs).round().clamp(0, 255);
        data[i + 1] = (data[i + 1] * gs).round().clamp(0, 255);
        data[i + 2] = (data[i + 2] * bs).round().clamp(0, 255);
      }
    }
    for (var i = 0; i < data.length; i += 3) {
      final r = data[i];
      final g = data[i + 1];
      final b = data[i + 2];
      final lum = RecordScanService._luminance(r, g, b);
      if (lum < 208) {
        continue;
      }
      final chroma = RecordScanService._chroma(r, g, b);
      final level = ((lum - 208) / 46).clamp(0.0, 1.0);
      final blend = level * (chroma < 44 ? 0.72 : 0.36);
      final gray = (r + g + b) / 3;
      final target = 214 + ((lum - 208) * 0.12);
      var nr = (r + (target - r) * blend * 0.95).round().clamp(0, 255);
      var ng = (g + (target - g) * blend).round().clamp(0, 255);
      var nb = (b + (target - b) * blend * 0.92).round().clamp(0, 255);
      if (chroma < 58) {
        nr = (nr + (gray - nr) * blend * 0.55).round().clamp(0, 255);
        ng = (ng + (gray - ng) * blend * 0.55).round().clamp(0, 255);
        nb = (nb + (gray - nb) * blend * 0.55).round().clamp(0, 255);
      }
      data[i] = nr;
      data[i + 1] = ng;
      data[i + 2] = nb;
    }
  }

  /// Maps the unit square (u, v) to [quad] (TL, TR, BR, BL). Returns
  /// [a, b, c, d, e, f, g, h] with x = (au+bv+c)/(gu+hv+1), y likewise.
  static List<double> _homographyUnitSquareTo(List<math.Point<double>> q) {
    final x0 = q[0].x, y0 = q[0].y;
    final x1 = q[1].x, y1 = q[1].y;
    final x2 = q[2].x, y2 = q[2].y;
    final x3 = q[3].x, y3 = q[3].y;
    final sx = x0 - x1 + x2 - x3;
    final sy = y0 - y1 + y2 - y3;
    if (sx.abs() < 1e-9 && sy.abs() < 1e-9) {
      return [x1 - x0, x3 - x0, x0, y1 - y0, y3 - y0, y0, 0, 0];
    }
    final dx1 = x1 - x2, dx2 = x3 - x2;
    final dy1 = y1 - y2, dy2 = y3 - y2;
    final den = dx1 * dy2 - dx2 * dy1;
    final g = (sx * dy2 - dx2 * sy) / den;
    final h = (dx1 * sy - sx * dy1) / den;
    return [
      x1 - x0 + g * x1,
      x3 - x0 + h * x3,
      x0,
      y1 - y0 + g * y1,
      y3 - y0 + h * y3,
      y0,
      g,
      h,
    ];
  }
}

/// A line n·p = rho with unit normal n.
class _Line {
  final double nx;
  final double ny;
  final double rho;

  const _Line(this.nx, this.ny, this.rho);

  factory _Line.through(double nx, double ny, double px, double py) =>
      _Line(nx, ny, nx * px + ny * py);

  math.Point<double>? intersect(_Line other) {
    final det = nx * other.ny - ny * other.nx;
    if (det.abs() < 1e-6) {
      return null;
    }
    return math.Point(
      (rho * other.ny - ny * other.rho) / det,
      (nx * other.rho - rho * other.nx) / det,
    );
  }
}

/// Lines in side order top, right, bottom, left → corners TL, TR, BR, BL.
List<math.Point<double>>? _quadFromLines(List<_Line> lines) {
  final corners = <math.Point<double>>[];
  for (var i = 0; i < 4; i++) {
    final p = lines[(i + 3) % 4].intersect(lines[i]);
    if (p == null || !p.x.isFinite || !p.y.isFinite) {
      return null;
    }
    corners.add(p);
  }
  // Clockwise on screen and convex.
  for (var i = 0; i < 4; i++) {
    final a = corners[i];
    final b = corners[(i + 1) % 4];
    final c = corners[(i + 2) % 4];
    if ((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) <= 0) {
      return null;
    }
  }
  return corners;
}

class _WindowCard {
  /// Outer frame, TL, TR, BR, BL in preview pixels (pixel-edge coordinates).
  final List<math.Point<double>> outer;
  final List<math.Point<double>> window;

  /// How many outer edges were seen in the image (the rest were placed
  /// from the frame proportions).
  final int seenSides;
  final double confidence;

  const _WindowCard({
    required this.outer,
    required this.window,
    required this.seenSides,
    required this.confidence,
  });

  /// Window width over height, height measured along the thick-border
  /// axis: about 0.74 on instax mini (46 × 62 mm), above 1 on WIDE.
  double get windowAspect {
    final w =
        (window[0].distanceTo(window[1]) + window[2].distanceTo(window[3])) / 2;
    final h =
        (window[1].distanceTo(window[2]) + window[3].distanceTo(window[0])) / 2;
    return h <= 0 ? 0 : w / h;
  }
}

/// Finds polaroids by their photo window: a darker quadrilateral whose
/// four straight edges all step up into a white border. Each window is
/// grown from a seed inside it until every side meets such an edge; the
/// outer frame is then searched just outside the window within the
/// border widths instax film allows. Works when cards touch or overlap,
/// sit on a pale or busy background, are seen in perspective, or carry
/// coloured writing on the border — as long as the photo is darker than
/// the border along its edges.
class _WindowCardDetector {
  static const int previewMaxSide = 800;

  final int width;
  final int height;
  final Float32List luma;
  final Uint8List chroma;

  /// Locally normalised white mask after a 5×5 closing (ink on borders
  /// filled in).
  late final Uint8List white;

  /// Looser mask for border bands that may be shaded or tinted.
  late final Uint8List pale;
  late final Float32List gx;
  late final Float32List gy;

  _WindowCardDetector(_Rgb preview)
      : width = preview.width,
        height = preview.height,
        luma = Float32List(preview.width * preview.height),
        chroma = Uint8List(preview.width * preview.height) {
    final d = preview.data;
    for (var i = 0, j = 0; i < luma.length; i++, j += 3) {
      final r = d[j], g = d[j + 1], b = d[j + 2];
      luma[i] = RecordScanService._luminance(r, g, b);
      chroma[i] = RecordScanService._chroma(r, g, b);
    }
    final (strict, loose) = _whiteMasks();
    white = _closing(strict, 2);
    pale = _closing(loose, 2);
    _gradients();
  }

  // ---- masks ---------------------------------------------------------

  (Uint8List, Uint8List) _whiteMasks() {
    // White reference per 16px cell: 95th percentile of near-neutral luma,
    // spread over 5×5 cells so pale backgrounds next to cards are measured
    // against the cards' white, and lighting falloff across the photo is
    // followed.
    const cell = 16;
    final cw = (width + cell - 1) ~/ cell;
    final ch = (height + cell - 1) ~/ cell;
    final ref = Float32List(cw * ch);
    final hist = Int32List(256);
    final global = Int32List(256);
    var globalCount = 0;
    for (var cy = 0; cy < ch; cy++) {
      for (var cx = 0; cx < cw; cx++) {
        hist.fillRange(0, 256, 0);
        var n = 0;
        for (var y = cy * cell; y < math.min(height, (cy + 1) * cell); y++) {
          for (var x = cx * cell; x < math.min(width, (cx + 1) * cell); x++) {
            final i = y * width + x;
            if (chroma[i] <= 40) {
              final v = luma[i].round().clamp(0, 255);
              hist[v]++;
              global[v]++;
              n++;
            }
          }
        }
        globalCount += n;
        ref[cy * cw + cx] = n > 8 ? _percentile(hist, n, 0.95).toDouble() : 0;
      }
    }
    final globalWhite =
        globalCount > 0 ? _percentile(global, globalCount, 0.99) : 255;
    final spread = Float32List(cw * ch);
    for (var cy = 0; cy < ch; cy++) {
      for (var cx = 0; cx < cw; cx++) {
        var best = globalWhite * 0.6;
        for (var y = math.max(0, cy - 2); y <= math.min(ch - 1, cy + 2); y++) {
          for (var x = math.max(0, cx - 2);
              x <= math.min(cw - 1, cx + 2);
              x++) {
            best = math.max(best, ref[y * cw + x]);
          }
        }
        spread[cy * cw + cx] = best;
      }
    }
    final mask = Uint8List(width * height);
    final loose = Uint8List(width * height);
    for (var y = 0; y < height; y++) {
      final fy = ((y + 0.5) / cell - 0.5).clamp(0.0, ch - 1.0);
      final y0 = fy.floor();
      final y1 = math.min(ch - 1, y0 + 1);
      final ty = fy - y0;
      for (var x = 0; x < width; x++) {
        final fx = ((x + 0.5) / cell - 0.5).clamp(0.0, cw - 1.0);
        final x0 = fx.floor();
        final x1 = math.min(cw - 1, x0 + 1);
        final tx = fx - x0;
        final top = spread[y0 * cw + x0] +
            (spread[y0 * cw + x1] - spread[y0 * cw + x0]) * tx;
        final bottom = spread[y1 * cw + x0] +
            (spread[y1 * cw + x1] - spread[y1 * cw + x0]) * tx;
        final reference = top + (bottom - top) * ty;
        final i = y * width + x;
        if (luma[i] >= reference * 0.86 && chroma[i] <= 50) {
          mask[i] = 1;
        }
        if (luma[i] >= reference * 0.66 && chroma[i] <= 60) {
          loose[i] = 1;
        }
      }
    }
    return (mask, loose);
  }

  static int _percentile(Int32List hist, int total, double fraction) {
    final target = total * fraction;
    var seen = 0;
    for (var v = 0; v < 256; v++) {
      seen += hist[v];
      if (seen >= target) {
        return v;
      }
    }
    return 255;
  }

  Uint8List _closing(Uint8List mask, int r) =>
      _morph(_morph(mask, r, dilate: true), r, dilate: false);

  /// Separable square max (dilate) or min (erode) filter; outside the
  /// image counts as the neutral value.
  Uint8List _morph(Uint8List mask, int r, {required bool dilate}) {
    final hit = dilate ? 1 : 0;
    final tmp = Uint8List(mask.length);
    for (var y = 0; y < height; y++) {
      final row = y * width;
      for (var x = 0; x < width; x++) {
        var v = 1 - hit;
        for (var k = math.max(0, x - r); k <= math.min(width - 1, x + r); k++) {
          if (mask[row + k] == hit) {
            v = hit;
            break;
          }
        }
        tmp[row + x] = v;
      }
    }
    final out = Uint8List(mask.length);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var v = 1 - hit;
        for (var k = math.max(0, y - r);
            k <= math.min(height - 1, y + r);
            k++) {
          if (tmp[k * width + x] == hit) {
            v = hit;
            break;
          }
        }
        out[y * width + x] = v;
      }
    }
    return out;
  }

  void _gradients() {
    final n = width * height;
    final tmp = Float32List(n);
    final blur = Float32List(n);
    for (var y = 0; y < height; y++) {
      final row = y * width;
      for (var x = 0; x < width; x++) {
        final l = luma[row + math.max(0, x - 1)];
        final r = luma[row + math.min(width - 1, x + 1)];
        tmp[row + x] = (l + 2 * luma[row + x] + r) / 4;
      }
    }
    for (var y = 0; y < height; y++) {
      final up = math.max(0, y - 1) * width;
      final down = math.min(height - 1, y + 1) * width;
      final row = y * width;
      for (var x = 0; x < width; x++) {
        blur[row + x] = (tmp[up + x] + 2 * tmp[row + x] + tmp[down + x]) / 4;
      }
    }
    gx = Float32List(n);
    gy = Float32List(n);
    for (var y = 1; y < height - 1; y++) {
      for (var x = 1; x < width - 1; x++) {
        final i = y * width + x;
        final a = blur[i - width - 1],
            b = blur[i - width],
            c = blur[i - width + 1];
        final d = blur[i - 1], f = blur[i + 1];
        final g = blur[i + width - 1],
            h = blur[i + width],
            k = blur[i + width + 1];
        gx[i] = ((c + 2 * f + k) - (a + 2 * d + g)) / 8;
        gy[i] = ((g + 2 * h + k) - (a + 2 * b + c)) / 8;
      }
    }
  }

  // ---- sampling ------------------------------------------------------

  int _index(double x, double y) {
    var ix = x.floor();
    var iy = y.floor();
    if (ix < 0) ix = 0;
    if (iy < 0) iy = 0;
    if (ix >= width) ix = width - 1;
    if (iy >= height) iy = height - 1;
    return iy * width + ix;
  }

  /// Directional derivative along (nx, ny) at a pixel-edge coordinate.
  double _grad(double x, double y, double nx, double ny) {
    final i = _index(x, y);
    return gx[i] * nx + gy[i] * ny;
  }

  /// Fraction of white pixels along the segment, [samples] points.
  double _whiteFraction(
      double ax, double ay, double bx, double by, int samples) {
    var hits = 0;
    for (var k = 0; k < samples; k++) {
      final t = (k + 0.5) / samples;
      hits += white[_index(ax + (bx - ax) * t, ay + (by - ay) * t)];
    }
    return hits / samples;
  }

  /// Like [_whiteFraction] on the looser [pale] mask.
  double _paleFraction(
      double ax, double ay, double bx, double by, int samples) {
    var hits = 0;
    for (var k = 0; k < samples; k++) {
      final t = (k + 0.5) / samples;
      hits += pale[_index(ax + (bx - ax) * t, ay + (by - ay) * t)];
    }
    return hits / samples;
  }

  // ---- seeds ---------------------------------------------------------

  /// Non-white regions enclosed by white (photo windows, possibly cut into
  /// pieces by white content), and distance-transform peaks of the
  /// non-white area for windows whose border is broken by thick ink.
  List<_WindowSeed> _seeds() {
    final area = width * height;
    final labels = Int32List(area);
    final queue = Int32List(area);
    final seeds = <_WindowSeed>[];
    final minArea = math.max(40, (area * 0.0015).round());
    var next = 1;
    for (var start = 0; start < area; start++) {
      if (white[start] == 1 || labels[start] != 0) {
        continue;
      }
      final label = next++;
      var head = 0;
      var tail = 0;
      queue[tail++] = start;
      labels[start] = label;
      var touchesEdge = false;
      while (head < tail) {
        final cur = queue[head++];
        final x = cur % width;
        final y = cur ~/ width;
        if (x == 0 || y == 0 || x == width - 1 || y == height - 1) {
          touchesEdge = true;
        }
        if (x > 0 && white[cur - 1] == 0 && labels[cur - 1] == 0) {
          labels[cur - 1] = label;
          queue[tail++] = cur - 1;
        }
        if (x < width - 1 && white[cur + 1] == 0 && labels[cur + 1] == 0) {
          labels[cur + 1] = label;
          queue[tail++] = cur + 1;
        }
        if (y > 0 && white[cur - width] == 0 && labels[cur - width] == 0) {
          labels[cur - width] = label;
          queue[tail++] = cur - width;
        }
        if (y < height - 1 &&
            white[cur + width] == 0 &&
            labels[cur + width] == 0) {
          labels[cur + width] = label;
          queue[tail++] = cur + width;
        }
      }
      if (touchesEdge || tail < minArea) {
        continue;
      }
      seeds.add(_WindowSeed.fromPixels(queue, tail, width));
    }
    seeds.sort((a, b) => b.area.compareTo(a.area));

    // Chamfer distance to the nearest white pixel.
    final dist = Int32List(area);
    const big = 1 << 28;
    for (var i = 0; i < area; i++) {
      dist[i] = white[i] == 1 ? 0 : big;
    }
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        var v = dist[i];
        if (v == 0) continue;
        if (x > 0) v = math.min(v, dist[i - 1] + 3);
        if (y > 0) {
          v = math.min(v, dist[i - width] + 3);
          if (x > 0) v = math.min(v, dist[i - width - 1] + 4);
          if (x < width - 1) v = math.min(v, dist[i - width + 1] + 4);
        }
        dist[i] = v;
      }
    }
    for (var y = height - 1; y >= 0; y--) {
      for (var x = width - 1; x >= 0; x--) {
        final i = y * width + x;
        var v = dist[i];
        if (v == 0) continue;
        if (x < width - 1) v = math.min(v, dist[i + 1] + 3);
        if (y < height - 1) {
          v = math.min(v, dist[i + width] + 3);
          if (x < width - 1) v = math.min(v, dist[i + width + 1] + 4);
          if (x > 0) v = math.min(v, dist[i + width - 1] + 4);
        }
        dist[i] = v;
      }
    }
    final peaks = <(int, int, int)>[];
    const radius = 7;
    for (var y = 1; y < height - 1; y++) {
      for (var x = 1; x < width - 1; x++) {
        final v = dist[y * width + x];
        if (v < 21 || v >= big) continue; // ≥ 7 px from white
        var isPeak = true;
        for (var yy = math.max(0, y - radius);
            isPeak && yy <= math.min(height - 1, y + radius);
            yy++) {
          for (var xx = math.max(0, x - radius);
              xx <= math.min(width - 1, x + radius);
              xx++) {
            final o = dist[yy * width + xx];
            if (o > v && o < big) {
              isPeak = false;
              break;
            }
          }
        }
        if (isPeak) peaks.add((x, y, v));
      }
    }
    peaks.sort((a, b) => b.$3.compareTo(a.$3));
    final chosen = <(int, int, int)>[];
    for (final p in peaks) {
      if (chosen.any((c) =>
          (c.$1 - p.$1) * (c.$1 - p.$1) + (c.$2 - p.$2) * (c.$2 - p.$2) <
          256)) {
        continue;
      }
      chosen.add(p);
      if (chosen.length >= 120) break;
    }
    for (final (x, y, v) in chosen) {
      seeds.add(_WindowSeed.disk(x + 0.5, y + 0.5, v / 3 * 0.8));
    }
    return seeds;
  }

  /// Dominant edge direction (mod 90°) around a point, in (-45°, 45°].
  double _localOrientation(double cx, double cy, double radius) {
    final hist = Float64List(90);
    final x0 = math.max(1, (cx - radius).floor());
    final x1 = math.min(width - 2, (cx + radius).ceil());
    final y0 = math.max(1, (cy - radius).floor());
    final y1 = math.min(height - 2, (cy + radius).ceil());
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final i = y * width + x;
        final m2 = gx[i] * gx[i] + gy[i] * gy[i];
        if (m2 < 225) continue;
        var a = math.atan2(gy[i], gx[i]) * 180 / math.pi;
        a = a % 90;
        if (a < 0) a += 90;
        hist[a.floor() % 90] += m2;
      }
    }
    var best = 0;
    var bestValue = -1.0;
    for (var a = 0; a < 90; a++) {
      final v = hist[(a + 89) % 90] + hist[a] + hist[(a + 1) % 90];
      if (v > bestValue) {
        bestValue = v;
        best = a;
      }
    }
    var degrees = best + 0.5;
    if (degrees > 45) degrees -= 90;
    return degrees * math.pi / 180;
  }

  // ---- window growth -------------------------------------------------

  /// Hit fraction and outside-white fraction of a candidate window edge:
  /// segment centred at (bx, by), direction (dx, dy), half length [half],
  /// outward normal (nx, ny). With [photoInside], the outside fraction is
  /// zero when the inside is mostly white too: that is the shadow line
  /// between two touching borders, not a photo's edge.
  (double, double, double) _edgeScore(double bx, double by, double dx,
      double dy, double half, double nx, double ny,
      {int maxSamples = 1 << 20, bool photoInside = true}) {
    final samples = math.min(maxSamples, math.max(10, half.round()));
    var hits = 0;
    var whites = 0;
    var insideWhite = 0;
    for (var k = 0; k < samples; k++) {
      final t = -half + 2 * half * (k + 0.5) / samples;
      final px = bx + dx * t;
      final py = by + dy * t;
      final g = math.max(
        _grad(px, py, nx, ny),
        math.max(_grad(px - nx * 0.7, py - ny * 0.7, nx, ny),
            _grad(px + nx * 0.7, py + ny * 0.7, nx, ny)),
      );
      if (g >= 15) hits++;
      whites += pale[_index(px + nx * 2, py + ny * 2)] +
          pale[_index(px + nx * 3, py + ny * 3)] +
          pale[_index(px + nx * 4, py + ny * 4)];
      if (photoInside) {
        insideWhite += white[_index(px - nx * 2.5, py - ny * 2.5)] +
            white[_index(px - nx * 4, py - ny * 4)];
      }
    }
    final inside = insideWhite / (2 * samples);
    if (photoInside && inside > 0.85) {
      return (hits / samples, 0.0, inside);
    }
    return (hits / samples, whites / (3 * samples), inside);
  }

  List<_Line>? _growWindow(_WindowSeed seed) {
    final theta = seed.theta ??
        _localOrientation(seed.cx, seed.cy, math.max(12, seed.radius * 3));
    final ux = math.cos(theta), uy = math.sin(theta);
    final vx = -uy, vy = ux;
    // Outward base normals: top, right, bottom, left.
    final normals = [
      [-vx, -vy],
      [ux, uy],
      [vx, vy],
      [-ux, -uy],
    ];
    final ext = List<double>.generate(4, (s) {
      var best = double.negativeInfinity;
      for (final p in seed.outline) {
        best = math.max(best, p.x * normals[s][0] + p.y * normals[s][1]);
      }
      return best;
    });
    final lines = List<_Line?>.filled(4, null);
    final maxImage = math.max(width, height).toDouble();
    // Coarse; [_refineWindow] settles the exact angle.
    const angles = [
      -12.0,
      -10.0,
      -8.0,
      -6.0,
      -4.0,
      -2.0,
      0.0,
      2.0,
      4.0,
      6.0,
      8.0,
      10.0,
      12.0
    ];
    for (var iteration = 0; iteration < 3; iteration++) {
      final hu = (ext[1] + ext[3]) / 2;
      final hv = (ext[0] + ext[2]) / 2;
      final cx = ux * (ext[1] - ext[3]) / 2 + vx * (ext[2] - ext[0]) / 2;
      final cy = uy * (ext[1] - ext[3]) / 2 + vy * (ext[2] - ext[0]) / 2;
      final span = 2 * math.max(hu, hv);
      final maxSteps = math.min(maxImage, span * 1.3 + 15).round();
      for (var s = 0; s < 4; s++) {
        final n0x = normals[s][0], n0y = normals[s][1];
        final d0x = -n0y, d0y = n0x;
        final half = s.isEven ? hu : hv;
        final start = (s.isEven ? hv : hu) - 3;
        double? bestOffset;
        var bestAngle = 0.0;
        var bestHit = 0.0;
        var whiteRun = 0;
        for (var step = 0; step < maxSteps; step++) {
          final o = start + step;
          final bx = cx + n0x * o;
          final by = cy + n0y * o;
          if (bx < -2 || by < -2 || bx > width + 2 || by > height + 2) {
            break;
          }
          final wf = _whiteFraction(
              bx - d0x * half * 0.9,
              by - d0y * half * 0.9,
              bx + d0x * half * 0.9,
              by + d0y * half * 0.9,
              30);
          whiteRun = wf >= 0.75 ? whiteRun + 1 : 0;
          if (whiteRun >= 3) {
            // Inside a white border: the window edge is where it began.
            if (bestOffset == null || bestOffset < o - 4) {
              bestOffset = o - 3;
              bestAngle = 0;
            }
            break;
          }
          for (final a in angles) {
            final rad = a * math.pi / 180;
            final nx = n0x * math.cos(rad) - n0y * math.sin(rad);
            final ny = n0x * math.sin(rad) + n0y * math.cos(rad);
            final (hit, band, _) =
                _edgeScore(bx, by, -ny, nx, half, nx, ny, maxSamples: 24);
            if (hit >= 0.4 && band >= 0.6 && hit > bestHit) {
              bestHit = hit;
              bestOffset = o;
              bestAngle = rad;
            }
          }
          if (bestOffset != null && o > bestOffset + 2) {
            break;
          }
        }
        if (bestOffset != null) {
          final nx = n0x * math.cos(bestAngle) - n0y * math.sin(bestAngle);
          final ny = n0x * math.sin(bestAngle) + n0y * math.cos(bestAngle);
          lines[s] = _Line.through(
              nx, ny, cx + n0x * bestOffset, cy + n0y * bestOffset);
        }
      }
      if (lines.any((l) => l == null)) {
        continue;
      }
      final quad = _quadFromLines(lines.cast<_Line>());
      if (quad == null) {
        return null;
      }
      for (var s = 0; s < 4; s++) {
        var best = double.negativeInfinity;
        for (final p in quad) {
          best = math.max(best, p.x * normals[s][0] + p.y * normals[s][1]);
        }
        ext[s] = best;
      }
    }
    if (lines.any((l) => l == null)) {
      return null;
    }
    return lines.cast<_Line>();
  }

  /// Snaps each side of a grown window onto the strongest nearby
  /// dark-to-white edge, measured over the side's own length.
  List<math.Point<double>>? _refineWindow(List<math.Point<double>> q) {
    var quad = q;
    for (var pass = 0; pass < 2; pass++) {
      final lines = <_Line>[];
      for (var s = 0; s < 4; s++) {
        final a = quad[s];
        final b = quad[(s + 1) % 4];
        final len = a.distanceTo(b);
        if (len < 4) return null;
        final n0x = (b.y - a.y) / len, n0y = -(b.x - a.x) / len;
        final mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
        var best = -1.0;
        var bestD = 0.0;
        var bestRad = 0.0;
        for (var d = -4.0; d <= 4.0; d += 0.5) {
          for (var deg = -3.0; deg <= 3.0; deg += 0.5) {
            final rad = deg * math.pi / 180;
            final nx = n0x * math.cos(rad) - n0y * math.sin(rad);
            final ny = n0x * math.sin(rad) + n0y * math.cos(rad);
            final (hit, band, _) = _edgeScore(
                mx + n0x * d, my + n0y * d, -ny, nx, len * 0.45, nx, ny);
            if (band < 0.55) continue;
            // Prefer the smallest move among equal hits.
            final score = hit - (d.abs() + deg.abs()) * 0.002;
            if (score > best) {
              best = score;
              bestD = d;
              bestRad = rad;
            }
          }
        }
        final nx = n0x * math.cos(bestRad) - n0y * math.sin(bestRad);
        final ny = n0x * math.sin(bestRad) + n0y * math.cos(bestRad);
        lines.add(_Line.through(nx, ny, mx + n0x * bestD, my + n0y * bestD));
      }
      final next = _quadFromLines(lines);
      if (next == null) return null;
      quad = next;
    }
    return quad;
  }

  /// A window whose growth stopped at white content inside the photo (a
  /// white shirt across it) still has its two neighbouring sides running
  /// on past that end. Pushes such an end out to the next real window edge.
  (double, List<math.Point<double>>) _extendTruncated(
      double score, List<math.Point<double>> q) {
    var best = (score, q);
    for (var end = 0; end < 4; end++) {
      final quad = best.$2;
      final ws = math.min(
          (quad[0].distanceTo(quad[1]) + quad[2].distanceTo(quad[3])) / 2,
          (quad[1].distanceTo(quad[2]) + quad[3].distanceTo(quad[0])) / 2);
      // The end side runs quad[end] → quad[end+1]. Its neighbours leave it
      // at those corners: side end-1 arrives at quad[end] and side end+1
      // starts at quad[end+1].
      final a = quad[end];
      final b = quad[(end + 1) % 4];
      final endLen = a.distanceTo(b);
      final ex = (b.y - a.y) / endLen, ey = -(b.x - a.x) / endLen;
      final rails = <(double, double, double, double, double, double)>[];
      for (final (from, corner) in [
        (quad[(end + 3) % 4], a),
        (quad[(end + 2) % 4], b),
      ]) {
        final len = from.distanceTo(corner);
        final dx = (corner.x - from.x) / len, dy = (corner.y - from.y) / len;
        // Outward normal of that side: away from the window's centre.
        final cx = (quad[0].x + quad[2].x) / 2,
            cy = (quad[0].y + quad[2].y) / 2;
        var nx = dy, ny = -dx;
        if ((corner.x - cx) * nx + (corner.y - cy) * ny < 0) {
          nx = -nx;
          ny = -ny;
        }
        rails.add((corner.x, corner.y, dx, dy, nx, ny));
      }

      /// Edge hit fractions of both rails between two distances.
      List<double> railHits(double from, double to, {bool needBand = false}) {
        final mid = (from + to) / 2;
        return [
          for (final (x, y, dx, dy, nx, ny) in rails)
            () {
              final (hit, band, _) = _edgeScore(
                  x + dx * mid, y + dy * mid, dx, dy, (to - from) / 2, nx, ny,
                  photoInside: false);
              return needBand && band < 0.55 ? 0.0 : hit;
            }(),
        ];
      }

      // Right past the corner the sides still run on (one of them may be
      // touched by the white content).
      final start = railHits(3, 3 + ws * 0.25, needBand: true);
      if (start.reduce(math.max) < 0.7 || start.reduce(math.min) < 0.3) {
        continue;
      }
      final mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
      for (var d = 6.0; d <= ws * 1.5; d += 1) {
        double? found;
        var foundRad = 0.0;
        var foundHit = 0.0;
        for (var deg = -4.0; deg <= 4.0; deg += 1) {
          final rad = deg * math.pi / 180;
          final nx = ex * math.cos(rad) - ey * math.sin(rad);
          final ny = ex * math.sin(rad) + ey * math.cos(rad);
          final (hit, band, _) = _edgeScore(
              mx + ex * d, my + ey * d, -ny, nx, endLen * 0.45, nx, ny);
          if (hit >= 0.4 && band >= 0.6 && hit > foundHit) {
            found = d;
            foundRad = rad;
            foundHit = hit;
          }
        }
        if (found == null) continue;
        // Up to the new end one side may be touched by the white content
        // for a stretch, the other must stay clear.
        final hits = railHits(3, math.max(4, d - 3));
        if (hits.reduce(math.max) < 0.8 || hits.reduce(math.min) < 0.25) {
          break;
        }
        final lines = _sides(quad);
        final nx = ex * math.cos(foundRad) - ey * math.sin(foundRad);
        final ny = ex * math.sin(foundRad) + ey * math.cos(foundRad);
        lines[end] = _Line.through(nx, ny, mx + ex * d, my + ey * d);
        final grown = _quadFromLines(lines);
        final refined = grown == null ? null : _refineWindow(grown);
        final newScore = refined == null
            ? null
            : _windowScore(refined, rows: end.isOdd, columns: end.isEven);
        if (refined != null && newScore != null) {
          best = (newScore, refined);
        }
        break;
      }
    }
    return best;
  }

  // ---- window validation ---------------------------------------------

  /// Mean edge support of a window, or null if it is not a photo window:
  /// wrong shape, a side without a white border, or a white band running
  /// straight across it (two neighbouring windows taken as one).
  /// [rows] / [columns]: whether to reject a white band running across
  /// the window side to side (rows) or top to bottom (columns). A window
  /// rebuilt across white content skips the band it was rebuilt across.
  double? _windowScore(List<math.Point<double>> q,
      {bool rows = true, bool columns = true}) {
    final top = q[0].distanceTo(q[1]);
    final right = q[1].distanceTo(q[2]);
    final bottom = q[2].distanceTo(q[3]);
    final left = q[3].distanceTo(q[0]);
    final w = (top + bottom) / 2;
    final h = (left + right) / 2;
    final shortSide = math.min(w, h);
    final ratio = shortSide / math.max(w, h);
    if (shortSide < math.max(width, height) * 0.025 || ratio < 0.3) {
      return null;
    }
    if (math.max(w, h) > math.max(width, height) * 0.95) {
      return null;
    }
    var total = 0.0;
    for (var s = 0; s < 4; s++) {
      final a = q[s];
      final b = q[(s + 1) % 4];
      final len = a.distanceTo(b);
      final dx = (b.x - a.x) / len;
      final dy = (b.y - a.y) / len;
      final nx = dy, ny = -dx;
      final (hit, band, inside) = _edgeScore(
          (a.x + b.x) / 2, (a.y + b.y) / 2, dx, dy, len * 0.45, nx, ny);
      if (hit < 0.3 || band < 0.55) {
        return null;
      }
      // White on both sides of an edge is more likely a seam between two
      // borders than the photo's edge.
      total += hit - math.max(0, inside - 0.4);
    }
    for (var k = 0; (rows || columns) && k < 15; k++) {
      final f = 0.12 + 0.76 * k / 14;
      final ax = q[0].x + (q[3].x - q[0].x) * f,
          ay = q[0].y + (q[3].y - q[0].y) * f;
      final bx = q[1].x + (q[2].x - q[1].x) * f,
          by = q[1].y + (q[2].y - q[1].y) * f;
      if (rows && _whiteFraction(ax, ay, bx, by, 48) >= 0.85) return null;
      final cx = q[0].x + (q[1].x - q[0].x) * f,
          cy = q[0].y + (q[1].y - q[0].y) * f;
      final dx = q[3].x + (q[2].x - q[3].x) * f,
          dy = q[3].y + (q[2].y - q[3].y) * f;
      if (columns && _whiteFraction(cx, cy, dx, dy, 48) >= 0.85) return null;
    }
    return total / 4;
  }

  // ---- outer frame ---------------------------------------------------

  static const List<double> _evidenceLevels = [
    2,
    3,
    4,
    5,
    6,
    8,
    10,
    12,
    15,
    20,
    30
  ];

  /// Quantised median of the aligned edge strength along a line: the
  /// largest level that at least half the samples reach. Only gradients
  /// pointing across the line count, so handwriting crossing it does not.
  double _lineEvidence(double bx, double by, double dx, double dy, double half,
      double nx, double ny) {
    final samples = math.max(12, half.round());
    final counts = Int32List(_evidenceLevels.length);
    for (var k = 0; k < samples; k++) {
      final t = -half + 2 * half * (k + 0.5) / samples;
      final px = bx + dx * t;
      final py = by + dy * t;
      var best = 0.0;
      for (final j in const [-0.7, 0.0, 0.7]) {
        final i = _index(px + nx * j, py + ny * j);
        // Brightness must drop going outward: white border to whatever
        // lies beyond (background, a seam's shadow, a sleeve edge).
        final along = -(gx[i] * nx + gy[i] * ny);
        final across = (gx[i] * -ny + gy[i] * nx).abs();
        if (along > 0 && along >= 2 * across && along > best) {
          best = along;
        }
      }
      for (var l = 0; l < _evidenceLevels.length; l++) {
        if (best >= _evidenceLevels[l]) counts[l]++;
      }
    }
    // Plus the share of samples reaching that level, so a line lying
    // along the edge beats a slightly tilted one crossing it.
    var level = 0.0;
    for (var l = 0; l < _evidenceLevels.length; l++) {
      if (counts[l] * 2 >= samples) {
        level = _evidenceLevels[l] + 0.99 * counts[l] / samples;
      }
    }
    return level;
  }

  /// Border widths in window short sides, per film: side, top, bottom.
  /// instax mini: 4 / 7 / 17 mm around a 46 mm wide image; WIDE and
  /// SQUARE: about 4.5 / 7 / 17 mm around a 62 mm short side.
  static const _thinRange = (0.035, 0.15);
  static const _topRange = (0.05, 0.21);
  static const _bottomRange = (0.17, 0.47);
  static const _miniBottomRange = (0.25, 0.5);
  static const _defaultTop = 0.12;
  static const _defaultBottom = 0.31;
  static const _miniTop = 0.15;
  static const _miniBottom = 0.37;
  static const double seenEvidence = 3;
  static const double strongEvidence = 9;

  /// [others]: the other windows found; a step down into one of them is
  /// that card's photo edge, not this card's outer edge.
  _WindowCard? _outerFrame(
    List<math.Point<double>> q,
    double windowScore,
    List<List<math.Point<double>>> others,
  ) {
    final w = (q[0].distanceTo(q[1]) + q[2].distanceTo(q[3])) / 2;
    final h = (q[1].distanceTo(q[2]) + q[3].distanceTo(q[0])) / 2;
    final ws = math.min(w, h);
    // instax mini windows are 46×62 mm (0.74); WIDE 62×99 (0.63).
    final miniWindow = ws / math.max(w, h) >= 0.68;
    // Per side: best (evidence, offset, angle) in each range.
    final best = List.generate(4, (_) => List.filled(3, (0.0, 0.0, 0.0)));
    final blockedByOther = List<bool>.filled(4, false);
    final windowLines = <_Line>[];
    for (var s = 0; s < 4; s++) {
      final a = q[s];
      final b = q[(s + 1) % 4];
      final len = a.distanceTo(b);
      final dx = (b.x - a.x) / len, dy = (b.y - a.y) / len;
      final n0x = dy, n0y = -dx;
      final mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
      windowLines.add(_Line.through(n0x, n0y, mx, my));
      final dMin = math.max(1.5, ws * 0.035);
      final dMax = ws * 0.47;
      // White fraction of lines parallel to the side, for the ring test.
      final steps = ((dMax + 1) * 2).ceil();
      final whiteAt = Float64List(steps + 1);
      for (var k = 0; k <= steps; k++) {
        final d = k / 2;
        whiteAt[k] = _paleFraction(
            mx + n0x * d - dx * len * 0.45,
            my + n0y * d - dy * len * 0.45,
            mx + n0x * d + dx * len * 0.45,
            my + n0y * d + dy * len * 0.45,
            24);
      }
      final prefix = Float64List(steps + 2);
      for (var k = 0; k <= steps; k++) {
        prefix[k + 1] = prefix[k] + whiteAt[k];
      }
      for (var d = dMin; d <= dMax; d += 0.5) {
        final px = mx + n0x * (d + 6), py = my + n0y * (d + 6);
        if (others.any((o) => _inside(o, px, py))) {
          blockedByOther[s] = true;
          break;
        }
        // Ring: from 2 px outside the window edge up to 1 px before the
        // candidate, mostly white (writing allowed).
        final k0 = 4;
        final k1 = math.max(k0 + 1, ((d - 1) * 2).floor());
        if (k1 <= steps && k1 > k0) {
          final ring = (prefix[k1] - prefix[k0]) / (k1 - k0);
          if (ring < 0.6) continue;
        }
        final ratio = d / ws;
        for (final deg in const [
          -4.0,
          -3.0,
          -2.0,
          -1.0,
          0.0,
          1.0,
          2.0,
          3.0,
          4.0
        ]) {
          final rad = deg * math.pi / 180;
          final nx = n0x * math.cos(rad) - n0y * math.sin(rad);
          final ny = n0x * math.sin(rad) + n0y * math.cos(rad);
          final e = _lineEvidence(
              mx + n0x * d, my + n0y * d, -ny, nx, len * 0.45, nx, ny);
          final ranges = [
            _thinRange,
            _topRange,
            miniWindow ? _miniBottomRange : _bottomRange,
          ];
          for (var r = 0; r < 3; r++) {
            if (ratio < ranges[r].$1 || ratio > ranges[r].$2) continue;
            if (e > best[s][r].$1) best[s][r] = (e, d, rad);
          }
        }
      }
    }

    // Which side is the thick bottom border.
    var bestK = -1;
    var bestScore = double.negativeInfinity;
    for (var k = 0; k < 4; k++) {
      double capped(double e) => math.min(e, 15);
      var score = capped(best[k][2].$1) +
          capped(best[(k + 2) % 4][1].$1) +
          capped(best[(k + 1) % 4][0].$1) +
          capped(best[(k + 3) % 4][0].$1);
      // Cards usually lie upright: small preference for the side facing
      // the bottom of the photo.
      final l = windowLines[k];
      if (l.ny > 0.7) score += 8;
      if (score > bestScore) {
        bestScore = score;
        bestK = k;
      }
    }
    final role = List<int>.filled(4, 0); // 0 thin, 1 top, 2 bottom
    role[bestK] = 2;
    role[(bestK + 2) % 4] = 1;
    final chosen = [for (var s = 0; s < 4; s++) best[s][role[s]]];
    final seen = [for (final c in chosen) c.$1 >= seenEvidence];
    final seenCount = seen.where((v) => v).length;
    // A card in a tight row has its two outer sides hidden behind the
    // neighbouring windows while top and bottom stay visible. Rejecting it for
    // "too few sides seen" silently dropped whole cards from a row (7 of 21 on
    // the owner's real desk photos). Being flanked is itself evidence, so
    // accept an *opposite* pair of blocked sides with strong evidence on the
    // visible pair. A 2×2 block hides two *adjacent* sides per card, which
    // stays ambiguous and is still rejected (see "2×2 block of touching cards
    // warns and does not guess a cut").
    final unseen = [
      for (var s = 0; s < 4; s++)
        if (!seen[s]) s
    ];
    final flanked = seenCount == 2 &&
        unseen.length == 2 &&
        (unseen[0] + 2) % 4 == unseen[1] &&
        blockedByOther[unseen[0]] &&
        blockedByOther[unseen[1]] &&
        [
          for (var s = 0; s < 4; s++)
            if (seen[s]) chosen[s].$1
        ].every((evidence) => evidence >= strongEvidence);
    if ((flanked ? false : seenCount < 3) ||
        !chosen.any((c) => c.$1 >= strongEvidence)) {
      return null;
    }
    final outerLines = <_Line>[];
    for (var s = 0; s < 4; s++) {
      var (_, d, rad) = chosen[s];
      if (!seen[s]) {
        rad = 0;
        d = switch (role[s]) {
          0 => seen[(s + 2) % 4] && role[(s + 2) % 4] == 0
              ? chosen[(s + 2) % 4].$2
              : ws * 0.085,
          1 => ws * (miniWindow ? _miniTop : _defaultTop),
          _ => ws * (miniWindow ? _miniBottom : _defaultBottom),
        };
      }
      final wl = windowLines[s];
      final a = q[s];
      final b = q[(s + 1) % 4];
      final mx = (a.x + b.x) / 2 + wl.nx * d;
      final my = (a.y + b.y) / 2 + wl.ny * d;
      final nx = wl.nx * math.cos(rad) - wl.ny * math.sin(rad);
      final ny = wl.nx * math.sin(rad) + wl.ny * math.cos(rad);
      outerLines.add(_Line.through(nx, ny, mx, my));
    }
    final outer = _quadFromLines(outerLines);
    if (outer == null) {
      return null;
    }
    // Rotate so the thick border is at the bottom (index 2 → side 2).
    final shift = (bestK - 2) % 4;
    final rotated = [for (var i = 0; i < 4; i++) outer[(i + shift) % 4]];
    final rotatedWindow = [for (var i = 0; i < 4; i++) q[(i + shift) % 4]];
    final evidence =
        chosen.map((c) => math.min(c.$1, 15) / 15).reduce((a, b) => a + b) / 4;
    final card = _WindowCard(
      outer: rotated,
      window: rotatedWindow,
      seenSides: seenCount,
      confidence: _clamp01(0.45 + 0.3 * windowScore + 0.25 * evidence),
    );
    return card;
  }

  static double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

  // ---- driver --------------------------------------------------------

  List<_WindowCard> detect() {
    final seeds = _seeds();
    final windows = <(double, List<math.Point<double>>)>[];
    // A seed may grow a different (better) window than an earlier seed in
    // the same card; stop trying once two windows cover it.
    bool covered(double x, double y) =>
        windows.where((w) => _inside(w.$2, x, y)).length >= 2;
    for (var seedIndex = 0; seedIndex < seeds.length; seedIndex++) {
      final seed = seeds[seedIndex];
      if (covered(seed.cx, seed.cy)) {
        continue;
      }
      final lines = _growWindow(seed);
      if (lines == null) {
        continue;
      }
      final grown = _quadFromLines(lines);
      final quad = grown == null ? null : _refineWindow(grown);
      if (quad == null) {
        continue;
      }
      final score = _windowScore(quad);
      if (score == null) {
        continue;
      }
      windows.add((score, quad));
    }
    // Cards in one photo are mostly the same film: a window rebuilt to far
    // more than the usual size has swallowed a neighbour.
    final areas = [
      for (final w in windows)
        if (_ratio(w.$2) >= 0.55) RecordScanService._polygonArea(w.$2).abs(),
    ]..sort();
    final maxRebuilt =
        areas.length >= 3 ? areas[areas.length ~/ 2] * 1.8 : double.infinity;
    bool plausible(List<math.Point<double>> q) =>
        RecordScanService._polygonArea(q).abs() <= maxRebuilt;
    for (var i = 0; i < windows.length; i++) {
      final extended = _extendTruncated(windows[i].$1, windows[i].$2);
      if (!identical(extended.$2, windows[i].$2) && plausible(extended.$2)) {
        windows[i] = extended;
      }
    }
    // A window cut in two by white clothing grows into two halves; their
    // union is the real window.
    final pieces = List.of(windows);
    for (var i = 0; i < pieces.length; i++) {
      for (var j = i + 1; j < pieces.length; j++) {
        if (_ratio(pieces[i].$2) >= 0.55 && _ratio(pieces[j].$2) >= 0.55) {
          continue;
        }
        final union = _unionWindow(pieces[i].$2, pieces[j].$2);
        if (union == null || !plausible(union.$1)) continue;
        // The white band between the pieces is expected here.
        final score =
            _windowScore(union.$1, rows: union.$2 == 1, columns: union.$2 == 0);
        if (score != null) windows.add((score, union.$1));
      }
    }
    windows.removeWhere((w) => _ratio(w.$2) < 0.55);
    windows.sort((a, b) => b.$1.compareTo(a.$1));
    final kept = <(double, List<math.Point<double>>)>[];
    for (final w in windows) {
      final area = RecordScanService._polygonArea(w.$2).abs();
      final clashes = <int>[];
      var swallows = true;
      for (var i = 0; i < kept.length; i++) {
        final k = kept[i];
        final kArea = RecordScanService._polygonArea(k.$2).abs();
        final inter = RecordScanService._polygonIntersectionArea(w.$2, k.$2);
        final small = math.min(area, kArea);
        if (small <= 0 || inter / small <= 0.3) continue;
        clashes.add(i);
        // A small rectangle inside a photo (a sign, a phone screen) loses
        // to the whole window around it.
        if (!(inter / kArea > 0.85 && area > 1.4 * kArea && w.$1 >= 0.6)) {
          swallows = false;
        }
      }
      if (clashes.isEmpty) {
        kept.add(w);
      } else if (swallows) {
        for (final i in clashes.reversed) {
          kept.removeAt(i);
        }
        kept.add(w);
      }
    }
    return [
      for (final (score, quad) in kept)
        _outerFrame(quad, score, [
          for (final k in kept)
            if (!identical(k.$2, quad)) k.$2,
        ]),
    ].whereType<_WindowCard>().toList();
  }

  static double _ratio(List<math.Point<double>> q) {
    final w = (q[0].distanceTo(q[1]) + q[2].distanceTo(q[3])) / 2;
    final h = (q[1].distanceTo(q[2]) + q[3].distanceTo(q[0])) / 2;
    return math.min(w, h) / math.max(w, h);
  }

  /// Two windows stacked along one axis whose outer corners line up: the
  /// quad spanning both and the axis (0 stacked vertically, 1 side by
  /// side), or null.
  static (List<math.Point<double>>, int)? _unionWindow(
    List<math.Point<double>> a,
    List<math.Point<double>> b,
  ) {
    for (var axis = 0; axis < 2; axis++) {
      // axis 0: stacked top to bottom; axis 1: left to right.
      final stack = _sides(a)[axis == 0 ? 2 : 1];
      double along(List<math.Point<double>> q) =>
          q.fold(0.0, (v, p) => v + stack.nx * p.x + stack.ny * p.y);
      final first = along(a) <= along(b) ? a : b;
      final second = identical(first, a) ? b : a;
      final union = axis == 0
          ? [first[0], first[1], second[2], second[3]]
          : [first[0], second[1], second[2], first[3]];
      // The inner corners must sit on the union's sides.
      final inner = axis == 0
          ? [(3, first[3], second[0]), (1, first[2], second[1])]
          : [(0, first[1], second[0]), (2, first[2], second[3])];
      final across = axis == 0
          ? math.min(
              first[0].distanceTo(first[1]), second[3].distanceTo(second[2]))
          : math.min(
              first[0].distanceTo(first[3]), second[1].distanceTo(second[2]));
      final tolerance = math.max(3.0, across * 0.1);
      final sides = _sides(union);
      var aligned = true;
      for (final (s, p, r) in inner) {
        final l = sides[s];
        if ((l.nx * p.x + l.ny * p.y - l.rho).abs() > tolerance ||
            (l.nx * r.x + l.ny * r.y - l.rho).abs() > tolerance) {
          aligned = false;
        }
      }
      if (!aligned ||
          RecordScanService._polygonArea(union) <= 0 ||
          !_inside(union, (union[0].x + union[2].x) / 2,
              (union[0].y + union[2].y) / 2)) {
        continue;
      }
      final area = RecordScanService._polygonArea(union).abs();
      final sum = RecordScanService._polygonArea(a).abs() +
          RecordScanService._polygonArea(b).abs();
      // Must be the two pieces plus a strip, not two distant windows.
      if (area > sum * 1.6 || area < sum * 0.9) continue;
      return (union, axis);
    }
    return null;
  }

  /// Outward-normal side lines of a clockwise quad (top, right, bottom,
  /// left for an upright one).
  static List<_Line> _sides(List<math.Point<double>> q) => [
        for (var s = 0; s < 4; s++)
          () {
            final a = q[s];
            final b = q[(s + 1) % 4];
            final len = a.distanceTo(b);
            final nx = (b.y - a.y) / len;
            final ny = -(b.x - a.x) / len;
            return _Line.through(nx, ny, a.x, a.y);
          }(),
      ];

  static bool _inside(List<math.Point<double>> q, double x, double y) {
    for (var i = 0; i < 4; i++) {
      final a = q[i];
      final b = q[(i + 1) % 4];
      if ((b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x) < 0) {
        return false;
      }
    }
    return true;
  }
}

class _WindowSeed {
  final double cx;
  final double cy;
  final double radius;
  final int area;

  /// Points on the seed's outline (pixel-edge coordinates).
  final List<math.Point<double>> outline;

  /// Orientation from the seed's own shape, if it has one.
  final double? theta;

  const _WindowSeed({
    required this.cx,
    required this.cy,
    required this.radius,
    required this.area,
    required this.outline,
    required this.theta,
  });

  factory _WindowSeed.fromPixels(Int32List pixels, int count, int width) {
    var minY = 1 << 30;
    var maxY = -1;
    for (var i = 0; i < count; i++) {
      final y = pixels[i] ~/ width;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    final rows = maxY - minY + 1;
    final rowMin = Int32List(rows)..fillRange(0, rows, 1 << 30);
    final rowMax = Int32List(rows)..fillRange(0, rows, -1);
    var sx = 0.0;
    var sy = 0.0;
    for (var i = 0; i < count; i++) {
      final x = pixels[i] % width;
      final r = pixels[i] ~/ width - minY;
      if (x < rowMin[r]) rowMin[r] = x;
      if (x > rowMax[r]) rowMax[r] = x;
      sx += x + 0.5;
      sy += pixels[i] ~/ width + 0.5;
    }
    final points = <math.Point<double>>[];
    for (var r = 0; r < rows; r++) {
      if (rowMax[r] < 0) continue;
      final y = (minY + r).toDouble();
      points
        ..add(math.Point(rowMin[r].toDouble(), y))
        ..add(math.Point(rowMax[r] + 1.0, y))
        ..add(math.Point(rowMin[r].toDouble(), y + 1))
        ..add(math.Point(rowMax[r] + 1.0, y + 1));
    }
    final hull = RecordScanService._convexHull(points);
    final box = hull.length >= 3 ? RecordScanService._minAreaBox(hull) : null;
    return _WindowSeed(
      cx: sx / count,
      cy: sy / count,
      radius: math.sqrt(count / math.pi),
      area: count,
      outline: hull,
      theta: box == null ? null : math.atan2(box.uy, box.ux),
    );
  }

  factory _WindowSeed.disk(double cx, double cy, double radius) {
    return _WindowSeed(
      cx: cx,
      cy: cy,
      radius: radius,
      area: (math.pi * radius * radius).round(),
      outline: [
        for (var k = 0; k < 16; k++)
          math.Point(cx + radius * math.cos(k * math.pi / 8),
              cy + radius * math.sin(k * math.pi / 8)),
      ],
      theta: null,
    );
  }
}
