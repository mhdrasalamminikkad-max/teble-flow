import type { Metadata, Viewport } from "next";
import "./globals.css";
import "./access.css";
import "./redesign.css";
import NativeShell from "@/components/tableflow/native-shell";

export const metadata: Metadata = {
  title: "TABLEFLOW — A better dining experience",
  description: "Your table. Your menu. Your flow. Order, follow your meal and view your bill with TABLEFLOW.",
  appleWebApp: { capable: true, title: "TABLEFLOW", statusBarStyle: "default" },
  manifest: "/manifest.webmanifest",
  icons: {
    apple: "/icons/icon-180.png",
    icon: "/favicon.svg",
    shortcut: "/favicon.svg",
  },
};

export const viewport: Viewport = { width: "device-width", initialScale: 1, viewportFit: "cover", themeColor: "#fafaf6" };

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body className="antialiased">{children}<NativeShell/></body>
    </html>
  );
}
