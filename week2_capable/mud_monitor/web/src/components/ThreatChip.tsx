/**
 * `consider`'s verdict, always shown with the player level it was measured at.
 *
 * The schema comment on `entities.threat_level` is explicit about why: the
 * verdict is relative to the PLAYER'S level, so "The perfect match!" measured
 * at level 1 says nothing useful once the agent is level 8. A verdict rendered
 * alone is not merely incomplete — after a single level-up it is wrong, and
 * confidently so. Hence one component; there is no way to render half of it.
 */
export default function ThreatChip({ threat, level }: { threat: string | null; level: number | null }) {
  if (!threat) return <span className="muted-cell">never appraised</span>;

  return (
    <span className="threat-chip" title={level == null ? "measured at an unrecorded level" : `measured at level ${level}`}>
      <span className="threat-verdict">{threat}</span>
      <span className="threat-level">{level == null ? "@ ?" : `@ L${level}`}</span>
    </span>
  );
}
