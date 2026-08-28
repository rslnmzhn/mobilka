String sessionArtifactsLocation(String conversationId) =>
    '/chat/${Uri.encodeComponent(conversationId)}/artifacts';
