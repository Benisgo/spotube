import 'package:auto_route/auto_route.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/titlebar/titlebar.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/modules/player/sibling_tracks_sheet.dart';

@RoutePage()
class PlayerTrackSourcesPage extends StatelessWidget {
  const PlayerTrackSourcesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      headers: [
        TitleBar(
          leading: [
            IconButton.ghost(
              icon: const Icon(SpotubeIcons.angleDown),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
          title: Text(context.l10n.alternative_track_sources),
        ),
      ],
      child: const SiblingTracksSheet(floating: false),
    );
  }
}
