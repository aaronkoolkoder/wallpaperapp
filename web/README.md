# Diorama — marketing site

Landing page for the macOS app in the parent directory. Separate from the app entirely: the app
is Swift/Metal and shares no code with this.

## Stack

Next.js 15 (App Router) · TypeScript · Tailwind CSS · shadcn conventions · framer-motion ·
lucide-react

## Run

```bash
npm install
npm run dev
```

```bash
npm run build
```

## Layout

Follows the shadcn project structure, which matters for a specific reason: the `shadcn` CLI
writes generated components to the `ui` alias from `components.json`. With that set to
`@/components/ui`, `npx shadcn@latest add <component>` lands files where imports already expect
them. Putting them anywhere else means every generated component needs its import path corrected
by hand.

```
app/
  page.tsx        landing page
  layout.tsx
  globals.css     Tailwind entry
components/ui/    shadcn target — generated and vendored components
lib/utils.ts      cn() helper (clsx + tailwind-merge)
public/           screenshots rendered by the app itself
```

## Images

`public/` holds real output from the app — a scene render and the menu bar interface — rather
than stock photography. It is a product page, so it should show the product.

Regenerate them from the repository root:

```bash
swift run wetool scene render <wallpaper-dir> web/public/hero-snow.png 1400x720
```

## Adding shadcn components

```bash
npx shadcn@latest add button
```
