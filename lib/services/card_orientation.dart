import 'dart:math' as math;

/// Why a cut card got its orientation.
enum CardOrientationBasis {
  /// The thick border already lies at the bottom.
  filmLayout,

  /// A portrait cut whose thick border lies on a side (e.g. a portrait
  /// print on WIDE film): kept as photographed.
  sourceUpright,

  /// Faces, perpendicular to the film layout (a sideways composition).
  face,

  /// Faces and the thick border agree.
  filmLayoutAndFace,

  /// Margin handwriting and the thick border agree.
  filmLayoutAndText,

  /// The thick border says turn, nothing corroborates it: kept as is.
  sourceUnconfirmed,

  /// Faces and the thick border point opposite ways: kept as is.
  conflicting,
}

/// The orientation settled for one cut card.
class CardOrientation {
  const CardOrientation(this.turns, this.basis, {required this.lowConfidence});

  /// Quarter turns counter-clockwise applied to the cut.
  final int turns;
  final CardOrientationBasis basis;

  /// The evidence was missing or contradictory; worth a human glance.
  final bool lowConfidence;

  /// The same rotation for `img.copyRotate` (degrees clockwise).
  int get clockwiseDegrees => (-90 * turns) % 360;

  @override
  String toString() =>
      'CardOrientation($turns, ${basis.name}${lowConfidence ? ', low' : ''})';
}

/// Combines the evidence on a cut card's direction: which side holds the
/// thick white border (film layout), which way faces in the picture are
/// upright, and (when available) which way margin handwriting reads.
///
/// The film format and its layout are settled first and independently (a
/// WIDE card standing on its short side is still WIDE). The picture may be
/// composed sideways on the film, so the border alone never turns a card;
/// a face or handwriting must corroborate it. When the signals contradict
/// each other or are all missing, the card keeps the photographed direction
/// and is marked [CardOrientation.lowConfidence].
class CardOrientationDecider {
  CardOrientationDecider._();

  /// All turns are counter-clockwise quarter turns of the cut as it was
  /// photographed: [layoutTurns] brings the thick border to the bottom
  /// (null without a settled film format), [faceTurns] makes faces upright,
  /// [textTurns] makes margin handwriting read normally. The app has no text
  /// recognizer yet; [textTurns] is the hook for one.
  static CardOrientation decide({
    required int width,
    required int height,
    required int? layoutTurns,
    int? faceTurns,
    int? textTurns,
  }) {
    if (layoutTurns == null) {
      return faceTurns == null || faceTurns == 0
          ? CardOrientation(0, CardOrientationBasis.face,
              lowConfidence: faceTurns == null)
          : CardOrientation(faceTurns, CardOrientationBasis.face,
              lowConfidence: false);
    }
    final layout = layoutTurns % 4;
    final face = faceTurns == null ? null : faceTurns % 4;
    // An already portrait cut is not laid on its side just to put the
    // border down: portrait compositions on WIDE film are valid.
    if (width < height && layout != 2) {
      return layout == 0
          ? const CardOrientation(0, CardOrientationBasis.filmLayout,
              lowConfidence: false)
          : CardOrientation(0, CardOrientationBasis.sourceUpright,
              lowConfidence: face != 0);
    }
    if (face != null && (width >= height || face.isEven)) {
      if (face == layout) {
        return CardOrientation(face, CardOrientationBasis.filmLayoutAndFace,
            lowConfidence: false);
      }
      if ((face - layout) % 4 == 2) {
        return const CardOrientation(0, CardOrientationBasis.conflicting,
            lowConfidence: true);
      }
      return CardOrientation(face, CardOrientationBasis.face,
          lowConfidence: false);
    }
    if (layout == 0) {
      return const CardOrientation(0, CardOrientationBasis.filmLayout,
          lowConfidence: false);
    }
    if (textTurns != null && textTurns % 4 == layout) {
      return CardOrientation(layout, CardOrientationBasis.filmLayoutAndText,
          lowConfidence: false);
    }
    return const CardOrientation(0, CardOrientationBasis.sourceUnconfirmed,
        lowConfidence: true);
  }

  /// Upright-face score of the card in each of the four turns
  /// (counter-clockwise, 0–3) → the turn that makes faces upright, or null
  /// unless one turn is both strong and clearly ahead of the others. When
  /// that turn is the one the thick border already points to ([layoutTurns]),
  /// the two corroborate each other and a smaller lead suffices.
  static int? faceTurns(Map<int, double> scores, {int? layoutTurns}) {
    var best = 0, bestScore = double.negativeInfinity;
    for (var turn = 0; turn < 4; turn++) {
      final score = scores[turn] ?? 0;
      if (score > bestScore) {
        best = turn;
        bestScore = score;
      }
    }
    var runnerUp = 0.0;
    for (var turn = 0; turn < 4; turn++) {
      if (turn != best) runnerUp = math.max(runnerUp, scores[turn] ?? 0);
    }
    final margin = layoutTurns != null && best == layoutTurns % 4
        ? faceMarginWithLayout
        : faceMargin;
    return bestScore >= faceMinimum && bestScore - runnerUp >= margin
        ? best
        : null;
  }

  /// Weakest upright-face score (YuNet, landmarks upright) that counts.
  static const double faceMinimum = 0.75;

  /// Lead over every other turn that a face direction needs on its own...
  static const double faceMargin = 0.15;

  /// ...and when the thick border points the same way.
  static const double faceMarginWithLayout = 0.10;
}
