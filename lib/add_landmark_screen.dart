import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'api_service.dart';
import 'location_service.dart';

class AddLandmarkScreen extends StatefulWidget {
  /// Called after a successful create so the Map and Landmarks tabs can
  /// refresh — IndexedStack keeps them alive, so they don't re-fetch on their
  /// own and would otherwise never show the new landmark.
  final VoidCallback? onLandmarkCreated;

  const AddLandmarkScreen({super.key, this.onLandmarkCreated});

  @override
  State<AddLandmarkScreen> createState() => _AddLandmarkScreenState();
}

class _AddLandmarkScreenState extends State<AddLandmarkScreen> {
  final ApiService _apiService = ApiService();
  final LocationService _locationService = LocationService();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _latController = TextEditingController();
  final TextEditingController _lonController = TextEditingController();

  File? _pickedImage;
  bool _isSubmitting = false;
  bool _isLocating = false;

  @override
  void initState() {
    super.initState();
    // The spec asks for the GPS location to be auto-fetched for a new entry,
    // not for the user to have to tap a button first. The manual button stays
    // as a way to re-read the position.
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoFetchLocation());
  }

  @override
  void dispose() {
    // These were never disposed before — one leaked controller per screen.
    _titleController.dispose();
    _latController.dispose();
    _lonController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    // The API rejects anything over 2MB and a modern phone photo is 3-8MB, so
    // resize/recompress at pick time rather than letting the upload fail.
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 80,
    );
    if (picked != null && mounted) {
      setState(() {
        _pickedImage = File(picked.path);
      });
    }
  }

  Future<void> _autoFetchLocation() async {
    if (!mounted) return;
    setState(() => _isLocating = true);
    try {
      final position = await _locationService.getCurrentLocation();
      if (!mounted) return;
      setState(() {
        _latController.text = position.latitude.toStringAsFixed(6);
        _lonController.text = position.longitude.toStringAsFixed(6);
      });
    } catch (e) {
      _showSnack('Could not get location: $e');
    } finally {
      if (mounted) setState(() => _isLocating = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _submit() async {
    final title = _titleController.text.trim();
    final lat = double.tryParse(_latController.text.trim());
    final lon = double.tryParse(_lonController.text.trim());

    if (title.isEmpty || lat == null || lon == null) {
      _showSnack('Enter a title and a valid latitude/longitude.');
      return;
    }
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      _showSnack('Latitude must be -90..90 and longitude -180..180.');
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      await _apiService.createLandmark(
        title: title,
        lat: lat,
        lon: lon,
        // Optional per the API spec — don't block the user who has no photo.
        imageFile: _pickedImage,
      );

      if (!mounted) return;
      _showSnack('Landmark created successfully!');

      _titleController.clear();
      _latController.clear();
      _lonController.clear();
      setState(() => _pickedImage = null);

      // Let the Map and List tabs know they're stale.
      widget.onLandmarkCreated?.call();
    } catch (e) {
      _showSnack('Error: $e');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _titleController,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _latController,
                  decoration: const InputDecoration(labelText: 'Latitude'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _lonController,
                  decoration: const InputDecoration(labelText: 'Longitude'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _isLocating ? null : _autoFetchLocation,
            icon: _isLocating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.my_location),
            label: Text(
              _isLocating ? 'Getting location…' : 'Use current location',
            ),
          ),
          const SizedBox(height: 16),
          if (_pickedImage != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(_pickedImage!, height: 150, fit: BoxFit.cover),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _pickedImage = null),
              icon: const Icon(Icons.close),
              label: const Text('Remove image'),
            ),
          ],
          TextButton.icon(
            onPressed: _pickImage,
            icon: const Icon(Icons.image),
            label: Text(
              _pickedImage == null ? 'Pick image (optional)' : 'Change image',
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _isSubmitting ? null : _submit,
            child: _isSubmitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Create Landmark'),
          ),
        ],
      ),
    );
  }
}
