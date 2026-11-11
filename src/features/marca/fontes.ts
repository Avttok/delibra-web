"use client";

import "@fontsource/inter/400.css"; import "@fontsource/inter/700.css"; import "@fontsource/inter/800.css";
import "@fontsource/poppins/400.css"; import "@fontsource/poppins/700.css"; import "@fontsource/poppins/800.css";
import "@fontsource/montserrat/400.css"; import "@fontsource/montserrat/700.css"; import "@fontsource/montserrat/800.css";
import "@fontsource/nunito/400.css"; import "@fontsource/nunito/700.css"; import "@fontsource/nunito/800.css";
import "@fontsource/space-grotesk/400.css"; import "@fontsource/space-grotesk/700.css";
import "@fontsource/playfair-display/400.css"; import "@fontsource/playfair-display/700.css"; import "@fontsource/playfair-display/800.css";
import "@fontsource/oswald/400.css"; import "@fontsource/oswald/700.css";

/** As mesmas fontes do app (o nome guardado é igual: INTER, POPPINS…). */
export const FONTES: { chave: string; rotulo: string; css: string }[] = [
  { chave: "ARCHIVO", rotulo: "Archivo (padrão)", css: '"Archivo Variable"' },
  { chave: "INTER", rotulo: "Inter", css: '"Inter"' },
  { chave: "POPPINS", rotulo: "Poppins", css: '"Poppins"' },
  { chave: "MONTSERRAT", rotulo: "Montserrat", css: '"Montserrat"' },
  { chave: "NUNITO", rotulo: "Nunito", css: '"Nunito"' },
  { chave: "SPACE_GROTESK", rotulo: "Space Grotesk", css: '"Space Grotesk"' },
  { chave: "PLAYFAIR", rotulo: "Playfair Display", css: '"Playfair Display"' },
  { chave: "OSWALD", rotulo: "Oswald", css: '"Oswald"' },
];
export const cssFonte = (chave: string | null | undefined) => (FONTES.find((f) => f.chave === chave?.toUpperCase()) ?? FONTES[0]).css;

const CHAVE = "delibra_fonte";
/** Fonte do site para esta pessoa (fica neste navegador). */
export function lerFonteUsuario(): string { try { return localStorage.getItem(CHAVE) ?? "ARCHIVO"; } catch { return "ARCHIVO"; } }
export function aplicarFonteUsuario(chave: string) {
  try { localStorage.setItem(CHAVE, chave); } catch { /* sem armazenamento */ }
  document.documentElement.style.setProperty("--fonte-app", cssFonte(chave));
}
