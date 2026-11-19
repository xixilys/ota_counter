import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/counter_model.dart';
import '../models/idol_database_models.dart';
import '../models/person_identity.dart';
import 'database_service.dart';
import 'idol_database_service.dart';

/// One card of a real person (one group / one stage name).
class PersonCardInfo {
  final CounterModel counter;
  final DateTime? lastActivity;
  final bool isCurrent;
  final bool isPast;
  final String membershipStatus;
  final bool formerMembership;

  const PersonCardInfo({
    required this.counter,
    required this.lastActivity,
    required this.isCurrent,
    required this.isPast,
    required this.membershipStatus,
    required this.formerMembership,
  });

  String get groupLabel =>
      counter.groupName.trim().isEmpty ? '未分组' : counter.groupName.trim();
}

/// Read-only view for the "this person's cards across groups" sheet.
class PersonCardOverview {
  final int? personId;
  final String displayName;
  final List<PersonCardInfo> cards;

  /// Cards with the same stage name but no proven/typed person link. They are
  /// only offered for an explicit merge, never grouped automatically.
  final List<CounterModel> sameNameCards;

  const PersonCardOverview({
    required this.personId,
    required this.displayName,
    required this.cards,
    required this.sameNameCards,
  });

  PersonCardInfo? get currentCard {
    for (final card in cards) {
      if (card.isCurrent) return card;
    }
    return cards.isEmpty ? null : cards.first;
  }

  int get totalCount =>
      cards.fold<int>(0, (sum, card) => sum + card.counter.count);
}

/// Device-local memory for multi-group cards. Nothing here changes the
/// database schema: "current card" and "past / graduated" are views, while
/// person ids on the cards remain the source of truth.
class PersonCardService {
  PersonCardService._();

  static const String _currentCardsKey = 'person_current_cards';
  static const String _pastCardsKey = 'person_past_cards';

  static Map<String, int> _currentCards = <String, int>{};
  static Set<int> _pastCards = <int>{};
  static bool _loaded = false;

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_currentCardsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _currentCards = {
            for (final entry in decoded.entries)
              if (entry.value is num && (entry.value as num).toInt() > 0)
                '${entry.key}': (entry.value as num).toInt(),
          };
        }
      }
      _pastCards = {
        for (final value in prefs.getStringList(_pastCardsKey) ?? const [])
          if (int.tryParse(value) != null) int.parse(value),
      };
    } catch (_) {
      _currentCards = <String, int>{};
      _pastCards = <int>{};
    }
    _loaded = true;
  }

  static void _ensureLoaded() {
    if (!_loaded) {
      // Callers that paint before [load] finishes only lose the preference,
      // never data. Production calls load() before runApp.
      _loaded = true;
    }
  }

  static String preferenceKey(CounterModel counter) {
    final personId = counter.personId;
    if (personId != null) return 'p:$personId';
    final personName = normalizePersonPart(counter.personName);
    if (personName.isNotEmpty) return 'n:$personName';
    return 'c:${counter.id ?? ''}';
  }

  static int? currentCardIdFor(CounterModel counter) {
    _ensureLoaded();
    return _currentCards[preferenceKey(counter)];
  }

  /// First remembered current id among several cards of one person. The
  /// grouping may contain both a linked card and an old typed-name alias, so
  /// looking at only the first card can miss the preference.
  static int? currentCardIdForAny(Iterable<CounterModel> counters) {
    for (final counter in counters) {
      final id = currentCardIdFor(counter);
      if (id != null) return id;
    }
    return null;
  }

  static bool isPast(CounterModel counter) {
    _ensureLoaded();
    final id = counter.id;
    return id != null && _pastCards.contains(id);
  }

  static Future<void> setCurrentCard(CounterModel personAnchor, int? cardId) async {
    _ensureLoaded();
    final key = preferenceKey(personAnchor);
    if (cardId == null) {
      _currentCards.remove(key);
    } else {
      _currentCards[key] = cardId;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_currentCardsKey, jsonEncode(_currentCards));
  }

  static Future<void> setPast(CounterModel counter, bool past) async {
    _ensureLoaded();
    final id = counter.id;
    if (id == null) return;
    if (past) {
      _pastCards.add(id);
    } else {
      _pastCards.remove(id);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _pastCardsKey,
      _pastCards.map((value) => value.toString()).toList(growable: false),
    );
  }

  static bool _sameRealPerson(CounterModel anchor, CounterModel card) {
    final anchorId = anchor.personId;
    final cardId = card.personId;
    if (anchorId != null && cardId != null) {
      return anchorId == cardId;
    }
    final anchorName = normalizePersonPart(anchor.personName);
    final cardName = normalizePersonPart(card.personName);
    if (anchorName.isEmpty || cardName.isEmpty) return false;
    if (anchorName != cardName) return false;
    // A different explicit id means the user already said these are not the
    // same person, even when the typed main name happens to match.
    return anchorId == null || cardId == null;
  }

  static Future<PersonCardOverview> loadOverview(
    CounterModel anchor, {
    List<CounterModel>? counters,
  }) async {
    await load();
    final all = counters ?? await DatabaseService.getCounters();
    final lastActivity = await DatabaseService.getLastCounterActivityDays(
      counters: all,
    );

    final cards = <CounterModel>[];
    for (final counter in all) {
      if (counter.id == anchor.id ||
          (anchor.id == null && counter == anchor) ||
          _sameRealPerson(anchor, counter)) {
        cards.add(counter);
      }
    }
    if (cards.isEmpty) cards.add(anchor);

    final anchorName = normalizePersonPart(anchor.name);
    final sameName = <CounterModel>[];
    if (anchorName.isNotEmpty) {
      for (final counter in all) {
        if (cards.any((card) => card.id == counter.id)) continue;
        if (normalizePersonPart(counter.name) == anchorName) {
          sameName.add(counter);
        }
      }
    }

    final memberships = <String, IdolMember>{};
    final personId = anchor.personId ??
        cards.map((card) => card.personId).whereType<int>().firstOrNull;
    if (personId != null) {
      try {
        for (final member in
            await IdolDatabaseService.getMembersForPerson(personId)) {
          memberships.putIfAbsent(
            '${normalizePersonPart(member.groupName)}|'
            '${normalizePersonPart(member.name)}',
            () => member,
          );
        }
      } catch (_) {
        // The idol library is optional context.
      }
    }

    final currentKey = preferenceKey(anchor);
    final configuredCurrent = _currentCards[currentKey];
    final activeCards = [
      for (final card in cards)
        if (!isPast(card)) card,
    ];
    final ranked = activeCards.isEmpty ? [...cards] : activeCards;
    ranked.sort((a, b) {
      final activityCompare = (lastActivity[b.id] ?? DateTime(0))
          .compareTo(lastActivity[a.id] ?? DateTime(0));
      if (activityCompare != 0) return activityCompare;
      return b.count.compareTo(a.count);
    });
    final fallbackCurrent = ranked.first.id;

    final infos = <PersonCardInfo>[];
    for (final counter in cards) {
      final membership = memberships[
          '${normalizePersonPart(counter.groupName)}|'
          '${normalizePersonPart(counter.name)}'];
      infos.add(PersonCardInfo(
        counter: counter,
        lastActivity: lastActivity[counter.id],
        isCurrent: configuredCurrent != null
            ? counter.id == configuredCurrent
            : counter.id == fallbackCurrent,
        isPast: isPast(counter),
        membershipStatus: membership?.status.trim() ?? '',
        formerMembership: membership?.isFormerAffiliation ?? false,
      ));
    }
    infos.sort((a, b) {
      if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
      final timeCompare = (b.lastActivity ?? DateTime(0))
          .compareTo(a.lastActivity ?? DateTime(0));
      if (timeCompare != 0) return timeCompare;
      return a.groupLabel.toLowerCase().compareTo(b.groupLabel.toLowerCase());
    });

    final displayName = anchor.personName.trim().isNotEmpty
        ? anchor.personName.trim()
        : (cards.map((card) => card.personName.trim()).firstWhere(
              (name) => name.isNotEmpty,
              orElse: () => anchor.name,
            ));

    return PersonCardOverview(
      personId: personId,
      displayName: displayName,
      cards: infos,
      sameNameCards: sameName,
    );
  }

  static CounterModel _withIdentity(
    CounterModel counter, {
    required int? personId,
    required String personName,
  }) {
    return CounterModel(
      id: counter.id,
      name: counter.name,
      groupName: counter.groupName,
      personId: personId,
      personName: personName,
      color: counter.color,
      isHidden: counter.isHidden,
      threeInchCount: counter.threeInchCount,
      fiveInchCount: counter.fiveInchCount,
      unsignedThreeInchCount: counter.unsignedThreeInchCount,
      unsignedFiveInchCount: counter.unsignedFiveInchCount,
      groupCutCount: counter.groupCutCount,
      threeInchShukudaiCount: counter.threeInchShukudaiCount,
      fiveInchShukudaiCount: counter.fiveInchShukudaiCount,
    );
  }

  static Future<IdolPerson> ensurePerson(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('真人主档名不能为空');
    }
    final id = await IdolDatabaseService.upsertPerson(
      IdolPerson(name: trimmed),
    );
    return IdolPerson(id: id, name: trimmed);
  }

  static Future<void> linkCounterToPerson(
    CounterModel counter,
    IdolPerson person,
  ) async {
    final id = counter.id;
    if (id == null || person.id == null) return;
    await DatabaseService.updateCounter(
      id,
      _withIdentity(
        counter,
        personId: person.id,
        personName: person.name.trim(),
      ),
    );
  }

  static Future<void> unlinkCounter(CounterModel counter) async {
    final id = counter.id;
    if (id == null) return;
    await DatabaseService.updateCounter(
      id,
      _withIdentity(counter, personId: null, personName: ''),
    );
  }

  /// Links [others] to the anchor's real person (creating one when the anchor
  /// has only a typed name). Returns the surviving person.
  static Future<IdolPerson> mergeCardsIntoPerson(
    CounterModel anchor,
    Iterable<CounterModel> others,
  ) async {
    IdolPerson person;
    final anchorId = anchor.personId;
    if (anchorId != null) {
      person = IdolPerson(
        id: anchorId,
        name: anchor.personName.trim().isEmpty
            ? anchor.name.trim()
            : anchor.personName.trim(),
      );
    } else {
      person = await ensurePerson(
        anchor.personName.trim().isEmpty
            ? anchor.name.trim()
            : anchor.personName.trim(),
      );
      await linkCounterToPerson(anchor, person);
    }
    for (final other in others) {
      await linkCounterToPerson(other, person);
    }
    return person;
  }
}
