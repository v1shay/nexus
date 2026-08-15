import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export const metadata: Metadata = {
  title: "Nexus Tool Validation",
  description: "Live Experimental-branch tool validation receipts for Nexus.",
  openGraph: {
    title: "Nexus Tool Validation",
    description: "Experimental branch • real receipts",
    images: [{ url: "/og.png", width: 1680, height: 945, alt: "Nexus Tool Validation" }],
  },
  twitter: { card: "summary_large_image", title: "Nexus Tool Validation", images: ["/og.png"] },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className={`${geistSans.variable} ${geistMono.variable}`}>{children}</body>
    </html>
  );
}
