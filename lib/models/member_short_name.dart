/// The short text printed on a member's card and avatar.
///
/// A member can configure [CounterModel.shortName] (1-4 characters) themselves.
/// When that is empty, [defaultMemberShortName] derives a stable, readable
/// glyph from the full name so cards never collapse to a placeholder "小" or a
/// single Latin initial for everyone:
///
/// - a leading 小 / 阿 / 大 is dropped when the rest still has text
///   (小雪→雪, 小树→树, 阿岚→岚);
/// - doubled names keep one character (娜娜→娜, 熊熊→熊);
/// - mixed CJK + Latin names use the CJK part, up to four characters
///   (兔兔Miottie→兔, 浙璃Kiko→浙璃, 水堇Sumire→水堇, 班班Airuru→班);
/// - Latin-only names keep up to four letters (Remi→Remi, Liumoo→Lium);
/// - anything else falls back to the first few characters.
library;

/// Maximum number of characters a configured short name may hold.
const int kMemberShortNameMaxLength = 4;

final RegExp _cjkPattern = RegExp(
  r'[㐀-䶿一-鿿豈-﫿]',
);
final RegExp _latinPattern = RegExp(r'[A-Za-z]');
final RegExp _leadingHonorific = RegExp(r'[小阿大]');

/// Reads a numeric character count using grapheme clusters, so an emoji or a
/// combining sequence still counts as one character.
int memberShortNameLength(String value) => value.runes.length;

/// Trims a user-typed short name to at most [kMemberShortNameMaxLength]
/// characters. Returns an empty string when nothing usable remains.
String normalizeMemberShortName(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  final buffer = StringBuffer();
  var count = 0;
  for (final rune in trimmed.runes) {
    if (count >= kMemberShortNameMaxLength) {
      break;
    }
    buffer.writeCharCode(rune);
    count++;
  }
  return buffer.toString().trim();
}

/// Chooses the short text to draw for [name].
///
/// [configured] (the member's own setting) always wins when non-empty after
/// trimming; otherwise a short name is derived from [name].
String resolveMemberShortName({
  required String name,
  String? configured,
}) {
  final custom = normalizeMemberShortName(configured ?? '');
  if (custom.isNotEmpty) {
    return custom;
  }
  return defaultMemberShortName(name);
}

/// Derives the default short name from a full member name.
///
/// Pure function; see the library doc for the rules. Never returns an empty
/// string when [name] has any visible character.
String defaultMemberShortName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    return '?';
  }

  final chars = trimmed.runes.map(String.fromCharCode).toList();
  var start = 0;
  if (chars.length > 1 && _leadingHonorific.hasMatch(chars.first)) {
    // 小雪→雪, 小树→树, 阿岚→岚. A bare "小" or "大" is kept as-is.
    start = 1;
  }

  var body = chars.sublist(start);
  // Drop a separating dot / space left by the prefix removal (小·某).
  while (body.isNotEmpty && _isSeparator(body.first)) {
    body = body.sublist(1);
  }
  if (body.isEmpty) {
    body = chars;
  }

  // Doubled names only give one character (娜娜→娜, 熊熊→熊, 班班→班).
  final doubled = body.length >= 2 &&
      body[0] == body[1] &&
      _cjkPattern.hasMatch(body[0]);
  final cjk = _splitCjkRun(doubled ? body.sublist(0, 1) : body);
  final latin = body.where(_latinPattern.hasMatch).join();

  if (cjk.isNotEmpty && latin.isEmpty) {
    return cjk;
  }
  if (cjk.isEmpty && latin.isNotEmpty) {
    final letters = latin.substring(0, latin.length.clamp(0, 4));
    final first = letters.substring(0, 1).toUpperCase();
    return '$first${letters.substring(1)}';
  }
  if (cjk.isNotEmpty) {
    // Mixed CJK + Latin: the Chinese part is the member's own name; the Latin
    // part is usually a transliteration or a tag.
    return cjk;
  }

  // Digits / punctuation only: keep up to four characters.
  return body.take(4).join();
}

/// Returns the leading CJK run of [chars], at most two characters.
///
/// Two characters are the common short form for Chinese nicknames (浙璃,
/// 水堇); a longer name like 夏小米 prints 夏小, which stays readable at
/// 2-5 columns without duplicating the whole name on the card.
String _splitCjkRun(List<String> chars) {
  final buffer = StringBuffer();
  for (final char in chars) {
    if (!_cjkPattern.hasMatch(char)) {
      if (buffer.isNotEmpty) {
        break;
      }
      continue;
    }
    buffer.write(char);
    if (buffer.length >= 2) {
      break;
    }
  }
  return buffer.toString();
}

bool _isSeparator(String char) {
  return char.trim().isEmpty ||
      char == '·' ||
      char == '•' ||
      char == '・' ||
      char == '-' ||
      char == '_';
}
