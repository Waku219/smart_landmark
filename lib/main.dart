import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
// material.dart re-exports foundation, so debugPrint is already available.
import 'package:flutter/material.dart';

import 'activity_screen.dart';
import 'add_landmark_screen.dart';
import 'background_service.dart';
import 'landmarks_list_screen.dart';
import 'map_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());

  // Deliberately started *after* the first frame is scheduled. Registering
  // WorkManager is a method-channel round trip; doing it before runApp added
  // to the visible startup stall (the "Skipped 253 frames" warning).
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_startBackgroundSync());
  });
}

Future<void> _startBackgroundSync() async {
  try {
    await initializeBackgroundService();
  } catch (e) {
    // WorkManager is Android/iOS only — on desktop or web this throws and
    // the rest of the app should still work.
    debugPrint('[main] background sync unavailable: $e');
    return;
  }

  // As soon as connectivity comes back, kick the sync worker immediately
  // instead of waiting for the next periodic (15 min) tick, so queued
  // offline visits and pending jobs resolve promptly.
  Connectivity().onConnectivityChanged.listen((results) {
    final isOnline = !results.contains(ConnectivityResult.none);
    debugPrint('[main] connectivity changed: online=$isOnline ($results)');
    if (isOnline) {
      runLandmarkSyncNow();
    }
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart Landmarks',
      home: const MainNavigation(),
    );
  }
}

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _selectedIndex = 0;

  /// Bumped whenever something changes the landmark set (e.g. adding one), so
  /// the Map and List tabs can reload instead of sitting on stale data —
  /// IndexedStack keeps them alive, so they'd otherwise never re-fetch.
  final ValueNotifier<int> _landmarksRevision = ValueNotifier<int>(0);

  /// Bumped when the Activity tab is opened, so it re-reads visit history.
  final ValueNotifier<int> _activityRevision = ValueNotifier<int>(0);

  late final List<Widget> _screens = [
    MapScreen(revision: _landmarksRevision),
    LandmarksListScreen(revision: _landmarksRevision),
    ActivityScreen(revision: _activityRevision),
    AddLandmarkScreen(onLandmarkCreated: () => _landmarksRevision.value++),
  ];

  final List<String> _titles = [
    'Map',
    'Landmarks',
    'Activity',
    'Add Landmark',
  ];

  @override
  void dispose() {
    _landmarksRevision.dispose();
    _activityRevision.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_selectedIndex]),
      ),

      // IndexedStack keeps all 4 tabs alive instead of destroying/rebuilding
      // their State each time you switch tabs (the previous body:
      // _screens[_selectedIndex] approach reset the map's viewport and
      // re-ran every screen's initState/network+DB fetch on every tap).
      body: IndexedStack(
        index: _selectedIndex,
        children: _screens,
      ),

      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,

        onTap: (index) {
          setState(() {
            _selectedIndex = index;
          });
          // Opening Activity should show the latest results the background
          // worker has written, without waiting for a pull-to-refresh.
          if (index == 2) {
            _activityRevision.value++;
          }
        },

        type: BottomNavigationBarType.fixed,

        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.map),
            label: 'Map',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.list),
            label: 'Landmarks',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history),
            label: 'Activity',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.add_location),
            label: 'Add',
          ),
        ],
      ),
    );
  }
}
