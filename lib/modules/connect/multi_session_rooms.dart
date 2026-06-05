import 'package:flutter/material.dart' show ListTile;
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/models/multi_session/multi_session.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';

class ConnectPageMultiSessionRooms extends HookConsumerWidget {
  const ConnectPageMultiSessionRooms({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final codeController = useTextEditingController();
    final session = ref.watch(multiSessionProvider);
    final sessionNotifier = ref.read(multiSessionProvider.notifier);
    final roomCode = session.code;
    final snapshot = session.snapshot;
    final isConnectedRoom = session.connected && roomCode != null;
    final isHost = session.isHost;
    final members = snapshot?.members ?? const <MultiSessionMember>[];

    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          sliver: SliverToBoxAdapter(
            child: Text("Multi-Session", style: theme.typography.bold),
          ),
        ),
        const SliverGap(10),
        SliverToBoxAdapter(
          child: SurfaceCard(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                if (isConnectedRoom) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          "Room $roomCode",
                          style: theme.typography.large,
                        ),
                      ),
                      HookBuilder(
                        builder: (context) {
                          final copied = useState(false);

                          return Button.ghost(
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: roomCode),
                              );
                              copied.value = true;
                            },
                            leading: Icon(
                              copied.value
                                  ? SpotubeIcons.done
                                  : SpotubeIcons.clipboard,
                            ),
                            child: Text(context.l10n.copy_to_clipboard),
                          );
                        },
                      ),
                      Button.outline(
                        onPressed: isHost
                            ? sessionNotifier.endRoom
                            : sessionNotifier.leaveRoom,
                        leading: const Icon(SpotubeIcons.power),
                        child: Text(isHost ? "End" : "Leave"),
                      ),
                    ],
                  ),
                  if (members.isNotEmpty)
                    for (final member in members)
                      _MemberTile(member: member),
                ] else ...[
                  Row(
                    spacing: 8,
                    children: [
                      Expanded(
                        child: Button.primary(
                          onPressed: session.connecting
                              ? null
                              : sessionNotifier.createRoom,
                          leading: const Icon(SpotubeIcons.add),
                          child: const Text("Create room"),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    spacing: 8,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: codeController,
                          placeholder: const Text("Room code"),
                        ),
                      ),
                      Button.outline(
                        onPressed: session.connecting
                            ? null
                            : () => sessionNotifier.joinRoom(codeController.text),
                        leading: const Icon(SpotubeIcons.login),
                        child: const Text("Join"),
                      ),
                    ],
                  ),
                ],
                if (session.error != null)
                  Text(
                    session.error!,
                    style: theme.typography.small.copyWith(
                      color: theme.colorScheme.destructive,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SliverGap(10),
      ],
    );
  }
}

class _MemberTile extends ConsumerWidget {
  final MultiSessionMember member;

  const _MemberTile({required this.member});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(multiSessionProvider);
    final notifier = ref.read(multiSessionProvider.notifier);
    final canManage = session.can(MultiSessionPermission.manageMembers) &&
        member.role != "host";

    return ListTile(
      leading: Icon(
        member.role == "host" ? SpotubeIcons.user : SpotubeIcons.device,
      ),
      title: Text(member.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(member.role),
          if (canManage)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _PermissionSwitch(
                  label: "Queue",
                  value:
                      member.permissions[MultiSessionPermission.editQueue] == true,
                  onChanged: (value) => notifier.setMemberPermissions(
                    member.id,
                    {MultiSessionPermission.editQueue: value},
                  ),
                ),
                _PermissionSwitch(
                  label: "Playback",
                  value: member
                          .permissions[MultiSessionPermission.controlPlayback] ==
                      true,
                  onChanged: (value) => notifier.setMemberPermissions(
                    member.id,
                    {MultiSessionPermission.controlPlayback: value},
                  ),
                ),
                _PermissionSwitch(
                  label: "Invite",
                  value: member.permissions[MultiSessionPermission.invite] == true,
                  onChanged: (value) => notifier.setMemberPermissions(
                    member.id,
                    {MultiSessionPermission.invite: value},
                  ),
                ),
                _PermissionSwitch(
                  label: "Members",
                  value: member
                          .permissions[MultiSessionPermission.manageMembers] ==
                      true,
                  onChanged: (value) => notifier.setMemberPermissions(
                    member.id,
                    {MultiSessionPermission.manageMembers: value},
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _PermissionSwitch extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _PermissionSwitch({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        Text(label),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}
