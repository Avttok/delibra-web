import { timingSafeEqual } from "node:crypto";
import { adminConfigurado, supabaseAdmin } from "@/lib/supabase/admin";
import { emitirNota, enviarEmail, enviarWhatsapp } from "@/lib/integracoes/modulos";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Aviso = { id: number; canal: "email" | "whatsapp" | "nota"; para: string | null; assunto: string | null; corpo: Record<string, unknown>; empresa: string | null; nf_provedor: string; nf_cnpj: string; nf_servico: string };

const moeda = (v: unknown) => Number(v ?? 0).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
const data = (v: unknown) => (typeof v === "string" ? v.split("-").reverse().join("/") : "");
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

/** O texto de cada e-mail, curto e no tom do app. */
function html(a: Aviso) {
  const c = a.corpo, emp = esc(a.empresa ?? "Delibra"), nome = esc(c.nome);
  const corpo = (() => {
    switch (c.modelo) {
      case "cadastro": return `<p>Olá, ${nome}!</p><p>Seu cadastro na <strong>${emp}</strong> foi aprovado. Você já pode entrar e fazer pedidos.</p>`;
      case "fatura": return `<p>Olá, ${nome}.</p><p>A fatura <strong>#${esc(c.numero)}</strong> (${data(c.inicio)} a ${data(c.fim)}) foi emitida: <strong>${moeda(c.total)}</strong>${c.vencimento ? `, vence em ${data(c.vencimento)}` : ""}.</p><p>Os detalhes estão no site, em Faturas.</p>`;
      case "entregue": return `<p>Olá, ${nome}.</p><p>O pedido <strong>#${esc(c.numero)}</strong> foi entregue.</p>`;
      case "devolucao": return `<p>Olá, ${nome}.</p><p>O pedido <strong>#${esc(c.numero)}</strong> (${moeda(c.valor)}) foi cancelado.</p>`
        + (c.devolver == null ? "<p>A empresa vai falar com você sobre a devolução.</p>" : Number(c.devolver) > 0 ? `<p>Vamos devolver <strong>${moeda(c.devolver)}</strong>.</p>` : "<p>Pelo combinado, este cancelamento não tem devolução.</p>");
      default: return `<p>${esc(a.assunto)}</p>`;
    }
  })();
  return `<div style="font-family:system-ui,sans-serif;font-size:15px;color:#16130c;max-width:520px">${corpo}<p style="color:#8a8270;font-size:12px">${emp}</p></div>`;
}

function segredoValido(recebido: string | null): boolean {
  const esperado = process.env.PUSH_SECRET;
  if (!esperado || !recebido) return false;
  const a = Buffer.from(recebido), b = Buffer.from(esperado);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** Chamado pelo banco a cada minuto quando há algo na fila: manda pelos módulos conectados. */
export async function POST(req: Request) {
  if (!adminConfigurado()) return Response.json({ erro: "servidor_sem_chave" }, { status: 503 });
  const segredo = req.headers.get("x-pwex-secret");
  const admin = supabaseAdmin();
  const doBanco = segredo ? (await admin.rpc("push_secret_confere", { p: segredo })).data === true : false;
  if (!segredoValido(segredo) && !doBanco) return Response.json({ erro: "nao_autorizado" }, { status: 401 });

  const { data: fila, error } = await admin.rpc("avisos_externos_pegar", { p_limite: 20 });
  if (error) return Response.json({ erro: "falha_fila" }, { status: 500 });
  let enviados = 0;
  for (const a of (fila ?? []) as Aviso[]) {
    let r: { ok: boolean; motivo?: string; erro?: string; dados?: unknown };
    if (a.canal === "email") r = await enviarEmail({ para: a.para!, assunto: a.assunto ?? "Aviso", html: html(a) });
    else if (a.canal === "whatsapp") r = await enviarWhatsapp({ para: a.para!, modelo: String(a.corpo.modelo ?? "rastreio_entrega"), variaveis: (a.corpo.variaveis as string[]) ?? [] });
    else r = !a.nf_cnpj || !a.nf_servico ? { ok: false, motivo: "erro", erro: "Faltam o CNPJ do prestador e o código do serviço (Ajustes → Nota fiscal)." }
      : await emitirNota(a.nf_provedor, { referencia: String(a.corpo.referencia), prestadorCnpj: a.nf_cnpj, codigoServico: a.nf_servico,
          tomador: { documento: String(a.corpo.documento ?? ""), nome: String(a.corpo.nome ?? ""), email: (a.corpo.email as string) ?? undefined },
          valor: Number(a.corpo.valor ?? 0), descricao: String(a.corpo.descricao ?? "") });
    const status = r.ok ? "enviado" : r.motivo === "nao_conectado" ? "sem_conexao" : "erro";
    if (r.ok) enviados++;
    const ref = r.ok ? String((r.dados as { id?: string; messages?: { id: string }[] } | undefined)?.id ?? (r.dados as { messages?: { id: string }[] } | undefined)?.messages?.[0]?.id ?? "") : null;
    await admin.rpc("avisos_externos_resultado", { p_id: a.id, p_status: status, p_erro: r.ok ? null : (r.erro ?? r.motivo ?? null), p_ref: ref });
  }
  return Response.json({ ok: true, enviados, total: (fila ?? []).length });
}
