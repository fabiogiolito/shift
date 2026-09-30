"use client"

import { useEffect, useRef, useState } from "react"
import { Check, GitMerge } from "lucide-react"
import { cn } from "@/lib/utils"

type Status = "working" | "input" | "ready" | "merged"

// Every task starts out working, then moves through its [tick, status] steps and stays on the last one.
// The pinned one is ready from the start; a line connects it to TaskDetails.
const TASKS: { id: number; title: string; steps: [number, Status][]; pinned?: boolean }[] = [
  { id: 102, title: "Wishlist button", steps: [[2, "ready"], [5, "merged"]] },
  { id: 101, title: "Tighter board spacing", steps: [[0, "ready"]], pinned: true },
  { id: 103, title: "Empty cart illustration", steps: [[4, "input"]] },
  { id: 104, title: "Dark mode for product pages", steps: [[7, "ready"]] },
  { id: 105, title: "⌘K product search", steps: [] },
]
const LAST = 7

export function TaskSim() {
  const ref = useRef<HTMLUListElement>(null)
  const [tick, setTick] = useState(0)

  // Start once the list scrolls into view, stop when everything has settled
  useEffect(() => {
    let id: ReturnType<typeof setInterval>
    const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches
    const io = new IntersectionObserver(
      ([e]) => {
        if (!e.isIntersecting) return
        io.disconnect()
        if (reduced) return setTick(LAST)
        id = setInterval(() => setTick((t) => Math.min(t + 1, LAST)), 1100)
      },
      { threshold: 0.6 }
    )
    if (ref.current) io.observe(ref.current)
    return () => {
      io.disconnect()
      clearInterval(id)
    }
  }, [])

  return (
    <ul ref={ref} className="divide-y divide-white/[0.06]">
      {TASKS.map(({ id, title, steps, pinned }) => {
        const status = steps.findLast(([at]) => tick >= at)?.[1] ?? "working"
        return (
          <li
            key={id}
            className={cn(
              "relative flex h-14 items-center gap-3 px-5",
              // Connector: runs from the selected row across the grid gap to the details panel
              pinned &&
                "bg-white/[0.05] lg:after:absolute lg:after:top-1/2 lg:after:left-full lg:after:h-px lg:after:w-[calc(3rem+1px)] lg:after:bg-[#30d158] lg:after:shadow-[0_0_8px_#30d158] lg:before:absolute lg:before:top-1/2 lg:before:left-full lg:before:z-10 lg:before:size-2 lg:before:-translate-x-1/2 lg:before:-translate-y-1/2 lg:before:rounded-full lg:before:bg-[#30d158]"
            )}
          >
            <StatusIcon key={status} status={status} />
            <span className={cn("flex-1 truncate text-[15px] transition-colors duration-500", status === "merged" && "text-muted-foreground")}>
              {title}
            </span>
            <Meta key={status + "meta"} status={status} id={id} />
          </li>
        )
      })}
    </ul>
  )
}

function StatusIcon({ status }: { status: Status }) {
  const base = "grid size-[18px] shrink-0 place-items-center rounded-full"
  if (status === "working")
    return <span className={cn(base, "animate-spin border-2 border-white/15 border-t-white/80")} />
  if (status === "input")
    return <span className={cn(base, "animate-in zoom-in-50 bg-[#0a84ff] text-[11px] font-bold text-white duration-300")}>?</span>
  return (
    <span className={cn(base, "animate-in duration-300", status === "ready" ? "zoom-in-50 bg-[#30d158] text-black" : "fade-in bg-white/15 text-white/60")}>
      <Check className="size-3" strokeWidth={3.5} />
    </span>
  )
}

function Meta({ status, id }: { status: Status; id: number }) {
  const cls = "animate-in fade-in font-mono text-xs duration-500"
  if (status === "ready")
    return (
      <span className={cn(cls, "flex items-center gap-1.5 rounded-full border border-white/10 bg-white/[0.04] px-2.5 py-1 text-foreground")}>
        <span className="size-1.5 rounded-full bg-[#30d158] shadow-[0_0_8px_#30d158]" />
        localhost:{3000 + (id % 100)}
      </span>
    )
  if (status === "merged")
    return (
      <span className={cn(cls, "flex items-center gap-1 text-muted-foreground")}>
        <GitMerge className="size-3.5" /> Merged
      </span>
    )
  if (status === "input") return <span className={cn(cls, "text-[#0a84ff]")}>needs input</span>
  return <span className={cn(cls, "text-muted-foreground")}>shift/{id}</span>
}
