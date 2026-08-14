import 'package:flutter/material.dart';
import 'landmarks_list_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Landmarks')),
        body: const LandmarksListScreen(),
      ),
    );
  }
}