class VisitRecord {
  final String landmarkTitle;
  final DateTime visitTime;
  final double distance;

  VisitRecord({
    required this.landmarkTitle,
    required this.visitTime,
    required this.distance,
  });
}

class VisitHistoryService {
  // Singleton pattern — পুরো app জুড়ে একটাই instance থাকবে
  static final VisitHistoryService _instance = VisitHistoryService._internal();
  factory VisitHistoryService() => _instance;
  VisitHistoryService._internal();

  final List<VisitRecord> _history = [];

  List<VisitRecord> get history => List.unmodifiable(_history);

  void addVisit(String landmarkTitle, double distance) {
    _history.insert(
      0,
      VisitRecord(
        landmarkTitle: landmarkTitle,
        visitTime: DateTime.now(),
        distance: distance,
      ),
    );
  }
}
