import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'landmark.dart';

/// Thrown for any non-200 response from the exam API.
///
/// Carrying the status code matters for the background worker: a 403
/// (invalid_or_expired_key) or a 404 (landmark / job doesn't exist) will
/// *never* succeed no matter how many times we retry, so those rows must be
/// dropped from the queue. A 5xx or a socket error is transient and should be
/// retried. Without the status code the worker can only see "some exception"
/// and ends up polling a dead job forever.
class ApiException implements Exception {
  final int statusCode;
  final String action;
  final String body;

  ApiException(this.statusCode, this.action, this.body);

  /// True when retrying is pointless.
  bool get isPermanent => statusCode == 403 || statusCode == 404;

  @override
  String toString() =>
      'ApiException[$action] HTTP $statusCode: ${body.length > 200 ? '${body.substring(0, 200)}…' : body}';
}

class ApiService {
  static const String baseUrl =
      'https://labs.anontech.info/cse489/exm3/api.php';

  static const String apiKey = '22299219';

  /// Every network call is logged so failures are visible in `flutter run`
  /// output — including calls made from the WorkManager background isolate,
  /// which is otherwise completely silent.
  static void _log(String message) => debugPrint('[ApiService] $message');

  static const Duration _timeout = Duration(seconds: 20);

  // Get all landmarks
  Future<List<Landmark>> getLandmarks() async {
    final url = Uri.parse('$baseUrl?action=get_landmarks&key=$apiKey');
    _log('GET get_landmarks');

    final response = await http.get(url).timeout(_timeout);

    if (response.statusCode != 200) {
      _log('get_landmarks failed: HTTP ${response.statusCode}');
      throw ApiException(response.statusCode, 'get_landmarks', response.body);
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      _log('get_landmarks returned a non-list body: ${response.body}');
      throw ApiException(response.statusCode, 'get_landmarks', response.body);
    }

    // parseList drops malformed rows rather than throwing. The shared class
    // database contains rows with null lat/lon/title, and one bad row used to
    // take down the entire list with a FormatException.
    final landmarks = Landmark.parseList(decoded);
    _log('get_landmarks ok: ${landmarks.length}/${decoded.length} usable');
    return landmarks;
  }

  // Visit a landmark — returns the job_id to poll with getJobStatus.
  Future<int> visitLandmark(int landmarkId, double lat, double lon) async {
    final url = Uri.parse('$baseUrl?action=visit_landmark&key=$apiKey');
    _log('POST visit_landmark landmark=$landmarkId lat=$lat lon=$lon');

    final response = await http
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'landmark_id': landmarkId,
            'user_lat': lat,
            'user_lon': lon,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      _log('visit_landmark failed: HTTP ${response.statusCode}');
      throw ApiException(response.statusCode, 'visit_landmark', response.body);
    }

    final data = jsonDecode(response.body);

    // The API is inconsistent about numeric types — create_landmark returns
    // {"id": "11"} as a *string*. Parsing via toString() means a quoted
    // job_id can't blow up with a dynamic-to-int TypeError.
    final jobId = int.parse(data['job_id'].toString());
    _log('visit_landmark ok: job_id=$jobId status=${data['status']}');
    return jobId;
  }

  // Get job status
  Future<Map<String, dynamic>> getJobStatus(int jobId) async {
    final url = Uri.parse(
      '$baseUrl?action=get_job_status&key=$apiKey&job_id=$jobId',
    );
    _log('GET get_job_status job_id=$jobId');

    final response = await http.get(url).timeout(_timeout);

    if (response.statusCode != 200) {
      _log('get_job_status($jobId) failed: HTTP ${response.statusCode}');
      throw ApiException(response.statusCode, 'get_job_status', response.body);
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    _log('get_job_status($jobId) -> ${data['status']} distance=${data['distance']}');
    return data;
  }

  /// Creates a landmark. Must be multipart/form-data — the server reads the
  /// image out of PHP's $_FILES, which is empty for a raw JSON body.
  ///
  /// [imageFile] is optional: the API marks the image field optional, and
  /// forcing one blocks the user from adding a landmark they have no photo for.
  Future<int?> createLandmark({
    required String title,
    required double lat,
    required double lon,
    File? imageFile,
  }) async {
    final url = Uri.parse('$baseUrl?action=create_landmark&key=$apiKey');
    _log('POST create_landmark title="$title" hasImage=${imageFile != null}');

    final request = http.MultipartRequest('POST', url);
    request.fields['title'] = title;
    request.fields['lat'] = lat.toString();
    request.fields['lon'] = lon.toString();

    if (imageFile != null) {
      final bytes = await imageFile.length();
      // The API rejects anything over 2MB. Fail here with a message the user
      // can act on rather than letting the server return an opaque error.
      if (bytes > 2 * 1024 * 1024) {
        throw Exception(
          'Image is ${(bytes / 1024 / 1024).toStringAsFixed(1)}MB — the server '
          'limit is 2MB. Pick a smaller photo.',
        );
      }
      request.files.add(
        await http.MultipartFile.fromPath('image', imageFile.path),
      );
    }

    final streamedResponse = await request.send().timeout(_timeout);
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      _log('create_landmark failed: HTTP ${response.statusCode}');
      throw ApiException(response.statusCode, 'create_landmark', response.body);
    }

    // Response is {"id": "11"} — note the id comes back as a string.
    try {
      final data = jsonDecode(response.body);
      final id = int.tryParse(data['id'].toString());
      _log('create_landmark ok: id=$id');
      return id;
    } catch (_) {
      _log('create_landmark ok (unparseable body: ${response.body})');
      return null;
    }
  }

  // Soft-delete a landmark
  Future<void> deleteLandmark(int id) async {
    final url = Uri.parse('$baseUrl?action=delete_landmark&key=$apiKey');
    _log('POST delete_landmark id=$id');

    final response = await http.post(url, body: {'id': id.toString()}).timeout(
      _timeout,
    );

    if (response.statusCode != 200) {
      _log('delete_landmark failed: HTTP ${response.statusCode}');
      throw ApiException(response.statusCode, 'delete_landmark', response.body);
    }
  }

  // Restore a previously soft-deleted landmark
  Future<void> restoreLandmark(int id) async {
    final url = Uri.parse('$baseUrl?action=restore_landmark&key=$apiKey');
    _log('POST restore_landmark id=$id');

    final response = await http.post(url, body: {'id': id.toString()}).timeout(
      _timeout,
    );

    if (response.statusCode != 200) {
      _log('restore_landmark failed: HTTP ${response.statusCode}');
      throw ApiException(
        response.statusCode,
        'restore_landmark',
        response.body,
      );
    }
  }
}
