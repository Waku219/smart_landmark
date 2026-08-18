import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'api_service.dart';
import 'background_service.dart';
import 'db_helper.dart';
import 'landmark.dart';
import 'location_service.dart';

class MapScreen extends StatefulWidget {
  /// Bumped by the parent when the landmark set changes (e.g. one was added
  /// on the Add tab), so this screen reloads rather than showing stale data.
  final ValueNotifier<int>? revision;

  const MapScreen({super.key, this.revision});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final ApiService _apiService = ApiService();
  final LocationService _locationService = LocationService();
  final DBHelper _dbHelper = DBHelper();

  List<Landmark> _landmarks = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.revision?.addListener(_onRevisionChanged);
    _loadLandmarks();
  }

  @override
  void dispose() {
    widget.revision?.removeListener(_onRevisionChanged);
    super.dispose();
  }

  void _onRevisionChanged() => _loadLandmarks();

  // Cache-first pattern
  Future<void> _loadLandmarks() async {
    // The cache read is inside its own try. Previously it sat outside any
    // try/catch, so if opening the database threw, _loadLandmarks aborted
    // before ever clearing _isLoading and the screen span forever.
    List<Landmark> cached = const [];
    try {
      cached = await _dbHelper.getCachedLandmarks();
    } catch (e) {
      debugPrint('[MapScreen] could not read cache: $e');
    }

    // Show cached data first
    if (cached.isNotEmpty && mounted) {
      setState(() {
        _landmarks = cached;
        _isLoading = false;
        _error = null;
      });
    }

    // Fetch fresh data from API
    try {
      final landmarks = await _apiService.getLandmarks();

      // Merge with cache (preserves any landmarks soft-deleted locally,
      // since the server never returns deleted ones) and save.
      // Caching is best-effort — a DB problem must not discard landmarks we
      // successfully fetched and are able to display right now.
      List<Landmark> merged = landmarks;
      try {
        merged = await _dbHelper.mergeAndCacheLandmarks(landmarks);
      } catch (e) {
        debugPrint('[MapScreen] could not cache landmarks: $e');
      }

      if (!mounted) return;
      setState(() {
        _landmarks = merged;
        _isLoading = false;
        // Clear any stale error from a previous failed attempt, otherwise a
        // successful refresh still leaves the failure banner on screen.
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        // Always record it. build() decides how loud to be: a full error page
        // when there's no cache to fall back on, a thin "offline" banner over
        // the cached map when there is.
        _error = e.toString();
      });
    }
  }

  // Color based on landmark score
  Color _colorForScore(double score, double minScore, double maxScore) {
    if (maxScore == minScore) {
      return Colors.blue;
    }

    final ratio = ((score - minScore) / (maxScore - minScore)).clamp(0.0, 1.0);

    return Color.lerp(Colors.red, Colors.green, ratio) ?? Colors.blue;
  }

  // Show landmark details
  void _showLandmarkDetail(Landmark landmark) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(landmark.displayTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (landmark.imageUrl.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Image.network(
                  landmark.imageUrl,
                  height: 120,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.broken_image, size: 48),
                ),
              ),
            Text('Score: ${landmark.score.toStringAsFixed(1)}'),
            Text(
              'Lat: ${landmark.lat?.toStringAsFixed(5) ?? '—'}, '
              'Lon: ${landmark.lon?.toStringAsFixed(5) ?? '—'}',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
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

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // Visit landmark
  Future<void> _visitLandmark(Landmark landmark) async {
    _showSnack('Getting your location...');

    try {
      // Get current location
      final position = await _locationService.getCurrentLocation();

      // Check internet connection
      final connectivity = await Connectivity().checkConnectivity();
      final isOffline = connectivity.contains(ConnectivityResult.none);

      // ------------------------------------------------
      // OFFLINE
      // ------------------------------------------------
      if (isOffline) {
        // Save visit request to pending queue
        await _dbHelper.addPendingVisit(
          landmark.id,
          landmark.displayTitle,
          position.latitude,
          position.longitude,
        );

        _showSnack(
          '${landmark.displayTitle}: no internet — visit queued, it will sync '
          'automatically. See the Activity tab.',
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

      // Hand the job off to WorkManager instead of polling on the UI
      // thread: record it locally, then nudge the background worker to run
      // right away so it doesn't wait for the next periodic tick. The
      // worker persists the result to visit_history once get_job_status
      // reports "done", and the Activity screen reads from there.
      await _dbHelper.addPendingJob(jobId, landmark.displayTitle);
      runLandmarkSyncNow();

      _showSnack(
        'Visit submitted (job #$jobId). The distance will appear in the '
        'Activity tab once the server finishes.',
      );
    } catch (e) {
      _showSnack('Visit failed: $e');
    }
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 56, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Could not load landmarks',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () {
                setState(() {
                  _isLoading = true;
                  _error = null;
                });
                _loadLandmarks();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Loading state
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Nothing cached and the fetch failed — say so instead of rendering a
    // blank map with no explanation.
    if (_error != null && _landmarks.isEmpty) {
      return _buildErrorState();
    }

    // Only landmarks that are active AND have a coordinate latlong2 will
    // accept. Several rows in the shared database are unmappable — null
    // lat/lon, or values like lat 7659.097 — and LatLng asserts on those.
    final activeLandmarks =
        _landmarks.where((l) => l.isActive && l.hasValidLocation).toList();

    final unmappable =
        _landmarks.where((l) => l.isActive && !l.hasValidLocation).length;

    // Calculate minimum and maximum score across what's actually drawn
    final scores = activeLandmarks.map((l) => l.score).toList();
    final minScore =
        scores.isEmpty ? 0.0 : scores.reduce((a, b) => a < b ? a : b);
    final maxScore =
        scores.isEmpty ? 0.0 : scores.reduce((a, b) => a > b ? a : b);

    return Stack(
      children: [
        FlutterMap(
          options: const MapOptions(
            // Centred on Bangladesh, as the spec requires.
            initialCenter: LatLng(23.6850, 90.3563),
            initialZoom: 6.5,
          ),
          children: [
            // OpenStreetMap
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.smart_landmark',
            ),

            // Landmark markers, coloured low (red) -> high (green) by score
            MarkerLayer(
              markers: activeLandmarks.map((landmark) {
                return Marker(
                  // Safe: activeLandmarks is filtered on hasValidLocation.
                  point: LatLng(landmark.lat!, landmark.lon!),
                  width: 40,
                  height: 40,
                  // Anchor the pin's *tip* at the coordinate rather than its
                  // centre, so markers sit on the right spot.
                  alignment: Alignment.topCenter,
                  child: GestureDetector(
                    onTap: () => _showLandmarkDetail(landmark),
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
              }).toList(),
            ),
          ],
        ),

        // Showing cached data because the refresh failed.
        if (_error != null)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Material(
              color: Colors.orange.shade100,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  'Offline — showing cached landmarks',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),

        // Be explicit that some rows can't be drawn, rather than silently
        // showing fewer pins than the Landmarks tab lists.
        if (unmappable > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              color: Colors.black.withValues(alpha: 0.6),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Text(
                  '${activeLandmarks.length} shown · $unmappable hidden '
                  '(invalid coordinates)',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
