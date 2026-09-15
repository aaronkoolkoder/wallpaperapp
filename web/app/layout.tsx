import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Diorama — Live wallpapers for macOS",
  description:
    "Plays Wallpaper Engine scene wallpapers natively on macOS, rendered in Metal. Fully offline.",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="antialiased">{children}</body>
    </html>
  );
}
