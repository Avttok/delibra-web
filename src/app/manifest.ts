import type { MetadataRoute } from "next";

/** Permite "Adicionar à tela inicial": o painel abre como app, sem barra do navegador. */
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "Delibra · Gestor",
    short_name: "Delibra",
    description: "Painel do gestor: corridas, mapa e equipe",
    start_url: "/gestor/mapa",
    scope: "/",
    display: "standalone",
    orientation: "any",
    background_color: "#08080a",
    theme_color: "#08080a",
    icons: [
      { src: "/marca/logo-192.png", sizes: "192x192", type: "image/png" },
      { src: "/marca/logo-512.png", sizes: "512x512", type: "image/png" },
      { src: "/marca/logo-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
  };
}
