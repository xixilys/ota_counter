import 'counter_model.dart';

/// Shared normalisation for names that are compared across groups. It keeps
/// punctuation / spacing differences from creating a second "person" key but
/// never treats a name alone as proof that two cards are the same real person.
String normalizePersonPart(String value) {
  final trimmed = value.trim().toLowerCase();
  if (trimmed.isEmpty) {
    return '';
  }
  return trimmed.replaceAll(
    RegExp(r'[\s·•・_\-~/\\\(\)\[\]\{\}]+'),
    '',
  );
}

/// Home / sync / stats entry key for one member card. Person ids are the
/// strongest evidence; an explicitly entered person name is next. The card
/// itself is only a fallback, so two groups of one person stay together while
/// unrelated namesakes stay apart.
String counterPersonEntryKey(CounterModel counter) {
  final personId = counter.personId;
  if (personId != null) {
    return 'person-id:$personId';
  }
  final personName = normalizePersonPart(counter.personName);
  if (personName.isNotEmpty) {
    return 'person-name:$personName';
  }
  return 'counter:${normalizePersonPart(counter.groupName)}|'
      '${normalizePersonPart(counter.name)}';
}

/// Whether the card carries an explicit identity the user can manage. A name
/// entered only as "same as card name" still counts, but is clearly weaker.
bool counterHasExplicitPerson(CounterModel counter) =>
    counter.personId != null || normalizePersonPart(counter.personName).isNotEmpty;
