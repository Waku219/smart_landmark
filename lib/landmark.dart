class Landmark {
  final int id;
  final String title;
  final double lat;
  final double lon;
  final String image;
  final double score;

  Landmark({
    required this.id,
    required this.title,
    required this.lat,
    required this.lon,
    required this.image,
    required this.score,
  });

  factory Landmark.fromJson(Map<String, dynamic> json) {
    return Landmark(
      id: json['id'],
      title: json['title'],
      lat: double.parse(json['lat'].toString()),
      lon: double.parse(json['lon'].toString()),
      image: json['image'],
      score: double.parse(json['score'].toString()),
    );
  }
}