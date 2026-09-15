import Image from "next/image";
import { Cpu, MonitorSmartphone, ShieldCheck, Sparkles, Zap } from "lucide-react";
import { ContainerScroll } from "@/components/ui/container-scroll-animation";

const features = [
  {
    icon: Sparkles,
    title: "Real scenes, not recordings",
    body: "Renders the actual Wallpaper Engine scene format in Metal — layers, particles, parallax and post-processing, all live. Not a video capture of one.",
  },
  {
    icon: Zap,
    title: "Close to free",
    body: "0.1% CPU for a 900-particle scene. Nothing at all when a window covers it, which is most of the time you are actually working.",
  },
  {
    icon: ShieldCheck,
    title: "Nothing leaves your Mac",
    body: "No account, no server, no telemetry. Web wallpapers are blocked from reaching the network entirely.",
  },
  {
    icon: MonitorSmartphone,
    title: "Every display",
    body: "A wallpaper per display, each suspending independently when it is covered or a fullscreen app takes over.",
  },
  {
    icon: Cpu,
    title: "Honest about limits",
    body: "When a wallpaper uses something we cannot draw yet, it says so by name instead of quietly looking wrong.",
  },
];

export default function Home() {
  return (
    <main className="min-h-screen bg-white dark:bg-[#0B0B0F]">
      <div className="flex flex-col overflow-hidden">
        <ContainerScroll
          titleComponent={
            <>
              <h1 className="text-4xl font-semibold text-black dark:text-white">
                Your Wallpaper Engine library <br />
                <span className="text-4xl md:text-[6rem] font-bold mt-1 leading-none">
                  running on macOS
                </span>
              </h1>
              <p className="mx-auto mt-6 max-w-xl text-base text-neutral-600 dark:text-neutral-400">
                Scene wallpapers rendered natively in Metal. Entirely offline.
              </p>
            </>
          }
        >
          <Image
            src="/hero-snow.png"
            alt="A snowfall scene wallpaper rendered natively by Diorama"
            height={720}
            width={1400}
            className="mx-auto h-full rounded-2xl object-cover object-left-top"
            draggable={false}
            priority
          />
        </ContainerScroll>
      </div>

      <section className="mx-auto max-w-6xl px-6 pb-32">
        <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
          {features.map(({ icon: Icon, title, body }) => (
            <div
              key={title}
              className="rounded-2xl border border-neutral-200 bg-neutral-50 p-6 dark:border-neutral-800 dark:bg-neutral-900/50"
            >
              <Icon className="h-5 w-5 text-neutral-900 dark:text-neutral-100" aria-hidden />
              <h3 className="mt-4 font-semibold text-neutral-900 dark:text-neutral-100">
                {title}
              </h3>
              <p className="mt-2 text-sm leading-relaxed text-neutral-600 dark:text-neutral-400">
                {body}
              </p>
            </div>
          ))}
        </div>

        <p className="mx-auto mt-16 max-w-2xl text-center text-xs text-neutral-500 dark:text-neutral-500">
          Diorama is a player for wallpapers you already own. It bundles no Wallpaper Engine
          content or code, and is not affiliated with, or endorsed by, Wallpaper Engine or Valve.
        </p>
      </section>
    </main>
  );
}
