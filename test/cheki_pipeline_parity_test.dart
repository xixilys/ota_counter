// Parity of the app's batch cut (format, edges, orientation) with the
// desktop cheki pipeline (~/.ota-counter/cheki_pipeline.py) on real photos.
//
// The photos are private and never enter the repository. Layout of
// OTA_CHEKI_PARITY_DIR (default /tmp/xixi-ph):
//
//   orig/*.jpg            the source photos
//   run3/result.json      the pipeline's result on orig/
//   inbox-ref/result.json optional: the pipeline's result on more chat
//                         photos (~/.ota-counter/inbox/*/qq_*.jpg); the
//                         photos are read from the paths it records
//   app-faces.json        YuNet rows for the app's face windows
//
// `flutter test` runs on the host, where onnxruntime is unavailable, so the
// face detector's output is read from app-faces.json. Produce it with the
// same model file the app ships (assets/models/yunet.onnx):
//
//   OTA_CHEKI_FACE_DUMP=/tmp/xixi-ph/app-windows \
//     flutter test test/cheki_pipeline_parity_test.dart
//   python3 tool/cheki_face_reference.py /tmp/xixi-ph/app-windows \
//     /tmp/xixi-ph/app-faces.json
//
// Without the directory every test here is skipped.
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:ota_counter/services/album_orientation_service.dart';
import 'package:ota_counter/services/card_edge_fit.dart';
import 'package:ota_counter/services/card_orientation.dart';
import 'package:ota_counter/services/face/face_models.dart';
import 'package:ota_counter/services/record_scan_service.dart';

final _dir = Platform.environment['OTA_CHEKI_PARITY_DIR'] ?? '/tmp/xixi-ph';
final _dump = Platform.environment['OTA_CHEKI_FACE_DUMP'];

// ignore: avoid_print
void _log(String line) => print('CHEKI_PARITY $line');

typedef _Pt = math.Point<double>;

class _AppCard {
  _AppCard(this.source, this.index, this.card, this.image);
  final String source;
  final int index;
  final RecordScanMultiCard card;
  final img.Image image;
  CardOrientation? orientation;

  String get key => '${source}__$index';
  List<_Pt> get quad => [
        math.Point(card.quad.topLeftX, card.quad.topLeftY),
        math.Point(card.quad.topRightX, card.quad.topRightY),
        math.Point(card.quad.bottomRightX, card.quad.bottomRightY),
        math.Point(card.quad.bottomLeftX, card.quad.bottomLeftY),
      ];

  /// Output size after the orientation is applied.
  (int, int) get oriented => (orientation?.turns ?? 0).isOdd
      ? (image.height, image.width)
      : (image.width, image.height);
}

Map<String, Map<int, List<FaceDetection>>>? _faces;

Map<String, Map<int, List<FaceDetection>>>? _loadFaces() {
  final file = File('$_dir/app-faces.json');
  if (!file.existsSync()) return null;
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final card in json.entries)
      card.key: {
        for (final turn in (card.value as Map<String, dynamic>).entries)
          int.parse(turn.key): [
            for (final row in turn.value as List)
              FaceDetection.fromOpenCvRow(
                  [for (final v in row as List) (v as num).toDouble()]),
          ],
      },
  };
}

Future<List<_AppCard>> _scan(List<String> paths) async {
  final out = <_AppCard>[];
  for (final path in paths) {
    final name = path.split('/').last;
    final scan =
        await RecordScanService.createMultiScan(sourceFile: File(path));
    for (var i = 0; i < scan.cards.length; i++) {
      final card = scan.cards[i];
      final app = _AppCard(name, i, card, img.decodeImage(card.bytes)!);
      if (card.layoutTurns != null) {
        final windows = AlbumOrientationService.faceInputs(app.image);
        if (_dump != null) {
          Directory(_dump!).createSync(recursive: true);
          for (final e in windows.entries) {
            File('$_dump/${app.key}__${e.key}.png')
                .writeAsBytesSync(img.encodePng(e.value));
          }
        }
        final faces = _faces?[app.key];
        if (faces != null) {
          _log('${app.key} faces ${{
            for (final e in faces.entries)
              e.key: AlbumOrientationService.uprightScore(e.value)
                  .toStringAsFixed(2)
          }}');
        }
        app.orientation = CardOrientationDecider.decide(
          width: app.image.width,
          height: app.image.height,
          layoutTurns: card.layoutTurns,
          faceTurns: faces == null
              ? null
              : AlbumOrientationService.faceTurnsFromDetections(faces,
                  layoutTurns: card.layoutTurns),
        );
      }
      _log('$name#$i ${card.sizeClass.name} '
          '${app.image.width}x${app.image.height} layout=${card.layoutTurns} '
          '${app.orientation} quad=${[
        for (final p in app.quad) '(${p.x.round()},${p.y.round()})'
      ].join()}');
      out.add(app);
    }
  }
  return out;
}

List<_Pt> _quad(List<dynamic> json) => [
      for (final p in json)
        math.Point((p[0] as num).toDouble(), (p[1] as num).toDouble()),
    ];

double _cornerDistance(List<_Pt> a, List<_Pt> b) =>
    [for (var i = 0; i < 4; i++) a[i].distanceTo(b[i])].reduce(math.max);

/// The app card cut from the same place as a pipeline card, if any.
_AppCard? _match(List<_AppCard> cards, Map<String, dynamic> photo) {
  final source = (photo['source'] as String).split('/').last;
  final quad = _quad(photo['quad'] as List);
  final side =
      math.min(quad[0].distanceTo(quad[1]), quad[1].distanceTo(quad[2]));
  _AppCard? best;
  for (final card in cards.where((c) => c.source == source)) {
    final d = _cornerDistance(card.quad, quad);
    if (d < 0.15 * side &&
        (best == null || d < _cornerDistance(best.quad, quad))) {
      best = card;
    }
  }
  return best;
}

String? _size(RecordScanCardSize size) => switch (size) {
      RecordScanCardSize.mini => 'mini',
      RecordScanCardSize.wide => 'wide',
      RecordScanCardSize.square => 'square',
      RecordScanCardSize.uncertain => null,
    };

void main() {
  final run3 = File('$_dir/run3/result.json');
  final skip = run3.existsSync() ? false : 'no $_dir/run3/result.json';

  group('run3 parity', () {
    late List<Map<String, dynamic>> photos;
    late List<_AppCard> cards;

    setUpAll(() async {
      _faces = _loadFaces();
      photos = [
        for (final p in (jsonDecode(run3.readAsStringSync())
            as Map<String, dynamic>)['photos'] as List)
          p as Map<String, dynamic>,
      ];
      final sources = (Directory('$_dir/orig').listSync())
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => p.endsWith('.jpg'))
          .toList()
        ..sort();
      cards = await _scan(sources);
    });

    test('every pipeline card: same place, format, layout and orientation', () {
      expect(_faces, isNotNull,
          reason: 'run tool/cheki_face_reference.py first (see header)');
      final used = <_AppCard>{};
      for (final photo in photos) {
        final n = photo['number'];
        final card = _match(cards, photo);
        expect(card, isNotNull, reason: 'run3 #$n not found');
        used.add(card!);
        final quad = _quad(photo['quad'] as List);
        expect(_cornerDistance(card.quad, quad), lessThan(8),
            reason: 'run3 #$n edges');
        expect(_size(card.card.sizeClass), photo['size'],
            reason: 'run3 #$n size');
        expect(card.card.layoutTurns,
            (photo['layout_rotation_degrees_ccw'] as int) ~/ 90,
            reason: 'run3 #$n thick-border side');
        expect(card.orientation!.turns,
            (photo['rotation_degrees_ccw'] as int) ~/ 90,
            reason: 'run3 #$n orientation');
        expect(card.oriented, (photo['width'], photo['height']),
            reason: 'run3 #$n output size');
      }
      // The pipeline dropped the pre-cut copy (mask_5) as a duplicate of
      // run3 #13 across photos; the app scans one photo at a time.
      final extra = cards.where((c) => !used.contains(c)).toList();
      expect(extra.map((c) => c.source), ['qq_20261119_mask_5.jpg']);
    });

    test('must pass: 兔兔 upright five-inch (ratio ≈ 0.80) is WIDE', () {
      final card = _match(cards, photos.firstWhere((p) => p['number'] == 12))!;
      expect(card.card.sizeClass, RecordScanCardSize.wide);
      final (w, h) = card.oriented;
      expect(w / h, closeTo(0.80, 0.01));
    });

    test('must pass: 卡绒 is portrait (also the pre-cut copy)', () {
      final karon = _match(cards, photos.firstWhere((p) => p['number'] == 13))!;
      final copy = cards.singleWhere((c) => c.source.endsWith('mask_5.jpg'));
      for (final card in [karon, copy]) {
        expect(card.card.sizeClass, RecordScanCardSize.mini);
        final (w, h) = card.oriented;
        expect(h, greaterThan(w), reason: card.key);
        expect(card.orientation!.basis, CardOrientationBasis.filmLayoutAndFace);
      }
    });

    test('must pass: 晕酱 is cut along the card edge', () {
      final photo = photos.firstWhere((p) => p['number'] == 10);
      final card = _match(cards, photo)!;
      expect(_cornerDistance(card.quad, _quad(photo['quad'] as List)),
          lessThan(6));
      // No sliver of background is left along any side.
      final source = img.decodeJpg(
          File('$_dir/orig/qq_20261119_mask_2.jpg').readAsBytesSync())!;
      final rgb =
          source.convert(numChannels: 3).getBytes(order: img.ChannelOrder.rgb);
      final signal = PaperSignalImage.fromRgb(rgb, source.width, source.height);
      final again = CardEdgeFit.tightenPaperEdges(signal, card.quad);
      expect(_cornerDistance(again, card.quad), lessThan(1.5));
    });

    test('no face and no handwriting: keeps direction, low confidence', () {
      // run3 #1: a mini lying on its side with no upright face.
      final card = _match(cards, photos.firstWhere((p) => p['number'] == 1))!;
      expect(card.card.layoutTurns, 3);
      expect(card.orientation!.turns, 0);
      expect(card.orientation!.basis, CardOrientationBasis.sourceUnconfirmed);
      expect(card.orientation!.lowConfidence, isTrue);
      final confident = cards.where((c) => c != card && c.orientation != null);
      expect(confident.where((c) => c.orientation!.lowConfidence), isEmpty);
    });
  }, skip: skip);

  final inboxRef = File('$_dir/inbox-ref/result.json');
  group('inbox chat photos', () {
    test('formats agree with the pipeline wherever both settle one', () async {
      final photos = [
        for (final p in (jsonDecode(inboxRef.readAsStringSync())
            as Map<String, dynamic>)['photos'] as List)
          p as Map<String, dynamic>,
      ];
      final sources = {
        for (final p in photos) p['source'] as String,
      }.toList()
        ..sort();
      final cards = await _scan(sources);
      var compared = 0;
      for (final photo in photos) {
        final card = _match(cards, photo);
        final size = photo['size'] as String?;
        final appSize = card == null ? null : _size(card.card.sizeClass);
        _log('inbox #${photo['number']} pipeline=$size app=$appSize '
            '${card?.key ?? 'unmatched'}');
        if (card == null || size == null || appSize == null) continue;
        compared++;
        expect(appSize, size, reason: 'inbox #${photo['number']}');
        if (photo['rotation_degrees_ccw'] != null && card.orientation != null) {
          expect(card.orientation!.turns,
              (photo['rotation_degrees_ccw'] as int) ~/ 90,
              reason: 'inbox #${photo['number']} orientation');
        }
      }
      expect(compared, greaterThan(0));
    });
  }, skip: inboxRef.existsSync() ? false : "no $_dir/inbox-ref/result.json");
}
