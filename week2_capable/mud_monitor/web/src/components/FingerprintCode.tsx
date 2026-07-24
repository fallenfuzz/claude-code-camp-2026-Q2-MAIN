/**
 * A room fingerprint, abbreviated to something scannable with the full value on
 * hover. Visible at all because a mis-identified room is the failure this tab
 * exists to catch, and comparing two rooms' fingerprints is how you catch it.
 */
export default function FingerprintCode({ value, chars = 12 }: { value: string | null; chars?: number }) {
  if (!value) return <span className="muted-cell">—</span>;

  return (
    <code className="fingerprint" title={value}>
      {value.slice(0, chars)}
    </code>
  );
}
