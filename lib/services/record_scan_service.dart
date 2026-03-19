import 'dart:io';
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

class RecordScanService {
  static const int _maxInputDimension = 1800;
  static const int _previewMaxSide = 320;
  static const double _polaroidAspectRatio = 0.8;
  static const int _targetLongSide = 1360;
  static const int _fusionFrameLimit = 4;

  static Future<RecordScanOutput> createBasicScan({
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

  static Future<RecordScanManualDraft> prepareManualDraft({
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

  static Future<RecordScanOutput> createManualScan({
    required Uint8List sourceBytes,
    required RecordScanQuad quad,
  }) async {
    final working = _decodeAndNormalize(sourceBytes);
    final clampedQuad = quad.clampToBounds(
      imageWidth: working.width,
      imageHeight: working.height,
    );
    final targetWidth = math.max(
      1,
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
    final targetHeight = math.max(
      1,
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

  static Future<RecordScanOutput> createFusionScan({
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
        bytes: img.encodeJpg(candidates.first.image, quality: 94),
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
        : img.Image.from(base.image);

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
    return _applyLegacyFusionPolish(normalized);
  }

  static Future<_PreparedScanSource> _prepareWorkingSource(
      File sourceFile) async {
    var working = _decodeAndNormalize(await sourceFile.readAsBytes());
    var detection = _detectPolaroid(working);

    if (detection != null &&
        detection.confidence >= 0.32 &&
        detection.rotationDegrees.abs() >= 1.5 &&
        detection.rotationDegrees.abs() <= 28) {
      working = img.copyRotate(
        working,
        angle: detection.rotationDegrees,
        interpolation: img.Interpolation.linear,
      );
      detection =
          _detectPolaroid(working) ?? detection.copyWith(rotationDegrees: 0);
    }

    final cropRect = detection != null
        ? _expandedPolaroidRect(
            rect: detection.rect,
            imageWidth: working.width,
            imageHeight: working.height,
          )
        : _fallbackCropRect(working);

    return _PreparedScanSource(
      image: working,
      cropRect: cropRect,
      detectionScore: detection?.confidence ?? 0,
      usedFallback: detection == null,
    );
  }

  static img.Image _decodeAndNormalize(List<int> bytes) {
    final decoded = img.decodeImage(Uint8List.fromList(bytes));
    if (decoded == null) {
      throw const FormatException('图片无法识别');
    }

    var normalized = img.bakeOrientation(decoded);
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

  static _DetectedPolaroid? _detectPolaroid(img.Image image) {
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
        if (luminance >= 150 && chroma <= 78) {
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

  static img.Image _buildPreview(img.Image image) {
    final longestSide = math.max(image.width, image.height);
    if (longestSide <= _previewMaxSide) {
      return img.Image.from(image);
    }
    final scale = _previewMaxSide / longestSide;
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
  }) {
    var left = rect.left;
    var right = rect.right;
    var top = rect.top;
    var bottom = rect.bottom;

    var width = (right - left) + 1;
    var height = (bottom - top) + 1;
    final targetRatio =
        height >= width ? _polaroidAspectRatio : (1 / _polaroidAspectRatio);
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

  static img.Image _resizeToTargetFrame(img.Image image) {
    final portrait = image.height >= image.width;
    final targetHeight = portrait
        ? _targetLongSide
        : (_targetLongSide * _polaroidAspectRatio).round();
    final targetWidth = portrait
        ? (_targetLongSide * _polaroidAspectRatio).round()
        : _targetLongSide;
    return img.copyResize(
      image,
      width: targetWidth,
      height: targetHeight,
      interpolation: img.Interpolation.linear,
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
    _applyGrayWorldWhiteBalance(working);
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
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        image.setPixelRgba(
          x,
          y,
          _curveChannel(pixel.r.toInt()),
          _curveChannel(pixel.g.toInt()),
          _curveChannel(pixel.b.toInt()),
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

            final basePixel = baseThumb.getPixel(x, y);
            final otherPixel = otherThumb.getPixel(otherX, otherY);
            diff += (_luminance(
                      basePixel.r.toInt(),
                      basePixel.g.toInt(),
                      basePixel.b.toInt(),
                    ) -
                    _luminance(
                      otherPixel.r.toInt(),
                      otherPixel.g.toInt(),
                      otherPixel.b.toInt(),
                    ))
                .abs();
            compared += 1;
          }
        }

        if (compared == 0) {
          continue;
        }

        final averageDiff = diff / compared;
        if (averageDiff < bestDiff) {
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

  const _PreparedScanSource({
    required this.image,
    required this.cropRect,
    required this.detectionScore,
    required this.usedFallback,
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
