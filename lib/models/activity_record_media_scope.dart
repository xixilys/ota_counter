import 'activity_record_media_model.dart';
import 'activity_record_model.dart';
import 'counter_model.dart';

String _normalizeMediaIdentityPart(String value) {
  final trimmed = value.trim().toLowerCase();
  if (trimmed.isEmpty) {
    return '';
  }
  return trimmed.replaceAll(
    RegExp(r'[\s·•・_\-~/\\\(\)\[\]\{\}]+'),
    '',
  );
}

bool _groupsCanMatch(String first, String second) {
  final normalizedFirst = _normalizeMediaIdentityPart(first);
  final normalizedSecond = _normalizeMediaIdentityPart(second);
  return normalizedFirst.isEmpty ||
      normalizedSecond.isEmpty ||
      normalizedFirst == normalizedSecond;
}

String _participantIdentityName(ActivityParticipant participant) {
  final personName = participant.personName.trim();
  return personName.isEmpty ? participant.memberName.trim() : personName;
}

String _counterIdentityName(CounterModel counter) {
  final personName = counter.personName.trim();
  return personName.isEmpty ? counter.name.trim() : personName;
}

bool _participantMatchesCounter(
  ActivityParticipant participant,
  CounterModel counter,
) {
  if (!_groupsCanMatch(participant.groupName, counter.groupName)) {
    return false;
  }
  if (participant.personId != null &&
      counter.personId != null &&
      participant.personId == counter.personId) {
    return true;
  }
  final participantName =
      _normalizeMediaIdentityPart(_participantIdentityName(participant));
  final counterName =
      _normalizeMediaIdentityPart(_counterIdentityName(counter));
  return participantName.isNotEmpty && participantName == counterName;
}

bool _ownerMatchesCounter(
  ActivityRecordMediaModel media,
  CounterModel counter,
) {
  if (media.ownerPersonId != null &&
      counter.personId != null &&
      media.ownerPersonId == counter.personId) {
    return true;
  }
  if (!_groupsCanMatch(media.ownerGroupName, counter.groupName)) {
    return false;
  }
  final ownerName = _normalizeMediaIdentityPart(media.ownerPersonName);
  final counterName =
      _normalizeMediaIdentityPart(_counterIdentityName(counter));
  return ownerName.isNotEmpty && ownerName == counterName;
}

ActivityRecordMediaOwnerScope? resolveActivityRecordMediaOwnerScope({
  required Iterable<ActivityRecordModel> records,
  required Iterable<CounterModel> ownerCounters,
}) {
  final counters = ownerCounters.toList(growable: false);
  if (counters.isEmpty) {
    return null;
  }

  for (final record in records) {
    if (!record.isMulti) {
      continue;
    }
    for (final participant in record.effectiveParticipants) {
      if (counters.any(
        (counter) => _participantMatchesCounter(participant, counter),
      )) {
        return ActivityRecordMediaOwnerScope(
          personId: participant.personId,
          personName: _participantIdentityName(participant),
          groupName: participant.groupName.trim(),
        );
      }
    }
  }

  final counter = counters.first;
  return ActivityRecordMediaOwnerScope(
    personId: counter.personId,
    personName: _counterIdentityName(counter),
    groupName: counter.groupName.trim(),
  );
}

bool activityRecordMediaBelongsToMember({
  required ActivityRecordMediaModel media,
  required ActivityRecordModel record,
  required Iterable<CounterModel> ownerCounters,
}) {
  final counters = ownerCounters.toList(growable: false);
  if (counters.isEmpty) {
    return true;
  }

  if (media.hasOwnerScope) {
    return counters.any((counter) => _ownerMatchesCounter(media, counter));
  }

  if (!record.isMulti) {
    return true;
  }

  final participants = record.effectiveParticipants;
  if (participants.isEmpty) {
    return true;
  }
  return counters.any(
    (counter) => _participantMatchesCounter(participants.first, counter),
  );
}
