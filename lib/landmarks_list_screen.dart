import 'package:flutter/material.dart';
import 'landmark.dart';
import 'api_service.dart';

class LandmarksListScreen extends StatefulWidget {
  const LandmarksListScreen({super.key});

  @override
  State<LandmarksListScreen> createState() => _LandmarksListScreenState();
}

class _LandmarksListScreenState extends State<LandmarksListScreen> {
  final ApiService _apiService = ApiService();
  List<Landmark> _landmarks = [];
  bool _isLoading = true;
  String? _error;
  bool _sortDescending = true;
  double _minScoreFilter = double.negativeInfinity;

  @override
  void initState() {
    super.initState();
    _loadLandmarks();
  }

  Future<void> _loadLandmarks() async {
    try {
      final landmarks = await _apiService.getLandmarks();
      setState(() {
        _landmarks = landmarks;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _showFilterDialog() {
    final controller = TextEditingController(
      text: _minScoreFilter == double.negativeInfinity
          ? ''
          : _minScoreFilter.toString(),
    );
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Filter by minimum score'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: const InputDecoration(hintText: 'e.g. -500000'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _minScoreFilter = double.negativeInfinity;
              });
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _minScoreFilter =
                    double.tryParse(controller.text) ?? double.negativeInfinity;
              });
              Navigator.pop(context);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text('Error: $_error'));
    }

    final filteredList = _landmarks
        .where((l) => l.score >= _minScoreFilter)
        .toList()
      ..sort((a, b) => _sortDescending
          ? b.score.compareTo(a.score)
          : a.score.compareTo(b.score));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  _sortDescending ? Icons.arrow_downward : Icons.arrow_upward,
                ),
                onPressed: () {
                  setState(() {
                    _sortDescending = !_sortDescending;
                  });
                },
              ),
              const Text('Sort by score'),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.filter_list),
                onPressed: () => _showFilterDialog(),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: filteredList.length,
            itemBuilder: (context, index) {
              final landmark = filteredList[index];
              return ListTile(
                leading: landmark.imageUrl.isNotEmpty
                    ? Image.network(
                  landmark.imageUrl,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                )
                    : const Icon(Icons.place, size: 40),
                title: Text(landmark.title),
                subtitle: Text('Score: ${landmark.score.toStringAsFixed(1)}'),
              );
            },
          ),
        ),
      ],
    );
  }
}