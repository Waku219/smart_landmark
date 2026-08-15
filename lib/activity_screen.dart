import 'package:flutter/material.dart';
import 'visit_history_service.dart';

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  @override
  Widget build(BuildContext context) {
    final history = VisitHistoryService().history;

    if (history.isEmpty) {
      return const Center(child: Text('No visits yet. Go visit a landmark!'));
    }

    return ListView.builder(
      itemCount: history.length,
      itemBuilder: (context, index) {
        final record = history[index];
        return ListTile(
          leading: const Icon(Icons.check_circle, color: Colors.green),
          title: Text(record.landmarkTitle),
          subtitle: Text(
            'Visited: ${record.visitTime.hour}:${record.visitTime.minute.toString().padLeft(2, '0')} • '
                'Distance: ${record.distance.toStringAsFixed(2)}m',
          ),
        );
      },
    );
  }
}