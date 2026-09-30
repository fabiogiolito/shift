import Image from "next/image"
import Link from "next/link"
import { ArrowRight, Download } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { Rails } from "@/components/rails"
import { TaskSim } from "@/components/task-sim"
import { Terminal } from "@/components/terminal"
import { Screens } from "@/components/screens"
import icon from "./icon.png"

const REPO = "https://github.com/fabiogiolito/shift"
const DOWNLOAD = `${REPO}/releases/latest`

function DownloadButton() {
  return (
    <Button size="xl" nativeButton={false} render={<a href={DOWNLOAD} />}>
      <Download data-icon="inline-start" />
      Download for Mac
    </Button>
  )
}

function Panel({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="reveal overflow-hidden rounded-2xl border border-white/10 bg-white/[0.02] shadow-2xl shadow-black/50 backdrop-blur">
      <div className="flex items-center gap-2 border-b border-white/[0.06] px-5 py-3">
        <span className="size-2.5 rounded-full bg-white/10" />
        <span className="size-2.5 rounded-full bg-white/10" />
        <span className="size-2.5 rounded-full bg-white/10" />
        <span className="ml-3 font-mono text-xs text-muted-foreground">{label}</span>
      </div>
      {children}
    </div>
  )
}

// Hero copy options, picked with ?hero=N from the numbered links in the nav.
// [headline, highlighted part, subline]
const HEROES = [
  ["Ship in", "parallel.", "Hand tasks to AI agents. Each gets its own branch, worktree and dev server. You just test and merge."],
  ["Your backlog,", "all at once.", "Give every task to an agent. Each one works on its own branch with its own dev server."],
  ["Describe.", "Test. Merge.", "Agents do the part in between, each on its own branch, worktree and dev server."],
  ["Tasks,", "not chats.", "No transcripts to read, no terminals to watch. Write what you want and get a branch ready to test."],
  ["Stop watching", "agents work.", "Hand off the task and leave. Come back when it is ready to test in your browser."],
  ["Every task,", "its own branch.", "And its own worktree, agent and dev server. Nothing collides, everything runs at once."],
  ["Parallel agents,", "without the mess.", "Worktrees, branches, ports, commits and cleanup are handled for you."],
  ["Come back to", "a checkmark.", "Describe a task and walk away. It is built on its own branch and running on localhost when you return."],
]

const STEPS = ["Describe", "Agent works", "Test", "Merge"]

export default async function Home({ searchParams }: PageProps<"/">) {
  const pick = Number((await searchParams).hero) || 1
  const [lead, accent, sub] = HEROES[pick - 1] ?? HEROES[0]

  return (
    <main className="relative">
      {/* Nav */}
      <header className="fixed inset-x-0 top-0 z-50 border-b border-white/[0.06] bg-background/60 backdrop-blur-xl">
        <nav className="mx-auto flex h-16 max-w-6xl items-center justify-between px-6">
          <a href="#" className="flex items-center gap-2.5 font-semibold tracking-tight">
            <Image src={icon} alt="" width={28} height={28} />
            Shift
          </a>
          <div className="flex items-center gap-0.5 font-mono text-xs">
            {HEROES.map((_, i) => (
              <Link
                key={i}
                href={`?hero=${i + 1}`}
                scroll={false}
                aria-current={pick === i + 1}
                className="grid size-7 place-items-center rounded-full text-muted-foreground transition-colors hover:text-foreground aria-[current=true]:bg-white/10 aria-[current=true]:text-foreground"
              >
                {i + 1}
              </Link>
            ))}
          </div>
          <div className="flex items-center gap-2">
            <Button variant="ghost" size="lg" className="hidden rounded-full text-muted-foreground sm:inline-flex" nativeButton={false} render={<a href={REPO} />}>
              GitHub
            </Button>
            <Button size="lg" className="rounded-full px-4" nativeButton={false} render={<a href={DOWNLOAD} />}>
              Download
            </Button>
          </div>
        </nav>
      </header>

      {/* Hero */}
      <section className="relative isolate px-6 pt-40 text-center sm:pt-48">
        <div className="grid-bg absolute inset-0 -z-10" />
        <Rails className="animate-drift absolute top-10 left-1/2 -z-10 w-[900px] max-w-none -translate-x-1/2 opacity-40 blur-[120px]" />

        <Badge
          variant="outline"
          className="animate-rise h-8 gap-2 rounded-full border-white/10 bg-white/[0.03] px-3.5 font-mono text-xs text-muted-foreground backdrop-blur"
        >
          <span className="size-1.5 rounded-full bg-[#30d158] shadow-[0_0_8px_#30d158]" />
          Claude Code · Codex · macOS
        </Badge>

        <h1 className="animate-rise mx-auto mt-8 max-w-5xl text-balance text-6xl leading-[0.95] font-semibold tracking-[-0.045em] [animation-delay:100ms] sm:text-8xl lg:text-[128px]">
          {lead} <span className="text-rails">{accent}</span>
        </h1>

        <p className="animate-rise mx-auto mt-8 max-w-xl text-lg text-balance text-muted-foreground [animation-delay:200ms] sm:text-xl">
          {sub}
        </p>

        <div className="animate-rise mt-10 flex flex-wrap items-center justify-center gap-3 [animation-delay:300ms]">
          <DownloadButton />
          <Button variant="glass" size="xl" nativeButton={false} render={<a href="#how" />}>
            How it works
            <ArrowRight data-icon="inline-end" />
          </Button>
        </div>

        <div className="animate-rise relative mx-auto mt-20 max-w-6xl [animation-delay:400ms]">
          <div className="absolute inset-x-[10%] top-[10%] bottom-0 -z-10 rounded-full bg-gradient-to-r from-rail-1/30 via-rail-2/30 to-rail-3/30 blur-[100px]" />
          <Image
            src="/screens/dark-01-ready-to-test.png"
            alt="Shift app showing parallel tasks"
            width={3104}
            height={2024}
            priority
            sizes="(min-width: 1152px) 1152px, 100vw"
            className="tilt w-full"
          />
        </div>
      </section>

      {/* What Shift handles */}
      <section id="how" className="mx-auto max-w-6xl scroll-mt-24 px-6 pt-32 sm:pt-44">
        <h2 className="reveal mx-auto max-w-3xl text-center text-4xl font-semibold tracking-[-0.035em] text-balance sm:text-6xl">
          You write the prompt.
          <br />
          <span className="text-muted-foreground">Shift does the rest.</span>
        </h2>

        <div className="mt-16 grid gap-5 lg:grid-cols-2">
          <Panel label="~/Sites/storefront">
            <Terminal />
          </Panel>
          <Panel label="Storefront · 5 tasks">
            <TaskSim />
          </Panel>
        </div>

        <ol className="reveal mt-20 grid grid-cols-2 gap-px overflow-hidden rounded-2xl border border-white/10 bg-white/10 sm:grid-cols-4">
          {STEPS.map((step, i) => (
            <li key={step} className="group bg-background p-6 transition-colors hover:bg-white/[0.03]">
              <span className="font-mono text-xs text-muted-foreground">0{i + 1}</span>
              <p className="mt-10 text-xl font-medium tracking-tight transition-transform group-hover:translate-x-1">{step}</p>
            </li>
          ))}
        </ol>
      </section>

      {/* Screens */}
      <section className="mx-auto max-w-6xl px-6 pt-32 sm:pt-44">
        <h2 className="reveal mb-12 text-center text-4xl font-semibold tracking-[-0.035em] sm:text-6xl">
          Calm by design.
        </h2>
        <div className="reveal">
          <Screens />
        </div>
      </section>

      {/* CTA */}
      <section className="relative isolate px-6 py-40 text-center sm:py-56">
        <Rails className="absolute top-1/2 left-1/2 -z-10 w-[700px] max-w-none -translate-x-1/2 -translate-y-1/2 opacity-25 blur-[100px]" />
        <div className="reveal">
          <Image src={icon} alt="Shift" width={128} height={128} className="mx-auto drop-shadow-[0_20px_60px_rgba(255,141,40,0.35)]" />
          <h2 className="mx-auto mt-10 max-w-3xl text-4xl font-semibold tracking-[-0.035em] text-balance sm:text-6xl">
            Leave. Come back to a <span className="text-rails">checkmark.</span>
          </h2>
          <div className="mt-10 flex justify-center">
            <DownloadButton />
          </div>
          <p className="mt-5 font-mono text-xs text-muted-foreground">Free & open source · macOS 26+</p>
        </div>
      </section>

      <footer className="border-t border-white/[0.06] px-6 py-8">
        <div className="mx-auto flex max-w-6xl items-center justify-between font-mono text-xs text-muted-foreground">
          <span>Shift</span>
          <a href={REPO} className="hover:text-foreground">github.com/fabiogiolito/shift</a>
        </div>
      </footer>
    </main>
  )
}
