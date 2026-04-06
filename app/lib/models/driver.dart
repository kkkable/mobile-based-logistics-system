class Driver {
  final int driverId;
  String name;
  double avgRating;

  Driver({required this.driverId, this.name = 'Unknown Driver', this.avgRating = 0.0});

  factory Driver.fromJson(Map<String, dynamic> json) {
    return Driver(
      driverId: json['driver_id'] ?? 0,
      name: json['name'] ?? 'Unknown Driver',
      avgRating: (json['avg_rating'] is String)
          ? double.tryParse(json['avg_rating']) ?? 0.0
          : json['avg_rating'] ?? 0.0,
    );
  }
}
