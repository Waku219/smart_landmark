import 'package:flutter/material.dart';

import 'api_service.dart';
import 'db_helper.dart';
import 'landmark.dart';

class LandmarksListScreen extends StatefulWidget {
  /// Bumped by the parent when the landmark set changes (e.g. one was added
  /// on the Add tab), so this screen reloads rather than showing stale data.
  final ValueNotifier<int>? revision;

  const LandmarksListScreen({super.key, this.revision});

  @override
  State<LandmarksListScreen> createState() => _LandmarksListScreenState();
}

class _LandmarksListScreenState extends State<LandmarksListScreen> {
  final ApiService _apiService = ApiService();
  final DBHelper _dbHelper = DBHelper();

  List<Landmark> _landmarks = [];

  bool _isLoading = true;
  String? _error;

  bool _sortDescending = true;
  bool _showDeleted = false;

  double _minScoreFilter = double.negativeInfinity;

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

  Future<void> _loadLandmarks() async {
    // Step 1: show cached data first (if any), for a fast UI.
    // Wrapped in its own try: if opening the database throws, this method
    // used to abort before clearing _isLoading, leaving a spinner forever.
    List<Landmark> cached = const [];
    try {
      cached = await _dbHelper.getCachedLandmarks();
    } catch (e) {
      debugPrint('[LandmarksList] could not read cache: $e');
    }

    if (cached.isNotEmpty && mounted) {
      setState(() {
        _landmarks = cached;
        _isLoading = false;
      });
    }

    // Step 2: try to fetch fresh data from the server.
    try {
      final landmarks = await _apiService.getLandmarks();

      // The server only ever returns active landmarks, so anything we've
      // locally soft-deleted (and haven't restored) needs to be preserved
      // in the cache rather than clobbered by this refresh — otherwise the
      // "show deleted" list would lose them on every pull-to-refresh.
      // Best-effort caching — a DB problem must not throw away landmarks we
      // just fetched successfully and could be showing.
      List<Landmark> merged = landmarks;
      try {
        merged = await _dbHelper.mergeAndCacheLandmarks(landmarks);
      } catch (e) {
        debugPrint('[LandmarksList] could not cache landmarks: $e');
      }

      if (!mounted) return;
      setState(() {
        _landmarks = merged;
        _isLoading = false;
        // Clearing this is essential: without it a single early failure left
        // _error set forever, and the error branch of build() had no
        // RefreshIndicator, so the screen was a permanent dead end.
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _deleteLandmark(Landmark landmark) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete landmark?'),
        content: Text('This will hide "${landmark.displayTitle}" from the list. '
            'You can restore it later.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _apiService.deleteLandmark(landmark.id);
      await _dbHelper.setLandmarkActive(landmark.id, false);
      if (!mounted) return;
      setState(() {
        _replaceLandmark(landmark, isActive: false);
      });
      _showSnack('${landmark.displayTitle} deleted.');
    } catch (e) {
      _showSnack('Could not delete: $e');
    }
  }

  Future<void> _restoreLandmark(Landmark landmark) async {
    try {
      await _apiService.restoreLandmark(landmark.id);
      await _dbHelper.setLandmarkActive(landmark.id, true);
      if (!mounted) return;
      setState(() {
        _replaceLandmark(landmark, isActive: true);
      });
      _showSnack('${landmark.displayTitle} restored.');
    } catch (e) {
      _showSnack('Could not restore: $e');
    }
  }

  void _replaceLandmark(Landmark landmark, {required bool isActive}) {
    final index = _landmarks.indexWhere((l) => l.id == landmark.id);
    if (index == -1) return;
    _landmarks[index] = landmark.copyWith(isActive: isActive);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showFilterDialog() {
    final controller = TextEditingController(
      text: _minScoreFilter == double.negativeInfinity
          ? ''
          : _minScoreFilter.toString(),
    );

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Filter by minimum score'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: const InputDecoration(
              hintText: 'e.g. -500000',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _minScoreFilter = double.negativeInfinity;
                });
                Navigator.pop(dialogContext);
              },
              child: const Text('Clear'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  _minScoreFilter = double.tryParse(controller.text) ??
                      double.negativeInfinity;
                });
                Navigator.pop(dialogContext);
              },
              child: const Text('Apply'),
            ),
          ],
        );
      },
      // The controller belongs to the dialog, not to this State, so dispose it
      // when the dialog closes instead of leaking one per open.
    ).then((_) => controller.dispose());
  }

  Widget _buildErrorState() {
    return ListView(
      // Must be scrollable for RefreshIndicator to accept a pull gesture.
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 100),
        const Icon(Icons.cloud_off, size: 56, color: Colors.grey),
        const SizedBox(height: 16),
        const Center(
          child: Text(
            'Could not load landmarks',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: FilledButton.icon(
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
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // No cache to fall back on — show the failure, but keep it inside a
    // RefreshIndicator and give it an explicit Retry button so the user is
    // never stranded.
    if (_error != null && _landmarks.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadLandmarks,
        child: _buildErrorState(),
      );
    }

    final deletedList = _landmarks.where((l) => !l.isActive).toList();

    final visibleList = (_showDeleted ? deletedList : _landmarks)
        .where(
          (l) => (_showDeleted || l.isActive) && l.score >= _minScoreFilter,
        )
        .toList()
      ..sort(
        (a, b) => _sortDescending
            ? b.score.compareTo(a.score)
            : a.score.compareTo(b.score),
      );

    return Column(
      children: [
        if (_error != null)
          Container(
            width: double.infinity,
            color: Colors.orange.shade100,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: const Text(
              'Offline — showing cached landmarks',
              textAlign: TextAlign.center,
            ),
          ),

        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  _sortDescending ? Icons.arrow_downward : Icons.arrow_upward,
                ),
                tooltip: _sortDescending
                    ? 'Sorted high to low'
                    : 'Sorted low to high',
                onPressed: () {
                  setState(() {
                    _sortDescending = !_sortDescending;
                  });
                },
              ),

              const Text('Sort by score'),

              const Spacer(),

              if (_minScoreFilter != double.negativeInfinity)
                Chip(
                  label: Text('≥ ${_minScoreFilter.toStringAsFixed(0)}'),
                  onDeleted: () {
                    setState(() {
                      _minScoreFilter = double.negativeInfinity;
                    });
                  },
                ),

              if (deletedList.isNotEmpty)
                TextButton.icon(
                  icon: Icon(
                    _showDeleted ? Icons.list : Icons.delete_outline,
                  ),
                  label: Text(
                    _showDeleted
                        ? 'Show active'
                        : 'Deleted (${deletedList.length})',
                  ),
                  onPressed: () {
                    setState(() {
                      _showDeleted = !_showDeleted;
                    });
                  },
                ),

              IconButton(
                icon: const Icon(Icons.filter_list),
                tooltip: 'Filter by minimum score',
                onPressed: _showFilterDialog,
              ),
            ],
          ),
        ),

        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadLandmarks,
            child: visibleList.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 100),
                      Center(
                        child: Text(
                          _showDeleted
                              ? 'No deleted landmarks.'
                              : 'No landmarks found.',
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    itemCount: visibleList.length,
                    itemBuilder: (context, index) {
                      final landmark = visibleList[index];

                      return ListTile(
                        leading: landmark.imageUrl.isNotEmpty
                            ? Image.network(
                                landmark.imageUrl,
                                width: 56,
                                height: 56,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) =>
                                    const Icon(Icons.broken_image, size: 40),
                              )
                            : const Icon(Icons.place, size: 40),

                        title: Text(landmark.displayTitle),

                        subtitle: Text(
                          'Score: ${landmark.score.toStringAsFixed(1)}',
                        ),

                        trailing: _showDeleted
                            ? IconButton(
                                icon: const Icon(Icons.restore),
                                tooltip: 'Restore',
                                onPressed: () => _restoreLandmark(landmark),
                              )
                            : IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Delete',
                                onPressed: () => _deleteLandmark(landmark),
                              ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
