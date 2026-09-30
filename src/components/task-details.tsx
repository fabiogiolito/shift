"use client"

import { useEffect, useRef, useState } from "react"
import { ArrowUpRight, Check, GitMerge } from "lucide-react"
import { Button } from "@/components/ui/button"

const ROWS = [
  ["branch", "shift/101"],
  ["worktree", "~/.shift/worktrees/my-project/101"],
  ["agent", "Claude Code"],
  ["server", "localhost:3001"],
  ["commit", "a41f9c2 Tighter board spacing"],
]

// Details of the task pinned as "ready" in TaskSim.
export function TaskDetails() {
  const ref = useRef<HTMLDivElement>(null)
  const [inView, setInView] = useState(false)

  useEffect(() => {
    const io = new IntersectionObserver(([e]) => e.isIntersecting && setInView(true), { threshold: 0.5 })
    if (ref.current) io.observe(ref.current)
    return () => io.disconnect()
  }, [])

  return (
    <div ref={ref} data-inview={inView} className="p-5">
      <div className="flex items-center justify-between gap-3">
        <h3 className="truncate text-lg font-medium tracking-tight">Tighter board spacing</h3>
        <span className="flex shrink-0 items-center gap-1.5 rounded-full border border-[#30d158]/25 bg-[#30d158]/10 px-2.5 py-1 text-xs font-medium text-[#30d158]">
          <Check className="size-3" strokeWidth={3.5} />
          Ready to test
        </span>
      </div>

      <dl className="mt-5 font-mono text-[13px] leading-7">
        {ROWS.map(([k, v], i) => (
          <div key={k} className="term-line flex gap-3" style={{ transitionDelay: `${i * 220}ms` }}>
            <dt className="flex w-24 shrink-0 items-center gap-2.5 text-muted-foreground">
              <span className="text-[#30d158]">✓</span>
              {k}
            </dt>
            <dd className="truncate">{v}</dd>
          </div>
        ))}
      </dl>

      <div className="term-line mt-6 flex flex-wrap gap-2" style={{ transitionDelay: `${ROWS.length * 220}ms` }}>
        <Button tabIndex={-1} className="pointer-events-none h-9 rounded-lg bg-[#0a84ff] px-3.5 text-white shadow-none">
          <GitMerge data-icon="inline-start" />
          Merge into main
        </Button>
        <Button tabIndex={-1} variant="glass" className="pointer-events-none h-9 rounded-lg px-3.5 font-mono text-xs">
          <span className="size-1.5 rounded-full bg-[#30d158] shadow-[0_0_8px_#30d158]" />
          localhost:3001
          <ArrowUpRight data-icon="inline-end" />
        </Button>
      </div>
    </div>
  )
}
