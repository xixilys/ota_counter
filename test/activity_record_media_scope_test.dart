import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/models/activity_record_media_scope.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';

void main() {
  final firstCounter = CounterModel(
    id: 1,
    name: 'A',
    groupName: 'G1',
    personId: 101,
    personName: 'A',
    color: '#111111',
  );
  final secondCounter = CounterModel(
    id: 2,
    name: 'B',
    groupName: 'G2',
    personId: 202,
    personName: 'B',
    color: '#222222',
  );
  final sharedRecord = ActivityRecordModel.multiCut(
    id: 10,
    participants: const [
      ActivityParticipant(
        memberName: 'A',
        groupName: 'G1',
        personId: 101,
        personName: 'A',
      ),
      ActivityParticipant(
        memberName: 'B',
        groupName: 'G2',
        personId: 202,
        personName: 'B',
      ),
    ],
    field: CounterCountField.threeInch,
    occurredAt: DateTime(2026, 8, 29),
  );

  ActivityRecordMediaModel media({
    int? ownerPersonId,
    String ownerPersonName = '',
    String ownerGroupName = '',
  }) {
    return ActivityRecordMediaModel(
      id: 1,
      recordId: 10,
      path: 'photo.jpg',
      createdAt: DateTime(2026, 8, 29),
      ownerPersonId: ownerPersonId,
      ownerPersonName: ownerPersonName,
      ownerGroupName: ownerGroupName,
    );
  }

  test('legacy media on a shared record belongs to its first participant', () {
    final legacyMedia = media();

    expect(
      activityRecordMediaBelongsToMember(
        media: legacyMedia,
        record: sharedRecord,
        ownerCounters: [firstCounter],
      ),
      isTrue,
    );
    expect(
      activityRecordMediaBelongsToMember(
        media: legacyMedia,
        record: sharedRecord,
        ownerCounters: [secondCounter],
      ),
      isFalse,
    );
  });

  test('scoped media on a shared record only appears for its owner', () {
    final secondMedia = media(
      ownerPersonId: 202,
      ownerPersonName: 'B',
      ownerGroupName: 'G2',
    );

    expect(
      activityRecordMediaBelongsToMember(
        media: secondMedia,
        record: sharedRecord,
        ownerCounters: [firstCounter],
      ),
      isFalse,
    );
    expect(
      activityRecordMediaBelongsToMember(
        media: secondMedia,
        record: sharedRecord,
        ownerCounters: [secondCounter],
      ),
      isTrue,
    );
  });

  test('owner matching tolerates a refreshed person id in the same group', () {
    final historicalCounter = CounterModel(
      id: 3,
      name: 'B',
      groupName: 'G2',
      personId: 999,
      personName: 'B',
      color: '#333333',
    );
    final secondMedia = media(
      ownerPersonId: 202,
      ownerPersonName: 'B',
      ownerGroupName: 'G2',
    );

    expect(
      activityRecordMediaBelongsToMember(
        media: secondMedia,
        record: sharedRecord,
        ownerCounters: [historicalCounter],
      ),
      isTrue,
    );
  });

  test('same-name people in different groups do not share media', () {
    final homonym = CounterModel(
      id: 4,
      name: 'B',
      groupName: 'G3',
      personId: 303,
      personName: 'B',
      color: '#444444',
    );
    final secondMedia = media(
      ownerPersonId: 202,
      ownerPersonName: 'B',
      ownerGroupName: 'G2',
    );

    expect(
      activityRecordMediaBelongsToMember(
        media: secondMedia,
        record: sharedRecord,
        ownerCounters: [homonym],
      ),
      isFalse,
    );
  });

  test('owner scope resolves the matching participant, not the first one', () {
    final owner = resolveActivityRecordMediaOwnerScope(
      records: [sharedRecord],
      ownerCounters: [secondCounter],
    );

    expect(owner?.personId, 202);
    expect(owner?.personName, 'B');
    expect(owner?.groupName, 'G2');
  });
}
