/// The native model receives verified moc3 bytes separately from the prefab.
/// Retain evaluation records without a second boxed copy of the moc payload.
bool retainNativeCubismModelSourceRecord(Map row) {
  final data = row['data'];
  final script = data is Map ? data['m_Script'] : null;
  final ref = script is Map ? script['reference'] : null;
  final name = ref is Map ? ref['name'] : null;
  return const {
        'GameObject',
        'Transform',
        'Animator',
        'AnimationClip',
      }.contains(row['type']) ||
      (row['type'] == 'MonoBehaviour' &&
          name is String &&
          name != 'CubismMoc' &&
          (name.startsWith('Cubism') || name.startsWith('Live2D')));
}
