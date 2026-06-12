import 'package:flutter/material.dart' show ListTile;
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/image/universal_image.dart';
import 'package:spotube/components/titlebar/titlebar.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/multi_session/multi_session.dart';
import 'package:spotube/provider/metadata_plugin/core/user.dart';
import 'package:spotube/provider/metadata_plugin/search/tracks.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:auto_route/auto_route.dart';

@RoutePage()
class MultiSessionPage extends HookConsumerWidget {
  static const name = "multi_session";
  const MultiSessionPage({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final theme = Theme.of(context);
    final codeController = useTextEditingController();
    final session = ref.watch(multiSessionProvider);
    final sessionNotifier = ref.read(multiSessionProvider.notifier);
    final roomCode = session.code;
    final snapshot = session.snapshot;
    final hasRoom = roomCode != null;
    final isConnectedRoom = session.connected && hasRoom;
    final isHost = session.isHost;
    final members = snapshot?.members ?? const <MultiSessionMember>[];
    final invite = session.pendingInvite;
    final inviteDialogKey = useRef<String?>(null);
    final preferences = ref.watch(userPreferencesProvider);

    Future<void> joinFromInput() async {
      final value = codeController.text.trim();
      if (value.isEmpty) return;

      final inviteLink = parseMultiSessionInviteUri(value);
      if (inviteLink != null) {
        await sessionNotifier.resolveInviteUri(value);
        return;
      }

      await sessionNotifier.joinRoom(value);
    }

    useEffect(() {
      final inviteCode = invite?.code;
      if (inviteCode == null) {
        inviteDialogKey.value = null;
        return null;
      }

      if (inviteDialogKey.value == inviteCode) {
        return null;
      }

      inviteDialogKey.value = inviteCode;
      Future.microtask(() async {
        if (!context.mounted) return;

        final shouldLeaveCurrentRoom =
            session.code != null && session.code != inviteCode;

        final result = await showDialog<bool>(
          context: context,
          builder: (context) {
            final title = invite?.metadata == null
                ? "Join room $inviteCode?"
                : "Join room $inviteCode with ${invite!.metadata!.members} member(s)?";

            return AlertDialog(
              title: Text(title),
              content: Text(
                invite?.error ??
                    "Relay: ${invite?.relayUrl}\nYou can confirm before Spotube joins the room.",
              ),
              actions: [
                Button.secondary(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(context.l10n.cancel),
                ),
                Button.primary(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(
                    shouldLeaveCurrentRoom
                        ? "Leave current & join"
                        : "Join room",
                  ),
                ),
              ],
            );
          },
        );

        if (result == true) {
          await sessionNotifier.acceptPendingInvite(
            leaveCurrentRoom: shouldLeaveCurrentRoom,
          );
        } else {
          sessionNotifier.clearPendingInvite();
        }
      });

      return null;
    }, [invite?.code, invite?.error, invite?.metadata?.members, session.code]);

    Widget buildRoomStatusBadge() {
      if (session.connected) {
        return const SecondaryBadge(
          child: Text("Connected"),
        );
      }
      if (session.connecting) {
        return const PrimaryBadge(
          child: Text("Connecting"),
        );
      }
      if (hasRoom) {
        return const DestructiveBadge(
          child: Text("Reconnecting"),
        );
      }
      return const OutlineBadge(
        child: Text("Idle"),
      );
    }

    return SafeArea(
      bottom: false,
      child: Scaffold(
        headers: [
          TitleBar(title: Text("Multi-Session")),
        ],
        child: Padding(
          padding: const EdgeInsets.all(10.0),
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    "Listening Room",
                    style: theme.typography.bold,
                  ),
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
                      if (hasRoom) ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                spacing: 6,
                                children: [
                                  Text(
                                    "Room $roomCode",
                                    style: theme.typography.large,
                                  ),
                                  buildRoomStatusBadge(),
                                  Text(
                                    snapshot?.communityQueueEnabled == true
                                        ? "Community queue is on"
                                        : "Community queue is off",
                                    style: theme.typography.small,
                                  ),
                                ],
                              ),
                            ),
                            Button.outline(
                              onPressed: session.connecting
                                  ? null
                                  : isHost
                                      ? sessionNotifier.endRoom
                                      : sessionNotifier.leaveRoom,
                              leading: const Icon(SpotubeIcons.power),
                              child: Text(isHost ? "End" : "Leave"),
                            ),
                          ],
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            Button.ghost(
                              onPressed: () => Clipboard.setData(
                                ClipboardData(text: roomCode),
                              ),
                              leading: const Icon(SpotubeIcons.clipboard),
                              child: const Text("Copy code"),
                            ),
                            if (session.can(MultiSessionPermission.invite) &&
                                sessionNotifier.inviteUri != null)
                              Button.ghost(
                                onPressed: () => Clipboard.setData(
                                  ClipboardData(
                                    text: sessionNotifier.inviteUri.toString(),
                                  ),
                                ),
                                leading: const Icon(SpotubeIcons.share),
                                child: const Text("Copy invite link"),
                              ),
                            if (session.can(MultiSessionPermission.invite) &&
                                sessionNotifier.inviteUri != null)
                              Button.ghost(
                                onPressed: () => showDialog<void>(
                                  context: context,
                                  builder: (context) => _InviteQrDialog(
                                    inviteUri: sessionNotifier.inviteUri!,
                                  ),
                                ),
                                leading: const Icon(SpotubeIcons.grid),
                                child: const Text("Show QR"),
                              ),
                          ],
                        ),
                        if (isConnectedRoom &&
                            session.can(MultiSessionPermission.editQueue))
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("Community queue"),
                              Switch(
                                value: snapshot?.communityQueueEnabled ?? true,
                                onChanged:
                                    sessionNotifier.setCommunityQueueEnabled,
                              ),
                            ],
                          ),
                        if (isConnectedRoom &&
                            session.can(MultiSessionPermission.editQueue))
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("Auto accept suggested tracks"),
                              Switch(
                                value: snapshot?.autoAcceptSuggestedTracks ??
                                    false,
                                onChanged: sessionNotifier
                                    .setAutoAcceptSuggestedTracksEnabled,
                              ),
                            ],
                          ),
                        if (isConnectedRoom &&
                            session.can(MultiSessionPermission.editQueue) &&
                            preferences.discordPresence)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("Allow joining through Discord"),
                              Switch(
                                value: snapshot?.discordJoinEnabled ?? false,
                                onChanged:
                                    sessionNotifier.setDiscordJoinEnabled,
                              ),
                            ],
                          ),
                        if (isConnectedRoom)
                          _SuggestionsSection(
                            session: session,
                            notifier: sessionNotifier,
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
                                placeholder:
                                    const Text("Room code or invite link"),
                              ),
                            ),
                            Button.outline(
                              onPressed:
                                  session.connecting ? null : joinFromInput,
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
          ),
        ),
      ),
    );
  }
}

class _SuggestionsSection extends HookConsumerWidget {
  final MultiSessionState session;
  final MultiSessionNotifier notifier;

  const _SuggestionsSection({
    required this.session,
    required this.notifier,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = session.snapshot;
    final suggestions =
        snapshot?.suggestions ?? const <MultiSessionSuggestion>[];
    final members = {
      for (final member in snapshot?.members ?? const <MultiSessionMember>[])
        member.id: member,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text("Suggestions"),
            if (snapshot?.communityQueueEnabled == true &&
                session.can(MultiSessionPermission.suggestTracks))
              Button.ghost(
                onPressed: () async {
                  final track = await showDialog<SpotubeFullTrackObject>(
                    context: context,
                    builder: (context) => const _SuggestTrackDialog(),
                  );
                  if (track != null) {
                    notifier.suggestTrack(track);
                  }
                },
                leading: const Icon(SpotubeIcons.add),
                child: const Text("Suggest track"),
              ),
          ],
        ),
        if (suggestions.isEmpty)
          const Text("No suggestions yet.")
        else
          for (final suggestion in suggestions)
            SurfaceCard(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Text(suggestion.track.name),
                  Text(
                    suggestion.track.artists
                        .map((artist) => artist.name)
                        .join(", "),
                    style: Theme.of(context).typography.small,
                  ),
                  Text(
                    "Suggested by ${members[suggestion.suggestedBy]?.name ?? "Unknown"}",
                    style: Theme.of(context).typography.small,
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Button.ghost(
                        onPressed:
                            suggestion.voterIds.contains(session.memberId)
                                ? null
                                : () => notifier.voteSuggestion(suggestion.id),
                        leading: const Icon(SpotubeIcons.heart),
                        child: Text("Upvote (${suggestion.voteCount})"),
                      ),
                      if (session.can(MultiSessionPermission.editQueue))
                        Button.ghost(
                          onPressed: () =>
                              notifier.promoteSuggestion(suggestion.id),
                          leading: const Icon(SpotubeIcons.lightning),
                          child: const Text("Play next"),
                        ),
                      if (session.can(MultiSessionPermission.editQueue))
                        Button.ghost(
                          onPressed: () =>
                              notifier.removeSuggestion(suggestion.id),
                          leading: const Icon(SpotubeIcons.trash),
                          child: const Text("Remove"),
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

class _MemberTile extends ConsumerWidget {
  final MultiSessionMember member;

  const _MemberTile({required this.member});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(multiSessionProvider);
    final notifier = ref.read(multiSessionProvider.notifier);
    final canManage = session.can(MultiSessionPermission.manageMembers) &&
        member.role != "host";
    final currentUser = ref.watch(metadataPluginUserProvider).valueOrNull;
    final displayImages = member.images.isNotEmpty
        ? member.images
        : member.id == session.memberId
            ? currentUser?.images ?? const <SpotubeImageObject>[]
            : const <SpotubeImageObject>[];

    return ListTile(
      leading: Avatar(
        initials: Avatar.getInitials(member.name),
        size: 40,
        provider: displayImages.isNotEmpty
            ? UniversalImage.imageProvider(
                displayImages.asUrlString(
                  placeholder: ImagePlaceholder.artist,
                ),
              )
            : null,
      ),
      title: Text(member.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(member.role == "host" ? "Host" : member.preset.label),
          if (canManage)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final preset in [
                  MultiSessionMemberPreset.listener,
                  MultiSessionMemberPreset.dj,
                  MultiSessionMemberPreset.coHost,
                ])
                  (member.preset == preset ? Button.secondary : Button.outline)(
                    onPressed: () =>
                        notifier.setMemberPreset(member.id, preset),
                    child: Text(preset.label),
                  ),
                Button.destructive(
                  onPressed: () => notifier.kickMember(member.id),
                  child: const Text("Kick"),
                ),
              ],
            ),
          if (canManage)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _PermissionSwitch(
                  label: "Suggest",
                  value: member
                          .permissions[MultiSessionPermission.suggestTracks] ==
                      true,
                  onChanged: (value) => notifier.setMemberPermissions(
                    member.id,
                    {MultiSessionPermission.suggestTracks: value},
                  ),
                ),
                _PermissionSwitch(
                  label: "Vote",
                  value:
                      member.permissions[MultiSessionPermission.voteTracks] ==
                          true,
                  onChanged: (value) => notifier.setMemberPermissions(
                    member.id,
                    {MultiSessionPermission.voteTracks: value},
                  ),
                ),
                _PermissionSwitch(
                  label: "Queue",
                  value: member.permissions[MultiSessionPermission.editQueue] ==
                      true,
                  onChanged: (value) => notifier.setMemberPermissions(
                    member.id,
                    {MultiSessionPermission.editQueue: value},
                  ),
                ),
                _PermissionSwitch(
                  label: "Playback",
                  value: member.permissions[
                          MultiSessionPermission.controlPlayback] ==
                      true,
                  onChanged: (value) => notifier.setMemberPermissions(
                    member.id,
                    {MultiSessionPermission.controlPlayback: value},
                  ),
                ),
                _PermissionSwitch(
                  label: "Invite",
                  value:
                      member.permissions[MultiSessionPermission.invite] == true,
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

class _SuggestTrackDialog extends HookConsumerWidget {
  const _SuggestTrackDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useTextEditingController();
    final query = useState("");
    final result = ref.watch(metadataPluginSearchTracksProvider(query.value));
    final tracks =
        result.asData?.value.items ?? const <SpotubeFullTrackObject>[];

    return AlertDialog(
      title: const Text("Suggest a track"),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 10,
          children: [
            TextField(
              controller: controller,
              placeholder: const Text("Search tracks"),
              onChanged: (value) => query.value = value.trim(),
            ),
            Flexible(
              child: SizedBox(
                height: 320,
                child: result.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.separated(
                        itemCount: tracks.length,
                        separatorBuilder: (_, __) => const Divider(),
                        itemBuilder: (context, index) {
                          final track = tracks[index];
                          return ListTile(
                            title: Text(track.name),
                            subtitle: Text(
                              track.artists
                                  .map((artist) => artist.name)
                                  .join(", "),
                            ),
                            trailing: Button.ghost(
                              onPressed: () => Navigator.of(context).pop(track),
                              child: const Text("Suggest"),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        Button.secondary(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.cancel),
        ),
      ],
    );
  }
}

class _InviteQrDialog extends StatelessWidget {
  final Uri inviteUri;

  const _InviteQrDialog({required this.inviteUri});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Invite QR"),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            QrImageView(
              data: inviteUri.toString(),
              size: 240,
            ),
            SelectableText(inviteUri.toString()),
          ],
        ),
      ),
      actions: [
        Button.secondary(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.close),
        ),
      ],
    );
  }
}
