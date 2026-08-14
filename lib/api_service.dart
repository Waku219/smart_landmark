import 'dart:convert';
import 'package:http/http.dart' as http;
import 'landmark.dart';

class ApiService {
  static const String baseUrl = 'https://labs.anontech.info/cse489/exm3/api.php';
  static const String apiKey = '22299219'; // তোমার ID

  Future<List<Landmark>> getLandmarks() async {
    final url = Uri.parse('$baseUrl?action=get_landmarks&key=$apiKey');
    final response = await http.get(url);

    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((item) => Landmark.fromJson(item)).toList();
    } else {
      throw Exception('Failed to load landmarks: ${response.statusCode}');
    }
  }
}