import { adminConfigurado, supabaseAdmin } from "@/lib/supabase/admin";

export const runtime = "nodejs";

/** App instalável do cliente com o nome, o ícone e a cor da empresa (/api/manifest?empresa=slug). */
export async function GET(req: Request) {
  const slug = new URL(req.url).searchParams.get("empresa")?.slice(0, 60) ?? "";
  let nome = "Delibra", cor = "#d4af37", logo: string | null = null;
  if (slug && adminConfigurado()) {
    const { data } = await supabaseAdmin().rpc("marca_publica", { p_slug: slug });
    const m = data as { nome?: string; nome_app?: string | null; cor?: string | null; logo?: string | null } | null;
    if (m?.nome) { nome = m.nome_app || m.nome; cor = m.cor || cor; logo = m.logo ?? null; }
  }
  const icones = logo ? [{ src: logo, sizes: "512x512", type: "image/png", purpose: "any" }] : [{ src: "/icon.png", sizes: "512x512", type: "image/png" }];
  return Response.json({
    name: nome, short_name: nome.slice(0, 12), start_url: `/entrar${slug ? `?empresa=${encodeURIComponent(slug)}` : ""}`, scope: "/",
    display: "standalone", background_color: "#0b0b0c", theme_color: cor, icons: icones,
  }, { headers: { "content-type": "application/manifest+json", "cache-control": "public, max-age=3600" } });
}
