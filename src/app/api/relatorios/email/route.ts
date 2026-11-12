import { clienteDoUsuario, gestorDaRequisicao } from "@/lib/supabase/admin";
import { enviarEmail } from "@/lib/integracoes/modulos";
import { COLUNAS_RELATORIO, paraCsv, traduzirLinhas } from "@/features/financeiro/relatorioDados";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Gestor: manda o relatório do período por e-mail, com a planilha anexada (precisa do e-mail conectado). */
export async function POST(req: Request) {
  const gestor = await gestorDaRequisicao(req);
  if (!gestor) return Response.json({ erro: "apenas_gestor" }, { status: 403 });
  let c: { tipo?: string; de?: string; ate?: string; para?: string };
  try { c = await req.json(); } catch { return Response.json({ erro: "json_invalido" }, { status: 400 }); }
  const para = String(c.para ?? "").trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(para)) return Response.json({ erro: "email_invalido" }, { status: 400 });
  const t = COLUNAS_RELATORIO[c.tipo as keyof typeof COLUNAS_RELATORIO];
  if (!t || !/^\d{4}-\d{2}-\d{2}$/.test(String(c.de)) || !/^\d{4}-\d{2}-\d{2}$/.test(String(c.ate))) return Response.json({ erro: "dados_invalidos" }, { status: 400 });
  const sb = clienteDoUsuario(req)!;
  const { data, error } = await sb.rpc("relatorio", { p_tipo: c.tipo, p_de: c.de, p_ate: c.ate });
  if (error) return Response.json({ erro: "falha_relatorio" }, { status: 400 });
  const linhas = traduzirLinhas((data ?? []) as Record<string, string | number | null>[]);
  const periodo = `${String(c.de).split("-").reverse().join("/")} a ${String(c.ate).split("-").reverse().join("/")}`;
  const csv = paraCsv(t.colunas, linhas);
  const r = await enviarEmail({
    para, assunto: `Relatório de ${t.r.toLowerCase()} · ${periodo}`,
    html: `<p>Segue o relatório de <strong>${t.r.toLowerCase()}</strong> de ${periodo} (${linhas.length} linha(s)).</p><p>A planilha vai anexada e abre direto no Excel.</p>`,
    anexos: [{ nome: `relatorio-${c.tipo}-${c.de}-a-${c.ate}.csv`, conteudo: Buffer.from(csv, "utf-8").toString("base64") }],
  });
  if (!r.ok) return Response.json({ erro: r.motivo === "nao_conectado" ? "nao_conectado" : "falha_envio" }, { status: r.motivo === "nao_conectado" ? 409 : 502 });
  return Response.json({ ok: true });
}
