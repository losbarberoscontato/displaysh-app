import type { Metadata, Viewport } from "next";

export const metadata: Metadata = {
  applicationName: "AteliePro",
  manifest: "/ateliepro/manifest.webmanifest",
  appleWebApp: { capable: true, title: "AteliePro", statusBarStyle: "black-translucent" },
  icons: { icon: [{ url: "/ateliepro/mark.png", type: "image/png" }], apple: "/ateliepro/mark.png" },
};

export const viewport: Viewport = { themeColor: "#4A3024" };

export default function AtelieProLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return children;
}
