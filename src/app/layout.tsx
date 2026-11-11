import { OlhoSenha } from "@/features/ui/OlhoSenha";
import { FonteUsuario } from "@/features/marca/FonteUsuario";
import type { Metadata, Viewport } from "next";
import "@fontsource-variable/archivo/wdth.css";
import "maplibre-gl/dist/maplibre-gl.css";
import "./globals.css";
import { ProvedorTema, scriptTema } from "@/features/tema/tema";
import { RolagemLateral } from "@/features/ui/RolagemLateral";

export const metadata: Metadata = {
  title: "Delibra",
  description: "Coletas e entregas com rastreamento em tempo real",
  appleWebApp: { capable: true, title: "Delibra", statusBarStyle: "black-translucent" },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  themeColor: [
    { media: "(prefers-color-scheme: dark)", color: "#08080a" },
    { media: "(prefers-color-scheme: light)", color: "#f6f2e9" },
  ],
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="pt-BR" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: scriptTema }} />
      </head>
      <body>
        <OlhoSenha />
        <FonteUsuario />
        <ProvedorTema>{children}</ProvedorTema>
        <RolagemLateral />
      </body>
    </html>
  );
}
