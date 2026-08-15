import 'dart:convert';
import 'package:http/http.dart' as http;
import 'landmark.dart';
import 'dart:io';

class ApiService {
  static const String baseUrl =
      'https://labs.anontech.info/cse489/exm3/api.php';

  static const String apiKey = '22299219';

  // Get all landmarks
  Future<List<Landmark>> getLandmarks() async {
    final url =
    Uri.parse('$baseUrl?action=get_landmarks&key=$apiKey');

    final response = await http.get(url);

    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);

      return data
          .map((item) => Landmark.fromJson(item))
          .toList();
    } else {
      throw Exception(
        'Failed to load landmarks: ${response.statusCode}',
      );
    }
  }

  // Visit a landmark
  Future<int> visitLandmark(
      int landmarkId, double lat, double lon) async {
    final url =
    Uri.parse('$baseUrl?action=visit_landmark&key=$apiKey');

    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'landmark_id': landmarkId,
        'user_lat': lat,
        'user_lon': lon,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['job_id'];
    } else {
      throw Exception(
        'Failed to visit landmark: ${response.statusCode}',
      );
    }
  }

  // Get job status
  Future<Map<String, dynamic>> getJobStatus(int jobId) async {
    final url = Uri.parse(
      '$baseUrl?action=get_job_status&key=$apiKey&job_id=$jobId',
    );

    final response = await http.get(url);

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception(
        'Failed to get job status: ${response.statusCode}',
      );
    }
  }
  Future<void> createLandmark({
    required String title,
    required double lat,
    required double lon,
    required File imageFile,
  }) async {
    final url = Uri.parse('$baseUrl?action=create_landmark&key=$apiKey');
    final request = http.MultipartRequest('POST', url);

    request.fields['title'] = title;
    request.fields['lat'] = lat.toString();
    request.fields['lon'] = lon.toString();
    request.files.add(
      await http.MultipartFile.fromPath('image', imageFile.path),
    );

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception('Failed to create landmark: ${response.statusCode}');
    }
  }
}