// ignore_for_file: implementation_imports, invalid_use_of_visible_for_testing_member

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:isar/isar.dart';
import 'package:isar_test/src/init_native.dart'
    if (dart.library.html) 'package:isar_test/src/init_web.dart';
import 'package:isar_test/src/sync_async_helper.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:test_api/src/backend/invoker.dart';

const bool kIsWeb = identical(0, 0.0);

final testErrors = <String>[];
int testCount = 0;

var _setUp = false;
Future<void> _prepareTest() async {
  if (!_setUp) {
    await init();
    _setUp = true;
  }
}

@isTest
void isarTest(
  String name,
  dynamic Function() body, {
  Timeout? timeout,
  bool skip = false,
  bool syncOnly = false,
}) {
  void runTest(bool syncTest) {
    final testName = syncTest ? '$name SYNC' : name;
    test(
      testName,
      () async {
        await runZoned(
          () async {
            try {
              await _prepareTest();
              await body();
              testCount++;
            } catch (e) {
              testErrors.add('$testName: $e');
              rethrow;
            }
          },
          zoneValues: {
            #syncTest: syncTest,
          },
        );
      },
      timeout: timeout ?? const Timeout(Duration(minutes: 10)),
      skip: skip,
    );
  }

  if (!syncOnly) {
    runTest(false);
  }

  if (!kIsWeb) {
    runTest(true);
  }
}

@isTest
void isarTestVm(String name, dynamic Function() body) {
  isarTest(name, body, skip: kIsWeb);
}

@isTest
void isarTestWeb(String name, dynamic Function() body) {
  isarTest(name, body, skip: !kIsWeb);
}

@isTest
void isarTestSync(String name, void Function() body) {
  isarTest(name, body, skip: kIsWeb, syncOnly: true);
}

String getRandomName() {
  final random = Random().nextInt(pow(2, 32) as int).toString();
  return '${random}_tmp';
}

String? testTempPath;
Future<Isar> openTempIsar(
  List<CollectionSchema<dynamic>> schemas, {
  String? name,
  String? directory,
  CompactCondition? compactOnLaunch,
}) async {
  await _prepareTest();
  if (!kIsWeb && directory == null && testTempPath == null) {
    final dartToolDir = path.join(Directory.current.path, '.dart_tool');
    testTempPath = path.join(dartToolDir, 'test', 'tmp');
    await Directory(testTempPath!).create(recursive: true);
  }

  final isar = await tOpen(
    schemas: schemas,
    name: name ?? getRandomName(),
    directory: directory ?? testTempPath,
    compactOnLaunch: compactOnLaunch,
  );

  if (Invoker.current != null) {
    addTearDown(() async {
      if (isar.isOpen) {
        await isar.close(deleteFromDisk: true);
      }
    });
  }

  if (!kIsWeb) await isar.verify();
  return isar;
}
