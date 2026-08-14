import 'package:flutter/material.dart';
import 'api_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('API Test')),
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              final landmarks = await ApiService().getLandmarks();
              for (var l in landmarks) {
                print('${l.title} - score: ${l.score}');
              }
            },
            child: const Text('Fetch Landmarks'),
          ),
        ),
      ),
    );
  }
}