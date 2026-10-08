class ChatConversation {
  final String peer;
  final String alias;
  final bool trusted;
  final int unread;
  final DateTime timestamp;
  ChatConversation.fromJson(Map<String, dynamic> json)
    : peer = json['peer'] as String,
      alias = json['alias'] as String,
      trusted = json['trusted'] as bool,
      unread = json['unread'] as int,
      timestamp = DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int);
  @override
  String toString() => 'ChatConversation(<redacted>)';
}

class ChatMessage {
  final int seq;
  final String id;
  final String text;
  final bool outgoing;
  final DateTime timestamp;
  final DateTime? expires;
  final int? ttl;
  final String status;
  ChatMessage.fromJson(Map<String, dynamic> json)
    : seq = json['seq'] as int,
      id = json['id'] as String,
      text = json['text'] as String,
      outgoing = json['outgoing'] as bool,
      timestamp = DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
      expires = json['expires'] == null ? null : DateTime.fromMillisecondsSinceEpoch(json['expires'] as int),
      ttl = json['ttl'] as int?,
      status = json['status'] as String;
  @override
  String toString() => 'ChatMessage($id, $status, <redacted>)';
}

class ChatState {
  final bool ready;
  final bool visible;
  final String? error;
  final List<ChatConversation> conversations;
  final List<ChatMessage> messages;
  final String? peer;
  final String alias;
  final String search;
  final int limit;
  final bool hasMore;
  const ChatState({
    this.ready = false,
    this.visible = false,
    this.error,
    this.conversations = const [],
    this.messages = const [],
    this.peer,
    this.alias = '',
    this.search = '',
    this.limit = 50,
    this.hasMore = false,
  });
  ChatState copyWith({
    bool? ready,
    bool? visible,
    String? error,
    bool clearError = false,
    List<ChatConversation>? conversations,
    List<ChatMessage>? messages,
    String? peer,
    bool close = false,
    String? alias,
    String? search,
    int? limit,
    bool? hasMore,
  }) => ChatState(
    ready: ready ?? this.ready,
    visible: visible ?? this.visible,
    error: clearError ? null : error ?? this.error,
    conversations: conversations ?? this.conversations,
    messages: messages ?? this.messages,
    peer: close ? null : peer ?? this.peer,
    alias: alias ?? this.alias,
    search: search ?? this.search,
    limit: limit ?? this.limit,
    hasMore: hasMore ?? this.hasMore,
  );
  @override
  String toString() => 'ChatState(ready: $ready, messages: ${messages.length}, <redacted>)';
}
