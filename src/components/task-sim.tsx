"use client"

import { useEffect, useState } from "react"
import { Check, GitMerge } from "lucide-react"
import { cn } from "@/lib/utils"

const TITLES = [
  "Wishlist button",
  "Dark mode for product pages",
  "⌘K product search",
  "Faster hero images",
  "Empty cart illustration",
  "Saved addresses at checkout",
  "Sticky header on scroll",
  "Fix cart total rounding",
  "Auto-width table column",
]

type Status = "working" | "input" | "ready" | "merged"
const CYCLE: Status[] = ["working", "working", "working", "input", "working", "working", "ready", "ready", "ready", "merged", "merged"]
const ROWS = 5
// This row stays "ready" and selected; a line connects it to TaskDetails.
const PINNED = 1

export function TaskSim() {
  const [tick, setTick] = useState(0)

  useEffect(() => {
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return
    const id = setInterval(() => setTick((t) => t + 1), 1400)
    return () => clearInterval(id)
  }, [])

  return (
    <ul className="divide-y divide-white/[0.06]">
      {Array.from({ length: ROWS }, (_, i) => {
        const pinned = i === PINNED
        const t = tick + i * 2 + (i % 2) * 3
        const round = Math.floor(t / CYCLE.length)
        const status = pinned ? "ready" : CYCLE[t % CYCLE.length]
        // Each cycling row alternates between its own two titles, so rows never show the same one
        const k = i < PINNED ? i : i - 1
        const id = pinned ? 101 : 102 + ((round * (ROWS - 1) + k) % 90)
        const title = pinned ? "Tighter board spacing" : TITLES[k * 2 + (round % 2)]
        return (
          <li
            key={i}
            className={cn(
              "relative flex h-14 items-center gap-3 px-5",
              // Connector: runs from the selected row across the grid gap to the details panel
              pinned &&
                "bg-white/[0.05] lg:after:absolute lg:after:top-1/2 lg:after:left-full lg:after:h-px lg:after:w-[calc(3rem+1px)] lg:after:bg-[#30d158] lg:after:shadow-[0_0_8px_#30d158] lg:before:absolute lg:before:top-1/2 lg:before:left-full lg:before:z-10 lg:before:size-2 lg:before:-translate-x-1/2 lg:before:-translate-y-1/2 lg:before:rounded-full lg:before:bg-[#30d158]"
            )}
          >
            <StatusIcon status={status} />
            <span
              key={title}
              className={cn(
                "animate-in fade-in slide-in-from-bottom-1 flex-1 truncate text-[15px] duration-500",
                status === "merged" && "text-muted-foreground"
              )}
            >
              {title}
            </span>
            <Meta status={status} id={id} />
          </li>
        )
      })}
    </ul>
  )
}

function StatusIcon({ status }: { status: Status }) {
  const base = "grid size-[18px] shrink-0 place-items-center rounded-full transition-colors duration-500"
  if (status === "working")
    return <span className={cn(base, "border-2 border-white/15 border-t-white/80 animate-spin")} />
  if (status === "input")
    return <span className={cn(base, "bg-[#0a84ff] text-[11px] font-bold text-white")}>?</span>
  return (
    <span className={cn(base, status === "ready" ? "bg-[#30d158] text-black" : "bg-white/15 text-white/60")}>
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
        <GitMerge className="size-3.5" /> main
      </span>
    )
  if (status === "input") return <span className={cn(cls, "text-[#0a84ff]")}>needs input</span>
  return <span className={cn(cls, "text-muted-foreground")}>shift/{id}</span>
}
