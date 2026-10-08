import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/chat.dart';
import 'package:localsend_app/provider/chat_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/system_date_time_formatter.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

class MessagesTab extends StatelessWidget {
  const MessagesTab({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch(chatProvider);
    final wide = MediaQuery.sizeOf(context).width >= 900;
    if (!state.ready) return Center(child: Text(state.error ?? t.chat.storageError));
    return PopScope(
      canPop: wide || state.peer == null,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) context.redux(chatProvider).dispatch(SelectChatAction());
      },
      child: Column(
        children: [
          if (state.error != null)
            MaterialBanner(
              content: Text(state.error!),
              actions: [TextButton(onPressed: () => context.redux(chatProvider).dispatch(DismissChatErrorAction()), child: Text(t.general.close))],
            ),
          Expanded(
            child: wide
                ? Row(
                    children: [
                      SizedBox(width: 300, child: _ConversationList(state)),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: state.peer == null
                            ? Center(child: Text(t.chat.selectConversation))
                            : _ConversationView(key: ValueKey(state.peer), state: state),
                      ),
                    ],
                  )
                : state.peer == null
                ? _ConversationList(state)
                : _ConversationView(key: ValueKey(state.peer), state: state),
          ),
        ],
      ),
    );
  }
}

class _ConversationList extends StatelessWidget {
  final ChatState state;
  const _ConversationList(this.state);
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(child: Text(t.chat.title, style: Theme.of(context).textTheme.headlineSmall)),
            IconButton(tooltip: t.chat.newConversation, icon: const Icon(Icons.edit_square), onPressed: () => _newConversation(context)),
          ],
        ),
      ),
      Expanded(
        child: state.conversations.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(t.chat.empty, textAlign: TextAlign.center),
                ),
              )
            : ListView.builder(
                itemCount: state.conversations.length,
                itemBuilder: (context, index) {
                  final conversation = state.conversations[index];
                  return ListTile(
                    selected: conversation.peer == state.peer,
                    leading: Badge(
                      isLabelVisible: conversation.unread > 0,
                      label: Text('${conversation.unread}'),
                      child: const Icon(Icons.chat_bubble_outline),
                    ),
                    title: Text(conversation.alias, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(SystemDateTimeFormatter.dateTime(context, conversation.timestamp)),
                    onTap: () => context.redux(chatProvider).dispatch(SelectChatAction(peer: conversation.peer, alias: conversation.alias)),
                  );
                },
              ),
      ),
    ],
  );
  Future<void> _newConversation(BuildContext context) async {
    unawaited(context.global.dispatchAsync(StartSmartScan()));
    final device = await showDialog<Device>(context: context, builder: (context) => _DevicePicker());
    if (device != null && context.mounted) context.redux(chatProvider).dispatch(SelectChatAction(peer: device.fingerprint, alias: device.alias));
  }
}

class _DevicePicker extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final nearby = context.watch(nearbyDevicesProvider).allDevices.values;
    final devices = {
      for (final d in nearby)
        if (d.ip != null && d.https) d.fingerprint: d,
    }.values.toList();
    return AlertDialog(
      title: Text(t.chat.newConversation),
      content: SizedBox(
        width: 400,
        height: 300,
        child: devices.isEmpty
            ? Center(child: Text(t.chat.noDevices))
            : ListView.builder(
                itemCount: devices.length,
                itemBuilder: (context, i) => ListTile(
                  leading: const Icon(Icons.devices),
                  title: Text(devices[i].alias),
                  subtitle: Text(devices[i].ip!),
                  onTap: () => Navigator.of(context).pop(devices[i]),
                ),
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.general.cancel))],
    );
  }
}

class _ConversationView extends StatefulWidget {
  final ChatState state;
  const _ConversationView({super.key, required this.state});
  @override
  State<_ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<_ConversationView> {
  final _text = TextEditingController();
  final _search = TextEditingController();
  int _ttl = 0;
  bool _saving = false;
  Timer? _searchDelay;
  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
  }

  void _changed() => setState(() {});
  @override
  void dispose() {
    _searchDelay?.cancel();
    _text.removeListener(_changed);
    _text.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final devices = context.watch(nearbyDevicesProvider).allDevices.values;
    final online = devices.any((d) => d.fingerprint == state.peer && d.https && d.ip != null);
    final https = context.watch(settingsProvider.select((s) => s.https));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.redux(chatProvider).dispatch(SelectChatAction()),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(state.alias, style: Theme.of(context).textTheme.titleLarge),
                    Text(online ? t.chat.online : t.chat.offlineLabel, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (value) async {
                  if (value == 'clear') {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(t.chat.clearHistory),
                        content: Text(t.chat.clearHistoryBody),
                        actions: [
                          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(t.general.cancel)),
                          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(t.general.confirm)),
                        ],
                      ),
                    );
                    if (confirmed != true || !context.mounted) return;
                  }
                  if (context.mounted) {
                    await context.redux(chatProvider).dispatchAsync(ChatEditHistoryAction(peer: state.peer!, revoke: value == 'revoke'));
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'clear', child: Text(t.chat.clearHistory)),
                  PopupMenuItem(value: 'revoke', child: Text(t.chat.revokeConsent)),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: t.chat.search,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) {
              _searchDelay?.cancel();
              _searchDelay = Timer(const Duration(milliseconds: 250), () {
                if (mounted) context.redux(chatProvider).dispatch(ChatSearchAction(value));
              });
            },
          ),
        ),
        Expanded(
          child: state.messages.isEmpty
              ? Center(child: Text(t.chat.noMessages))
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: state.messages.length + (state.hasMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == state.messages.length) {
                      return TextButton(
                        onPressed: () => context.redux(chatProvider).dispatch(ChatSearchAction(state.search, more: true)),
                        child: Text(t.chat.loadMore),
                      );
                    }
                    return _MessageBubble(key: ValueKey(state.messages[index].seq), message: state.messages[index], peer: state.peer!);
                  },
                ),
        ),
        if (!https) Padding(padding: const EdgeInsets.all(8), child: Text(t.chat.requiresHttps)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(Icons.timer_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(t.chat.disappearing)),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 128,
                    child: DropdownButton<int>(
                      isExpanded: true,
                      value: _ttl,
                      items: [0, 300, 3600, 86400, 604800].map((value) => DropdownMenuItem(value: value, child: Text(_ttlLabel(value)))).toList(),
                      onChanged: (value) => setState(() => _ttl = value ?? 0),
                    ),
                  ),
                ],
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: null,
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(hintText: t.chat.writeMessage, border: const OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: t.chat.send,
                    icon: const Icon(Icons.send),
                    onPressed: !https || _saving || _text.text.trim().isEmpty
                        ? null
                        : () async {
                            setState(() => _saving = true);
                            final text = _text.text;
                            final saved = await context
                                .redux(chatProvider)
                                .dispatchAsyncTakeResult(ComposeChatAction(text: text, ttl: _ttl == 0 ? null : _ttl));
                            if (!mounted) return;
                            if (saved && _text.text == text) _text.clear();
                            setState(() => _saving = false);
                          },
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _ttlLabel(int value) => switch (value) {
  300 => t.chat.fiveMinutes,
  3600 => t.chat.oneHour,
  86400 => t.chat.oneDay,
  604800 => t.chat.oneWeek,
  _ => t.chat.off,
};

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final String peer;
  const _MessageBubble({super.key, required this.message, required this.peer});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final status = switch (message.status) {
      'sending' => t.chat.sending,
      'delivered' => t.chat.delivered,
      'declined' => t.chat.declined,
      'unconfirmed' => t.chat.unconfirmed,
      _ => t.chat.failed,
    };
    final remaining = message.expires?.difference(DateTime.now()).inSeconds.clamp(0, 604800);
    return Align(
      alignment: message.outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 640),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        decoration: BoxDecoration(
          color: message.outgoing ? colors.primaryContainer : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(child: SelectableText(message.text)),
                PopupMenuButton<String>(
                  iconSize: 18,
                  onSelected: (value) async {
                    if (value == 'copy') {
                      await Clipboard.setData(ClipboardData(text: message.text));
                    } else if (value == 'delete') {
                      await context.redux(chatProvider).dispatchAsync(ChatEditHistoryAction(peer: peer, id: message.id));
                    } else if (value == 'retry') {
                      await context.redux(chatProvider).dispatchAsync(SendChatAction(text: message.text, ttl: message.ttl, messageId: message.id));
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'copy', child: Text(t.chat.copy)),
                    PopupMenuItem(value: 'delete', child: Text(t.chat.deleteLocal)),
                    if (message.outgoing && ['failed', 'declined', 'unconfirmed'].contains(message.status))
                      PopupMenuItem(value: 'retry', child: Text(t.chat.retry)),
                  ],
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                [
                  SystemDateTimeFormatter.dateTime(context, message.timestamp),
                  if (message.outgoing) status,
                  if (remaining != null) '${_ttlLabel(message.ttl ?? 0)} · ${remaining}s',
                ].join(' · '),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
