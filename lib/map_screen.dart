import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'landmark.dart';
import 'api_service.dart';
import 'location_service.dart';
import 'visit_history_service.dart';
import 'db_helper.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final ApiService _apiService = ApiService();
  final LocationService _locationService = LocationService();
  final DBHelper _dbHelper = DBHelper();

  List<Landmark> _landmarks = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadLandmarks();
  }

  // Cache-first pattern
  Future<void> _loadLandmarks() async {
    final cached = await _dbHelper.getCachedLandmarks();

    // Show cached data first
    if (cached.isNotEmpty) {
      setState(() {
        _landmarks = cached;
        _isLoading = false;
      });
    }

    // Fetch fresh data from API
    try {
      final landmarks = await _apiService.getLandmarks();

      // Save fresh data to local database
      await _dbHelper.cacheLandmarks(landmarks);

      if (!mounted) return;

      setState(() {
        _landmarks = landmarks;
        _isLoading = false;
      });
    } catch (e) {
      // If there is no cached data, stop loading
      if (cached.isEmpty) {
        if (!mounted) return;

        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // Color based on landmark score
  Color _colorForScore(
      double score,
      double minScore,
      double maxScore,
      ) {
    if (maxScore == minScore) {
      return Colors.blue;
    }

    final ratio =
        (score - minScore) / (maxScore - minScore);

    return Color.lerp(
      Colors.red,
      Colors.green,
      ratio,
    ) ??
        Colors.blue;
  }

  // Show landmark details
  void _showLandmarkDetail(Landmark landmark) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(landmark.title),
        content: Text(
          'Score: ${landmark.score.toStringAsFixed(1)}\n'
              'Lat: ${landmark.lat}, Lon: ${landmark.lon}',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
            },
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _visitLandmark(landmark);
            },
            child: const Text('Visit'),
          ),
        ],
      ),
    );
  }

  // Visit landmark
  Future<void> _visitLandmark(Landmark landmark) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Getting your location...'),
      ),
    );

    try {
      // Get current location
      final position =
      await _locationService.getCurrentLocation();

      // Check internet connection
      final connectivity =
      await Connectivity().checkConnectivity();

      final isOffline =
      connectivity.contains(ConnectivityResult.none);

      // ------------------------------------------------
      // OFFLINE
      // ------------------------------------------------
      if (isOffline) {
        // Save visit request to pending queue
        await _dbHelper.addPendingVisit(
          landmark.id,
          landmark.title,
          position.latitude,
          position.longitude,
        );

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${landmark.title}: no internet, '
                  'visit queued for later.',
            ),
          ),
        );

        return;
      }

      // ------------------------------------------------
      // ONLINE
      // ------------------------------------------------

      // Submit visit directly to API
      final jobId = await _apiService.visitLandmark(
        landmark.id,
        position.latitude,
        position.longitude,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Visit submitted, job #$jobId processing...',
          ),
        ),
      );

      // Check job status
      _pollJobStatus(
        jobId,
        landmark.title,
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
        ),
      );
    }
  }

  // Poll job status
  Future<void> _pollJobStatus(
      int jobId,
      String landmarkTitle,
      ) async {
    const maxAttempts = 15;

    for (int i = 0; i < maxAttempts; i++) {
      await Future.delayed(
        const Duration(seconds: 2),
      );

      try {
        final status =
        await _apiService.getJobStatus(jobId);

        if (status['status'] == 'done') {
          final distance = status['distance'];

          // Save visit to visit history
          VisitHistoryService().addVisit(
            landmarkTitle,
            distance,
          );

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '$landmarkTitle visited! '
                      'Distance: '
                      '${distance.toStringAsFixed(2)}m',
                ),
              ),
            );
          }

          return;
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Polling error: $e',
              ),
            ),
          );
        }

        return;
      }
    }

    // Maximum attempts reached
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Job taking too long, giving up.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Loading state
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    // Calculate minimum and maximum score
    final scores =
    _landmarks.map((l) => l.score).toList();

    final minScore = scores.isEmpty
        ? 0.0
        : scores.reduce(
          (a, b) => a < b ? a : b,
    );

    final maxScore = scores.isEmpty
        ? 0.0
        : scores.reduce(
          (a, b) => a > b ? a : b,
    );

    return FlutterMap(
      options: const MapOptions(
        initialCenter: LatLng(
          23.6850,
          90.3563,
        ),
        initialZoom: 6.5,
      ),

      children: [
        // OpenStreetMap
        TileLayer(
          urlTemplate:
          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName:
          'com.example.smart_landmarks',
        ),

        // Landmark markers
        MarkerLayer(
          markers: _landmarks
          // Only active landmarks
              .where((l) => l.isActive)
              .map(
                (landmark) {
              return Marker(
                point: LatLng(
                  landmark.lat,
                  landmark.lon,
                ),
                width: 40,
                height: 40,
                child: GestureDetector(
                  onTap: () {
                    _showLandmarkDetail(
                      landmark,
                    );
                  },
                  child: Icon(
                    Icons.location_on,
                    color: _colorForScore(
                      landmark.score,
                      minScore,
                      maxScore,
                    ),
                    size: 40,
                  ),
                ),
              );
            },
          )
              .toList(),
        ),
      ],
    );
  }
}