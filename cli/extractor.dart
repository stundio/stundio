#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: dart extractor.dart <group_or_class_name> [data_file_path] [output_dir]');
    exit(1);
  }

  final groupName = args[0];
  final dataPath = args.length > 1 ? args[1] : 'sample.json';
  final outputDir = args.length > 2 ? args[2] : '.';
  final results = await extractData(groupName, dataPath);

  if (results != null && results.isNotEmpty) {
    // Group by day
    final groupedResults = <String, List<Map<String, dynamic>>>{};
    for (final item in results) {
      groupedResults.putIfAbsent(item['Day'] as String, () => []).add(item);
    }

    // Ensure output directory exists
    await Directory(outputDir).create(recursive: true);

    // Save JSON
    final jsonFile = File('$outputDir/$groupName.json');
    final jsonOutput = {
      for (final entry in groupedResults.entries) entry.key: entry.value
    };
    await jsonFile.writeAsString(
      const JsonEncoder.withIndent('    ').convert(jsonOutput),
    );

    // Save CSV
    final csvFile = File('$outputDir/$groupName.csv');
    final keys = results.first.keys.where((k) => k != 'day_idx').toList();
    final csvBuffer = StringBuffer();
    csvBuffer.writeln(keys.join(','));
    for (final row in results) {
      final values = keys.map((k) {
        final val = row[k]?.toString() ?? '';
        // Escape fields containing commas or quotes
        if (val.contains(',') || val.contains('"')) {
          return '"${val.replaceAll('"', '""')}"';
        }
        return val;
      });
      csvBuffer.writeln(values.join(','));
    }
    await csvFile.writeAsString(csvBuffer.toString());

    print('\nSaved to $outputDir/$groupName.json and $outputDir/$groupName.csv');
  }
}

Future<List<Map<String, dynamic>>?> extractData(String targetName, String filePath) async {
  Map<String, dynamic> data;
  try {
    final content = await File(filePath).readAsString();
    data = jsonDecode(content) as Map<String, dynamic>;
  } on FileSystemException {
    print('Error: $filePath not found.');
    return null;
  } on FormatException {
    print('Error: Could not decode JSON in $filePath.');
    return null;
  }

  final tables = (data['r']?['dbiAccessorRes']?['tables'] as List?) ?? [];

  // Build lookup tables
  final subjects = <String, Map<String, dynamic>>{};
  final classes = <String, Map<String, dynamic>>{};
  final groups = <String, Map<String, dynamic>>{};
  final teachers = <String, Map<String, dynamic>>{};
  final periods = <String, Map<String, dynamic>>{};
  final lessons = <String, Map<String, dynamic>>{};
  final cards = <Map<String, dynamic>>[];

  for (final table in tables) {
    final tId = table['id'] as String?;
    final rows = (table['data_rows'] as List?) ?? [];

    switch (tId) {
      case 'subjects':
        for (final r in rows) subjects[r['id'] as String] = Map<String, dynamic>.from(r as Map);
      case 'classes':
        for (final r in rows) classes[r['id'] as String] = Map<String, dynamic>.from(r as Map);
      case 'groups':
        for (final r in rows) groups[r['id'] as String] = Map<String, dynamic>.from(r as Map);
      case 'teachers':
        for (final r in rows) teachers[r['id'] as String] = Map<String, dynamic>.from(r as Map);
      case 'periods':
        for (final r in rows) periods[r['id'] as String] = Map<String, dynamic>.from(r as Map);
      case 'lessons':
        for (final r in rows) lessons[r['id'] as String] = Map<String, dynamic>.from(r as Map);
      case 'cards':
        for (final r in rows) cards.add(Map<String, dynamic>.from(r as Map));
    }
  }

  const dayMapping = {
    '10000': 'Monday',
    '01000': 'Tuesday',
    '00100': 'Wednesday',
    '00010': 'Thursday',
    '00001': 'Friday',
  };
  final dayKeys = dayMapping.keys.toList();

  // Find matching class or group IDs
  final entityIds = <(String, String)>{};
  for (final entry in classes.entries) {
    if (entry.value['name'] == targetName) {
      entityIds.add(('class', entry.key));
    }
  }
  for (final entry in groups.entries) {
    if (entry.value['name'] == targetName) {
      entityIds.add(('group', entry.key));
    }
  }

  if (entityIds.isEmpty) {
    print('No class or group found with name: $targetName');
    return null;
  }

  // Find lesson IDs matching the entity
  final targetLessonIds = <String>{};
  for (final entry in lessons.entries) {
    final lesson = entry.value;
    for (final (etype, eid) in entityIds) {
      final classIds = (lesson['classids'] as List?)?.cast<String>() ?? [];
      final groupIds = (lesson['groupids'] as List?)?.cast<String>() ?? [];
      if ((etype == 'class' && classIds.contains(eid)) ||
          (etype == 'group' && groupIds.contains(eid))) {
        targetLessonIds.add(entry.key);
      }
    }
  }

  // Build schedule
  final schedule = <Map<String, dynamic>>[];

  for (final card in cards) {
    final lessonId = card['lessonid'] as String?;
    if (lessonId == null || !targetLessonIds.contains(lessonId)) continue;

    final dayStr = card['days'] as String? ?? '';
    final dayName = dayMapping[dayStr] ?? 'Unassigned';
    if (dayName == 'Unassigned') continue;

    final periodId = card['period'] as String? ?? '';
    final pData = periods[periodId] ?? {};

    final lesson = lessons[lessonId]!;
    final subjectId = lesson['subjectid'] as String? ?? '';
    final subject = subjects[subjectId]?['name'] as String? ?? 'N/A';

    final teacherIds = (lesson['teacherids'] as List?)?.cast<String>() ?? [];
    final teacherNames = teacherIds
        .map((tid) => teachers[tid]?['short'] as String? ?? 'Unknown')
        .toList();

    final groupIds = (lesson['groupids'] as List?)?.cast<String>() ?? [];
    final gNames = groupIds
        .map((gid) => groups[gid]?['name'] as String? ?? 'Unknown')
        .toList();
    final groupStr = gNames.isNotEmpty ? gNames.join(', ') : 'Visa klase';

    final startTime = pData['starttime'] as String? ?? '??:??';
    final endTime = pData['endtime'] as String? ?? '??:??';
    final timeStr = periodId.isNotEmpty ? '$startTime - $endTime' : '??:?? - ??:??';

    schedule.add({
      'Day': dayName,
      'day_idx': dayKeys.contains(dayStr) ? dayKeys.indexOf(dayStr) : 99,
      'No': periodId,
      'Time': timeStr,
      'Subgroup': groupStr,
      'Subject': subject,
      'Teacher': teacherNames.join(', '),
    });
  }

  // Sort by day then period
  schedule.sort((a, b) {
    final dayComp = (a['day_idx'] as int).compareTo(b['day_idx'] as int);
    if (dayComp != 0) return dayComp;
    final aNo = int.tryParse(a['No'] as String) ?? 99;
    final bNo = int.tryParse(b['No'] as String) ?? 99;
    return aNo.compareTo(bNo);
  });

  // Print formatted table
  print("\n--- Timetable for '$targetName' ---");
  const header =
      'Day         | No | Time            | Subgroup        | Subject                                       | Teacher';
  print(header);
  print('-' * header.length);

  String currentDay = '';
  for (final item in schedule) {
    final day = item['Day'] as String;
    if (day != currentDay) {
      if (currentDay.isNotEmpty) print('-' * header.length);
      currentDay = day;
    }
    print(
      '${day.padRight(11)} | '
      '${(item['No'] as String).padRight(2)} | '
      '${(item['Time'] as String).padRight(15)} | '
      '${(item['Subgroup'] as String).padRight(15)} | '
      '${(item['Subject'] as String).padRight(45)} | '
      '${item['Teacher']}',
    );
  }

  return schedule;
}