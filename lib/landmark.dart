import 'package:flutter/foundation.dart';

/// A landmark as returned by get_landmarks.
///
/// IMPORTANT: the exam API is a single shared database that every student in
/// the class writes into, so the payload contains a lot of malformed rows —
/// entries with `"lat":null,"lon":null,"title":null`, empty titles, and
/// coordinates such as `lat: 7659.097, lon: 6547.93`. Requirement 1 ("handle
/// dynamic data correctly") and Requirement 7 ("app must not crash if data
/// changes") are precisely about surviving that, so nothing in this class is
/// allowed to throw on bad input.
///
/// [lat] and [lon] are nullable on purpose: a row can legitimately have no
/// usable position. Such a landmark still belongs in the list (it has a title
/// and a score) but must be left off the map.
class Landmark {
  final int id;
  final String title;
  final double? lat;
  final double? lon;
  final String image;
  final double score;
  final bool isActive;

  const Landmark({
    required this.id,
    required this.title,
    required this.lat,
    required this.lon,
    required this.image,
    required this.score,
    required this.isActive,
  });

  /// True only when this landmark can actually be placed on a map.
  ///
  /// latlong2's LatLng asserts that latitude is within -90..90 and longitude
  /// within -180..180. Feeding it id 128 (lat 7659.097) throws in debug mode,
  /// so the map layer filters on this instead.
  bool get hasValidLocation {
    final la = lat;
    final lo = lon;
    return la != null &&
        lo != null &&
        la.isFinite &&
        lo.isFinite &&
        la >= -90 &&
        la <= 90 &&
        lo >= -180 &&
        lo <= 180;
  }

  String get displayTitle => title.isEmpty ? 'Untitled landmark' : title;

  String get imageUrl =>
      image.isNotEmpty ? 'https://labs.anontech.info/cse489/exm3/$image' : '';

  /// Lenient parser. Returns null only when the row has no usable id, which
  /// is the one field we genuinely cannot work without (it's the primary key
  /// locally and the identifier for visit/delete/restore).
  static Landmark? tryFromJson(Map<String, dynamic> json) {
    final id = _asInt(json['id']);
    if (id == null) {
      debugPrint('[Landmark] skipping row with unusable id: $json');
      return null;
    }

    return Landmark(
      id: id,
      title: (json['title'] ?? '').toString().trim(),
      // Null / "" / unparseable all collapse to null rather than throwing.
      lat: _asDouble(json['lat']),
      lon: _asDouble(json['lon']),
      image: (json['image'] ?? '').toString(),
      score: _asDouble(json['score']) ?? 0.0,
      // is_active arrives as 1/0, true/false, or "1" depending on the row.
      isActive: _asBool(json['is_active']),
    );
  }

  /// Parses a whole response, dropping unusable rows instead of letting one
  /// bad entry take down the entire list.
  static List<Landmark> parseList(List<dynamic> data) {
    final landmarks = <Landmark>[];
    var skipped = 0;

    for (final item in data) {
      if (item is! Map) {
        skipped++;
        continue;
      }
      final landmark = tryFromJson(Map<String, dynamic>.from(item));
      if (landmark == null) {
        skipped++;
      } else {
        landmarks.add(landmark);
      }
    }

    if (skipped > 0) {
      debugPrint('[Landmark] skipped $skipped malformed row(s) of ${data.length}');
    }
    return landmarks;
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'lat': lat,
      'lon': lon,
      'image': image,
      'score': score,
      'isActive': isActive ? 1 : 0,
    };
  }

  factory Landmark.fromMap(Map<String, dynamic> map) {
    return Landmark(
      id: (map['id'] as num).toInt(),
      title: (map['title'] ?? '').toString(),
      lat: _asDouble(map['lat']),
      lon: _asDouble(map['lon']),
      image: (map['image'] ?? '').toString(),
      score: _asDouble(map['score']) ?? 0.0,
      isActive: map['isActive'] == 1,
    );
  }

  Landmark copyWith({bool? isActive}) => Landmark(
        id: id,
        title: title,
        lat: lat,
        lon: lon,
        image: image,
        score: score,
        isActive: isActive ?? this.isActive,
      );

  // --- tolerant primitive coercion ---

  static int? _asInt(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString().trim());
  }

  /// Returns null instead of throwing. `double.parse(null.toString())` — i.e.
  /// parsing the literal string "null" — is what broke the whole landmark
  /// list, because four rows in the shared database have a null lat/lon.
  static double? _asDouble(Object? value) {
    if (value == null) return null;
    if (value is double) return value.isFinite ? value : null;
    if (value is num) return value.toDouble();
    final parsed = double.tryParse(value.toString().trim());
    if (parsed == null || !parsed.isFinite) return null;
    return parsed;
  }

  static bool _asBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value?.toString().toLowerCase().trim();
    return text == '1' || text == 'true';
  }
}
