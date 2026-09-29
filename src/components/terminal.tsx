"use client"

import { useEffect, useRef, useState } from "react"

const LINES = [
  ["branch", "shift/101"],
  ["worktree", "~/.shift/worktrees/storefront/101"],
  ["agent", "claude code"],
  ["server", "localhost:3001"],
  ["commit", "a41f9c2 Tighter board spacing"],
]

export function Terminal() {
  const ref = useRef<HTMLDivElement>(null)
  const [inView, setInView] = useState(false)

  useEffect(() => {
    const io = new IntersectionObserver(([e]) => e.isIntersecting && setInView(true), { threshold: 0.5 })
    if (ref.current) io.observe(ref.current)
    return () => io.disconnect()
  }, [])

  return (
    <div ref={ref} data-inview={inView} className="p-5 font-mono text-[13px] leading-7">
      <div className="term-line text-muted-foreground">
        <span className="text-rail-2">❯</span> new task{" "}
        <span className="text-foreground">&quot;Board items feel too far apart&quot;</span>
      </div>
      {LINES.map(([k, v], i) => (
        <div key={k} className="term-line flex gap-3" style={{ transitionDelay: `${(i + 1) * 280}ms` }}>
          <span className="text-[#30d158]">✓</span>
          <span className="w-20 text-muted-foreground">{k}</span>
          <span className="truncate">{v}</span>
        </div>
      ))}
      <div className="term-line mt-1 flex items-center gap-2 text-muted-foreground" style={{ transitionDelay: `${(LINES.length + 1) * 280}ms` }}>
        ready to test
        <span className="inline-block h-4 w-2 animate-pulse bg-foreground/80" />
      </div>
    </div>
  )
}
