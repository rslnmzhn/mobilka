class Artifact {
  const Artifact({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'content': content,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory Artifact.fromJson(Map<dynamic, dynamic> json) => Artifact(
    id: json['id'].toString(),
    title: json['title']?.toString() ?? '',
    content: json['content']?.toString() ?? '',
    createdAt: DateTime.parse(json['createdAt'].toString()),
    updatedAt: DateTime.parse(json['updatedAt'].toString()),
  );

  Artifact copyWith({String? title, String? content}) => Artifact(
    id: id,
    title: title ?? this.title,
    content: content ?? this.content,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
  );
}
