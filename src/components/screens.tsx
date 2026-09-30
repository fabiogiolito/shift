"use client"

import { useState } from "react"
import Image from "next/image"
import { Moon, Sun } from "lucide-react"
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs"

const SHOTS = [
  ["01-ready-to-test", "Ready to test"],
  ["02-working", "Working"],
  ["03-needs-input", "Needs input"],
  ["04-codex-project", "Codex"],
]

const trigger =
  "h-9 rounded-full px-4 text-[13px] data-active:bg-white/10 data-active:text-foreground dark:data-active:border-white/10 dark:data-active:bg-white/10"

export function Screens() {
  const [shot, setShot] = useState(SHOTS[0][0])
  const [theme, setTheme] = useState("dark")

  return (
    <div className="flex flex-col items-center gap-10">
      <div className="flex flex-wrap items-center justify-center gap-3">
        <Tabs value={shot} onValueChange={setShot}>
          <TabsList className="h-11! rounded-full border border-white/10 bg-white/[0.03] p-1 backdrop-blur">
            {SHOTS.map(([id, label]) => (
              <TabsTrigger key={id} value={id} className={trigger}>
                {label}
              </TabsTrigger>
            ))}
          </TabsList>
        </Tabs>
        <Tabs value={theme} onValueChange={setTheme}>
          <TabsList className="h-11! rounded-full border border-white/10 bg-white/[0.03] p-1 backdrop-blur">
            <TabsTrigger value="dark" aria-label="Dark" className={trigger}>
              <Moon />
            </TabsTrigger>
            <TabsTrigger value="light" aria-label="Light" className={trigger}>
              <Sun />
            </TabsTrigger>
          </TabsList>
        </Tabs>
      </div>

      <div className="relative w-full">
        {/* Render every shot stacked so switching is an instant crossfade */}
        {SHOTS.flatMap(([id, label]) =>
          ["dark", "light"].map((t) => {
            const active = id === shot && t === theme
            return (
              <Image
                key={t + id}
                src={`/screens/${t}-${id}.png`}
                alt={`Shift — ${label}`}
                width={3104}
                height={2024}
                sizes="(min-width: 1280px) 1200px, 100vw"
                className={`w-full transition-all duration-500 ${active ? "relative opacity-100" : "pointer-events-none absolute inset-0 scale-[0.99] opacity-0"}`}
              />
            )
          })
        )}
      </div>
    </div>
  )
}
