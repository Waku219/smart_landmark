// Replaces the default Flutter counter smoke test, which referenced a counter
// and an Icons.add button this app has never had — it failed on every run.
//
// These are plain unit tests over the parsing/error logic, deliberately with
// no widget pumping: MyApp's first frame builds MapScreen, whose initState
// opens sqflite, which is unavailable in the test VM.
//
// The malformed-input cases below are not hypothetical. The exam API is one
// shared database the whole class writes into, and these exact rows are live
// in it: ids 108/115/116/122 have null lat/lon/title, and id 128 is
// {"title":"bushra","lat":7659.097,"lon":6547.93}.

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_landmark/api_service.dart';
import 'package:smart_landmark/landmark.dart';

void main() {
  group('Landmark.tryFromJson', () {
    test('parses a well-formed landmark from the API', () {
      final landmark = Landmark.tryFromJson({
        'id': 1,
        'title': "Cox's Bazar Sea Beach",
        'lat': 21.4272,
        'lon': 92.0058,
        'image': 'uploads/1786430640_5629.jpg',
        'is_active': 1,
        'visit_count': 49,
        'score': 27.8,
      })!;

      expect(landmark.id, 1);
      expect(landmark.title, "Cox's Bazar Sea Beach");
      expect(landmark.lat, closeTo(21.4272, 1e-6));
      expect(landmark.score, closeTo(27.8, 1e-6));
      expect(landmark.isActive, isTrue);
      expect(landmark.hasValidLocation, isTrue);
      expect(
        landmark.imageUrl,
        'https://labs.anontech.info/cse489/exm3/uploads/1786430640_5629.jpg',
      );
    });

    test('null lat/lon/title do not throw (ids 108/115/116/122)', () {
      // This is the regression that broke the whole app: the old parser did
      // double.parse(json['lat'].toString()) -> double.parse("null") ->
      // FormatException, which took down all 175 landmarks.
      final landmark = Landmark.tryFromJson({
        'id': 108,
        'title': null,
        'lat': null,
        'lon': null,
        'image': '',
        'is_active': 1,
      })!;

      expect(landmark.id, 108);
      expect(landmark.lat, isNull);
      expect(landmark.lon, isNull);
      expect(landmark.hasValidLocation, isFalse);
      expect(landmark.displayTitle, 'Untitled landmark');
      expect(landmark.score, 0);
      expect(landmark.imageUrl, '');
    });

    test('out-of-range coordinates are flagged, not fed to LatLng', () {
      // latlong2 asserts -90..90 / -180..180, so id 128 would crash the map.
      final bushra = Landmark.tryFromJson({
        'id': 128,
        'title': 'bushra',
        'lat': 7659.097,
        'lon': 6547.93,
        'image': '',
        'is_active': 1,
        'score': 0,
      })!;
      expect(bushra.hasValidLocation, isFalse);

      final seaa = Landmark.tryFromJson({
        'id': 58,
        'title': 'seaa',
        'lat': 41.22,
        'lon': 1688.236,
        'image': '',
        'is_active': 1,
        'score': 0,
      })!;
      expect(seaa.hasValidLocation, isFalse);
    });

    test('an empty title still gets a readable label (id 100)', () {
      final landmark = Landmark.tryFromJson({
        'id': 100,
        'title': '',
        'lat': 0,
        'lon': 0,
        'image': '',
        'is_active': 1,
      })!;

      expect(landmark.displayTitle, 'Untitled landmark');
      // 0,0 is in range, so it is technically mappable.
      expect(landmark.hasValidLocation, isTrue);
    });

    test('tolerates the API returning numbers as strings', () {
      // create_landmark returns {"id": "11"} — a string — so the parser has
      // to cope with quoted numerics anywhere.
      final landmark = Landmark.tryFromJson({
        'id': '11',
        'title': 'Quoted numbers',
        'lat': '23.7',
        'lon': '90.4',
        'image': 'uploads/x.jpg',
        'is_active': true,
        'score': '5.5',
      })!;

      expect(landmark.id, 11);
      expect(landmark.lat, closeTo(23.7, 1e-6));
      expect(landmark.score, closeTo(5.5, 1e-6));
      expect(landmark.isActive, isTrue);
    });

    test('a row with no usable id is rejected', () {
      expect(Landmark.tryFromJson({'title': 'no id'}), isNull);
      expect(Landmark.tryFromJson({'id': null, 'title': 'x'}), isNull);
    });

    test('round-trips through the sqflite map form', () {
      final original = Landmark.tryFromJson({
        'id': 7,
        'title': 'Round trip',
        'lat': 22.5,
        'lon': 91.0,
        'image': 'uploads/y.jpg',
        'is_active': 1,
        'score': 12.25,
      })!;

      final restored = Landmark.fromMap(original.toMap());

      expect(restored.id, original.id);
      expect(restored.title, original.title);
      expect(restored.lat, original.lat);
      expect(restored.lon, original.lon);
      expect(restored.score, original.score);
      expect(restored.isActive, original.isActive);
    });

    test('a null position survives the sqflite round trip', () {
      final original = Landmark.tryFromJson({
        'id': 115,
        'title': null,
        'lat': null,
        'lon': null,
        'image': '',
        'is_active': 1,
      })!;

      final restored = Landmark.fromMap(original.toMap());
      expect(restored.lat, isNull);
      expect(restored.hasValidLocation, isFalse);
    });
  });

  group('Landmark.parseList', () {
    test('drops bad rows instead of failing the whole response', () {
      final parsed = Landmark.parseList([
        {'id': 1, 'title': 'Good', 'lat': 23.7, 'lon': 90.4, 'score': 5},
        {'id': 108, 'title': null, 'lat': null, 'lon': null},
        {'id': 128, 'title': 'bushra', 'lat': 7659.097, 'lon': 6547.93},
        {'title': 'no id at all'},
        'not even an object',
      ]);

      // The two junk-but-identifiable rows survive; only the id-less row and
      // the non-object are dropped.
      expect(parsed.map((l) => l.id), [1, 108, 128]);
      expect(parsed.where((l) => l.hasValidLocation).map((l) => l.id), [1]);
    });
  });

  group('ApiException', () {
    test('403 and 404 are permanent so the worker stops retrying', () {
      expect(
        ApiException(403, 'get_landmarks', '{"error":"invalid_or_expired_key"}')
            .isPermanent,
        isTrue,
      );
      expect(
        ApiException(404, 'get_job_status', '{"error":"job_not_found"}')
            .isPermanent,
        isTrue,
      );
    });

    test('server errors are transient so the worker keeps retrying', () {
      expect(ApiException(500, 'visit_landmark', '').isPermanent, isFalse);
      expect(ApiException(502, 'visit_landmark', '').isPermanent, isFalse);
    });
  });
}
