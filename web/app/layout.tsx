import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Multi-Speaker",
  description: "One song, every speaker in the house",
  appleWebApp: { capable: true, statusBarStyle: "black-translucent", title: "Speakers" },
};

export const viewport: Viewport = {
  themeColor: "#0b0b0f",
  width: "device-width",
  initialScale: 1,
  // Keeps the layout under the notch and stops pinch-zoom on the controls.
  maximumScale: 1,
  viewportFit: "cover",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
