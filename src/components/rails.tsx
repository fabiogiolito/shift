// The three rails from the app icon (App/Resources/AppIcon.icon).
const RAIL =
  "M192 288.339C192 255.567 218.567 229 251.339 229H351.505C366.786 229 381.988 231.196 396.644 235.52L628.172 303.832C642.769 308.139 657.91 310.326 673.13 310.326H772.661C805.433 310.326 832 336.893 832 369.665C832 402.437 805.433 429.004 772.661 429.004H673.13C657.91 429.004 642.769 426.817 628.172 422.51L396.644 354.198C381.988 349.874 366.786 347.678 351.505 347.678H251.339C218.567 347.678 192 321.111 192 288.339Z"

export function Rails({ className }: { className?: string }) {
  return (
    <svg viewBox="160 200 704 630" className={className} aria-hidden>
      <path d={RAIL} fill="var(--color-rail-1)" />
      <path d={RAIL} fill="var(--color-rail-2)" transform="translate(0 183)" />
      <path d={RAIL} fill="var(--color-rail-3)" transform="translate(0 366)" />
    </svg>
  )
}
