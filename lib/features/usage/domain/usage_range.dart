import 'dart:ui' show Locale;

/// Calendar dates as the companion reports them: `YYYY-MM-DD`, local to
/// the machine. The arithmetic runs on UTC midnights, so no time zone or
/// daylight-saving change shifts a day.
DateTime? parseUsageDate(String date) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(date);
  if (match == null) {
    return null;
  }
  return DateTime.utc(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

/// [day]'s calendar date as `YYYY-MM-DD` (its own fields, any zone).
String formatUsageDate(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// [date] moved by [days] (negative: back).
String addUsageDays(String date, int days) {
  final parsed = parseUsageDate(date);
  if (parsed == null) {
    return date;
  }
  return formatUsageDate(
    DateTime.utc(parsed.year, parsed.month, parsed.day + days),
  );
}

/// Days from [from] to [to] (0 when equal, negative when [to] is earlier).
int usageDaysBetween(String from, String to) {
  final a = parseUsageDate(from);
  final b = parseUsageDate(to);
  if (a == null || b == null) {
    return 0;
  }
  return (b.difference(a).inHours / 24).round();
}

/// The weekday a week starts on in [locale]'s region: Sunday where that is
/// the custom (the Americas' largest, Japan, Korea, Israel, …), Monday
/// everywhere else and without a region.
int firstWeekdayFor(Locale? locale) {
  const sundayFirst = {
    'US', 'CA', 'MX', 'BR', 'JP', 'KR', 'TW', 'HK', 'IL', 'PH', 'IN', //
    'ZA', 'AU', 'CO', 'PE', 'VE', 'GT', 'DO', 'PR', 'SG', 'TH',
  };
  final country = locale?.countryCode?.toUpperCase();
  return country != null && sundayFirst.contains(country)
      ? DateTime.sunday
      : DateTime.monday;
}

/// The ranges the usage explorer offers.
enum UsageRangePreset {
  today('Today'),
  yesterday('Yesterday'),
  last7('7 days'),
  thisWeek('This week'),
  last30('30 days'),
  thisMonth('This month'),
  custom('Custom');

  const UsageRangePreset(this.label);

  final String label;

  static UsageRangePreset? byName(Object? name) {
    for (final preset in values) {
      if (preset.name == name) {
        return preset;
      }
    }
    return null;
  }
}

/// A run of days: [from] to [to] hold data (never after today); a week or
/// month is shown up to [end], its future days empty.
class UsageDateRange {
  const UsageDateRange(this.from, this.to, {String? end}) : end = end ?? to;

  final String from;
  final String to;
  final String end;

  /// Days that have passed (or are today): what totals and averages cover.
  int get length => usageDaysBetween(from, to) + 1;

  bool get isSingleDay => from == end;

  bool contains(String date) =>
      date.compareTo(from) >= 0 && date.compareTo(to) <= 0;

  /// Every day shown, [from] to [end].
  List<String> get shownDays => [
    for (var i = 0; i <= usageDaysBetween(from, end); i++)
      addUsageDays(from, i),
  ];

  @override
  bool operator ==(Object other) =>
      other is UsageDateRange &&
      other.from == from &&
      other.to == to &&
      other.end == end;

  @override
  int get hashCode => Object.hash(from, to, end);

  @override
  String toString() => 'UsageDateRange($from..$to, end $end)';
}

/// [preset] on the day [today] (`YYYY-MM-DD`, the machine's). A week
/// starts on [firstWeekday] ([DateTime.monday] … [DateTime.sunday]).
/// [custom] is the picked range, clamped to [today].
UsageDateRange resolveUsageRange(
  UsageRangePreset preset, {
  required String today,
  int firstWeekday = DateTime.monday,
  UsageDateRange? custom,
}) {
  final day = parseUsageDate(today) ?? DateTime.utc(1970);
  switch (preset) {
    case UsageRangePreset.today:
      return UsageDateRange(today, today);
    case UsageRangePreset.yesterday:
      final yesterday = addUsageDays(today, -1);
      return UsageDateRange(yesterday, yesterday);
    case UsageRangePreset.last7:
      return UsageDateRange(addUsageDays(today, -6), today);
    case UsageRangePreset.last30:
      return UsageDateRange(addUsageDays(today, -29), today);
    case UsageRangePreset.thisWeek:
      final back = (day.weekday - firstWeekday + 7) % 7;
      final from = addUsageDays(today, -back);
      return UsageDateRange(from, today, end: addUsageDays(from, 6));
    case UsageRangePreset.thisMonth:
      final first = DateTime.utc(day.year, day.month);
      final last = DateTime.utc(day.year, day.month + 1, 0);
      return UsageDateRange(
        formatUsageDate(first),
        today,
        end: formatUsageDate(last),
      );
    case UsageRangePreset.custom:
      final picked = custom ?? UsageDateRange(addUsageDays(today, -6), today);
      var from = picked.from;
      final to = picked.to.compareTo(today) > 0 ? today : picked.to;
      if (from.compareTo(to) > 0) {
        from = to;
      }
      return UsageDateRange(from, to);
  }
}

/// The period [range] is compared with: the one just before it, as long
/// as what has passed of it. A month compares with the same days of the
/// previous month (cut at its end), a week with the same weekdays of the
/// week before.
UsageDateRange previousUsageRange(
  UsageRangePreset preset,
  UsageDateRange range,
) {
  if (preset == UsageRangePreset.thisMonth) {
    final from = parseUsageDate(range.from);
    if (from != null) {
      final first = DateTime.utc(from.year, from.month - 1);
      final last = DateTime.utc(from.year, from.month, 0);
      final wanted = DateTime.utc(
        first.year,
        first.month,
        first.day + range.length - 1,
      );
      return UsageDateRange(
        formatUsageDate(first),
        formatUsageDate(wanted.isAfter(last) ? last : wanted),
      );
    }
  }
  if (preset == UsageRangePreset.thisWeek) {
    return UsageDateRange(
      addUsageDays(range.from, -7),
      addUsageDays(range.to, -7),
    );
  }
  final length = range.length;
  return UsageDateRange(
    addUsageDays(range.from, -length),
    addUsageDays(range.from, -1),
  );
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// `Thu 25 Sep`.
String formatUsageDay(String date) {
  final day = parseUsageDate(date);
  if (day == null) {
    return date;
  }
  return '${_weekdays[day.weekday - 1]} ${day.day} ${_months[day.month - 1]}';
}

/// `Mon`.
String usageWeekday(String date) {
  final day = parseUsageDate(date);
  return day == null ? '' : _weekdays[day.weekday - 1];
}

/// `25 Sep`, or `25 Sep 2025` outside [currentYear].
String formatUsageShortDate(String date, {int? currentYear}) {
  final day = parseUsageDate(date);
  if (day == null) {
    return date;
  }
  final year = currentYear != null && day.year != currentYear
      ? ' ${day.year}'
      : '';
  return '${day.day} ${_months[day.month - 1]}$year';
}

/// `19–25 Sep`, `29 Sep – 5 Oct`, `Thu 25 Sep` for one day.
String formatUsageRange(UsageDateRange range) {
  final from = parseUsageDate(range.from);
  final end = parseUsageDate(range.end);
  if (from == null || end == null) {
    return '${range.from} – ${range.end}';
  }
  if (range.from == range.end) {
    return formatUsageDay(range.from);
  }
  if (from.year == end.year && from.month == end.month) {
    return '${from.day}–${end.day} ${_months[end.month - 1]}';
  }
  final year = from.year == end.year ? null : end.year;
  return '${formatUsageShortDate(range.from, currentYear: year)} – '
      '${formatUsageShortDate(range.end, currentYear: from.year)}';
}
