class Artifact {
  const Artifact({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
    this.conversationId,
    this.sessionKey,
    this.docxSourceSha256,
  });

  final String id;
  final String title;
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? conversationId;
  final String? sessionKey;
  final String? docxSourceSha256;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'content': content,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'conversationId': conversationId,
    'sessionKey': sessionKey,
    'docxSourceSha256': docxSourceSha256,
  };

  factory Artifact.fromJson(Map<dynamic, dynamic> json) => Artifact(
    id: json['id'].toString(),
    title: json['title']?.toString() ?? '',
    content: json['content']?.toString() ?? '',
    createdAt: DateTime.parse(json['createdAt'].toString()),
    updatedAt: DateTime.parse(json['updatedAt'].toString()),
    conversationId: json['conversationId']?.toString(),
    sessionKey: json['sessionKey']?.toString(),
    docxSourceSha256: json['docxSourceSha256']?.toString(),
  );

  Artifact copyWith({
    String? title,
    String? content,
    String? docxSourceSha256,
    bool clearDocxSourceSha256 = false,
  }) => Artifact(
    id: id,
    title: title ?? this.title,
    content: content ?? this.content,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
    conversationId: conversationId,
    sessionKey: sessionKey,
    docxSourceSha256: clearDocxSourceSha256
        ? null
        : docxSourceSha256 ?? this.docxSourceSha256,
  );
}
