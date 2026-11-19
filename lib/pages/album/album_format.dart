/// Formatting helpers for the album. Kept separate so widget tests and the
/// golden preview can use the same labels without depending on `intl`.
library;

const _weekdays = <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

String albumWeekday(DateTime day) => _weekdays[day.weekday - 1];

String albumMonthTitle(DateTime month) => '${month.year}年${month.month}月';

String albumDayTitle(DateTime? day) {
  if (day == null) return '日期不明';
  return '${day.month}月${day.day}日';
}

String albumShortDay(DateTime? day) {
  if (day == null) return '日期不明';
  return '${day.month}.${day.day}';
}

String albumCountLabel(int count) => '$count 张';

String albumMemberCountLabel(int solo, int group) {
  if (group <= 0) return '单人切 $solo';
  return '单人切 $solo · 同框 $group';
}
