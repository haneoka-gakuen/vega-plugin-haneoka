import 'story_scene_state.dart';

/// A visual profile and its packet provenance are independent of the chapter's
/// provider, revision and media scope. The host verifies the profile's assets.
final class StoryRenderProfileBinding {
  StoryRenderProfileBinding({
    required this.chapterIdentity,
    required this.profileId,
    required this.profileManifestSHA256,
    required this.packetSource,
  }) {
    if (profileId.isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(profileManifestSHA256) ||
        packetSource.namespace.isEmpty ||
        packetSource.resourceScope.isEmpty ||
        packetSource.contentIdentity != profileManifestSHA256) {
      throw const FormatException('story_render_profile_binding');
    }
  }

  final StorySourceIdentity chapterIdentity, packetSource;
  final String profileId, profileManifestSHA256;
}
