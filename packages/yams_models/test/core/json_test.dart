import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

enum _Color { red, darkBlue, unknown }

void main() {
  group('readInt', () {
    test('accepts ints, whole doubles and numeric strings', () {
      expect(readInt(42), 42);
      expect(readInt(42.0), 42);
      expect(readInt('42'), 42);
      expect(readInt(' -7 '), -7);
      expect(readInt('42.0'), 42);
    });
    test('rejects fractions and other types', () {
      expect(readInt(42.5), isNull);
      expect(readInt('42.5'), isNull);
      expect(readInt(double.nan), isNull);
      expect(readInt(double.infinity), isNull);
      expect(readInt('abc'), isNull);
      expect(readInt('0x1F'), isNull);
      expect(readInt(true), isNull);
      expect(readInt(null), isNull);
      expect(readInt(const [1]), isNull);
    });
  });

  test('readDouble', () {
    expect(readDouble(1), 1.0);
    expect(readDouble(1.5), 1.5);
    expect(readDouble('2.25'), 2.25);
    expect(readDouble('x'), isNull);
    expect(readDouble('NaN'), isNull);
    expect(readDouble('Infinity'), isNull);
    expect(readDouble(double.infinity), isNull);
    expect(readDouble(null), isNull);
  });

  test('readString', () {
    expect(readString('a'), 'a');
    expect(readString(''), '');
    expect(readString(5), '5');
    expect(readString(true), 'true');
    expect(readString(null), isNull);
    expect(readString(const {'a': 1}), isNull);
  });

  test('readBool', () {
    expect(readBool(true), isTrue);
    expect(readBool(false), isFalse);
    expect(readBool('true'), isTrue);
    expect(readBool('False'), isFalse);
    expect(readBool('yes'), isNull);
    expect(readBool(1), isNull);
    expect(readBool(null), isNull);
  });

  group('readInstant', () {
    test('parses UTC instants with and without fractions', () {
      expect(
        readInstant('2026-11-08T07:41:48Z'),
        DateTime.utc(2026, 11, 8, 7, 41, 48),
      );
      expect(
        readInstant('2026-11-08T07:41:48.123Z'),
        DateTime.utc(2026, 11, 8, 7, 41, 48, 123),
      );
    });
    test('converts offsets to UTC', () {
      final d = readInstant('2026-11-08T09:41:48+02:00')!;
      expect(d.isUtc, isTrue);
      expect(d, DateTime.utc(2026, 11, 8, 7, 41, 48));
    });
    test('treats strings without a zone as UTC', () {
      final d = readInstant('2026-11-08T07:41:48')!;
      expect(d.isUtc, isTrue);
      expect(d, DateTime.utc(2026, 11, 8, 7, 41, 48));
      // 02:30 on the last Sunday of March does not exist in most European
      // zones; the value must not be shifted by the local time zone.
      expect(
        readInstant('2026-03-29T02:30:00.250'),
        DateTime.utc(2026, 3, 29, 2, 30, 0, 250),
      );
      expect(readInstant('2026-11-08'), DateTime.utc(2026, 11, 8));
    });
    test('returns null for the .NET sentinel and garbage', () {
      expect(readInstant('0001-01-01T00:00:00Z'), isNull);
      expect(readInstant('0001-01-01T00:00:00'), isNull);
      expect(readInstant('not a date'), isNull);
      expect(readInstant(12345), isNull);
      expect(readInstant(null), isNull);
    });
  });

  test('instantToJson writes UTC with Z and drops zero fractions', () {
    expect(
      instantToJson(DateTime.utc(2026, 11, 8, 7, 41, 48)),
      '2026-11-08T07:41:48Z',
    );
    expect(
      instantToJson(DateTime.utc(2026, 11, 8, 7, 41, 48, 250)),
      '2026-11-08T07:41:48.250Z',
    );
    expect(
      instantToJson(DateTime.utc(2026, 11, 8, 7, 41, 48, 0, 5)),
      '2026-11-08T07:41:48.000005Z',
    );
    final local = DateTime.utc(2026, 11, 8, 7).toLocal();
    expect(instantToJson(local), '2026-11-08T07:00:00Z');
    expect(optionalInstantToJson(null), isNull);
    final d = DateTime.utc(2026, 1, 2, 3, 4, 5, 6);
    expect(readInstant(instantToJson(d)), d);
  });

  test('readMap', () {
    expect(readMap(<String, Object?>{'a': 1}), {'a': 1});
    expect(readMap(<Object?, Object?>{'a': 1}), {'a': 1});
    expect(readMap(<Object?, Object?>{1: 1}), isNull);
    expect(readMap(const [1]), isNull);
    expect(readMap(null), isNull);
  });

  test('readList decodes maps, skips other elements, empty on non-lists', () {
    final out = readList<int>([
      {'v': 1},
      'x',
      null,
      {'v': 2},
    ], (j) => readInt(j['v'])!);
    expect(out, [1, 2]);
    expect(readList<int>(null, (j) => 0), isEmpty);
    expect(readList<int>('nope', (j) => 0), isEmpty);
  });

  test('readStringList and readIntList', () {
    expect(readStringList(['a', 1, null, 'b']), ['a', '1', 'b']);
    expect(readStringList(null), isEmpty);
    expect(readIntList([1, '2', 3.0, 'x', null]), [1, 2, 3]);
    expect(readIntList('1'), isEmpty);
  });

  test('readEnum never throws and falls back to unknown', () {
    expect(readEnum('red', _Color.values, _Color.unknown), _Color.red);
    expect(
      readEnum('darkBlue', _Color.values, _Color.unknown),
      _Color.darkBlue,
    );
    expect(readEnum('DarkBlue', _Color.values, _Color.unknown), _Color.unknown);
    expect(readEnum('purple', _Color.values, _Color.unknown), _Color.unknown);
    expect(readEnum(3, _Color.values, _Color.unknown), _Color.unknown);
    expect(readEnum(null, _Color.values, _Color.unknown), _Color.unknown);
    expect(readOptionalEnum(null, _Color.values), isNull);
    expect(readOptionalEnum('purple', _Color.values), isNull);
  });

  test('compactJson drops null values only', () {
    expect(compactJson({'a': 1, 'b': null, 'c': false, 'd': const <int>[]}), {
      'a': 1,
      'c': false,
      'd': const <int>[],
    });
  });

  test('req throws a FormatException naming the field', () {
    expect(req(1, 'a'), 1);
    expect(
      () => req<int>(null, 'createdAt'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('createdAt'),
        ),
      ),
    );
  });
}
