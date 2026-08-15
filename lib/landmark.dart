class Landmark {
  final int id;
  final String title;
  final double lat;
  final double lon;
  final String image;
  final double score;
  final bool isActive;

  Landmark({
    required this.id,
    required this.title,
    required this.lat,
    required this.lon,
    required this.image,
    required this.score,
    required this.isActive,
  });

  factory Landmark.fromJson(Map<String, dynamic> json) {
    return Landmark(
      id: json['id'],
      title: json['title'],
      lat: double.parse(json['lat'].toString()),
      lon: double.parse(json['lon'].toString()),
      image: json['image'],
      score: double.parse(json['score'].toString()),
      isActive: json['is_active'] == 1,
    );
  }

  String get imageUrl => image.isNotEmpty
      ? 'https://labs.anontech.info/cse489/exm3/$image'
      : '';

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'lat': lat,
      'lon': lon,
      'image': image,
      'score': score,
      'isActive': isActive ? 1 : 0,
    };
  }

  factory Landmark.fromMap(Map<String, dynamic> map) {
    return Landmark(
      id: map['id'],
      title: map['title'],
      lat: map['lat'],
      lon: map['lon'],
      image: map['image'],
      score: map['score'],
      isActive: map['isActive'] == 1,
    );
  }
}