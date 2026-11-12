/**
 * Módulos de integração prontos e desligados ("conectar depois").
 * Cada um só funciona quando a chave existe no servidor (variável do Vercel) e o Dev escolhe o provedor em Ajustes.
 * Nada aqui falha o fluxo principal: sem chave, devolve { ok: false, motivo: "nao_conectado" }.
 * As chaves nunca saem do servidor nem aparecem em logs.
 */
export type Resultado<T = unknown> = { ok: true; dados: T } | { ok: false; motivo: "nao_conectado" | "erro"; erro?: string };

export const MODULOS = [
  { chave: "asaas", nome: "Asaas", area: "Pagamentos", variavel: "ASAAS_API_KEY", descricao: "Cobrança das faturas (PIX, boleto ou cartão, o cliente escolhe), com a parte da plataforma separada.", extras: ["ASAAS_WALLET_PLATAFORMA (carteira da plataforma, opcional)", "ASAAS_URL (só para testar no sandbox)"] },
  { chave: "focus", nome: "Focus NFe", area: "Nota fiscal", variavel: "FOCUS_NFE_TOKEN", descricao: "Emissor principal de nota fiscal de serviço (NFS-e).", extras: ["CNPJ de quem emite e código do serviço em Ajustes → Nota fiscal"] },
  { chave: "plugnotas", nome: "PlugNotas", area: "Nota fiscal", variavel: "PLUGNOTAS_TOKEN", descricao: "Emissor alternativo, para quem já usa." },
  { chave: "nfeio", nome: "NFE.io", area: "Nota fiscal", variavel: "NFEIO_TOKEN", descricao: "Emissor alternativo, para quem já usa." },
  { chave: "enotas", nome: "eNotas", area: "Nota fiscal", variavel: "ENOTAS_TOKEN", descricao: "Emissor alternativo, para quem já usa." },
  { chave: "resend", nome: "Resend", area: "E-mail", variavel: "RESEND_API_KEY", descricao: "Cadastro aprovado, fatura emitida, pedido entregue, devolução e relatórios.", extras: ["EMAIL_REMETENTE (ex.: PW Express <avisos@seudominio.com>)"] },
  { chave: "whatsapp", nome: "WhatsApp (Meta)", area: "WhatsApp", variavel: "WHATSAPP_TOKEN", descricao: "Link de acompanhar para quem recebe, quando a rota sai.", extras: ["WHATSAPP_NUMERO_ID (id do número na Meta)", "Modelo aprovado com 2 campos (nome e link) em Ajustes → Integrações"] },
] as const;

export const conectado = (variavel: string) => Boolean(process.env[variavel]?.trim());

async function chamar<T>(url: string, init: RequestInit): Promise<Resultado<T>> {
  try {
    const r = await fetch(url, { ...init, signal: AbortSignal.timeout(15_000) });
    const corpo = await r.json().catch(() => ({}));
    if (!r.ok) return { ok: false, motivo: "erro", erro: String((corpo as { message?: string; errors?: { description?: string }[] }).message ?? (corpo as { errors?: { description?: string }[] }).errors?.[0]?.description ?? r.status) };
    return { ok: true, dados: corpo as T };
  } catch (e) { return { ok: false, motivo: "erro", erro: (e as Error).message }; }
}

// ---------------------------------------------------------------- Asaas: cobrança com split
export async function asaasCobrar(p: { clienteId: string; valor: number; vencimento: string; descricao: string; metodo: "PIX" | "CREDIT_CARD" | "BOLETO" | "UNDEFINED";
  divisao: { walletId: string; percentual?: number; fixo?: number }[]; referencia: string }): Promise<Resultado<{ id: string; invoiceUrl: string }>> {
  const chave = process.env.ASAAS_API_KEY?.trim();
  if (!chave) return { ok: false, motivo: "nao_conectado" };
  const base = process.env.ASAAS_URL?.trim() || "https://api.asaas.com/v3";
  return chamar(`${base}/payments`, {
    method: "POST", headers: { access_token: chave, "Content-Type": "application/json" },
    body: JSON.stringify({ customer: p.clienteId, billingType: p.metodo, value: p.valor, dueDate: p.vencimento, description: p.descricao, externalReference: p.referencia,
      split: p.divisao.map((d) => ({ walletId: d.walletId, ...(d.percentual != null ? { percentualValue: d.percentual } : { fixedValue: d.fixo }) })) }),
  });
}

/** Acha (pelo CPF/CNPJ) ou cria o cliente no Asaas e devolve o id dele. */
export async function asaasCliente(p: { documento: string; nome: string; email?: string | null; telefone?: string | null }): Promise<Resultado<{ id: string }>> {
  const chave = process.env.ASAAS_API_KEY?.trim();
  if (!chave) return { ok: false, motivo: "nao_conectado" };
  const base = process.env.ASAAS_URL?.trim() || "https://api.asaas.com/v3";
  const doc = p.documento.replace(/\D/g, "");
  const achado = await chamar<{ data?: { id: string }[] }>(`${base}/customers?cpfCnpj=${doc}`, { method: "GET", headers: { access_token: chave } });
  if (achado.ok && achado.dados.data?.[0]?.id) return { ok: true, dados: { id: achado.dados.data[0].id } };
  return chamar(`${base}/customers`, {
    method: "POST", headers: { access_token: chave, "Content-Type": "application/json" },
    body: JSON.stringify({ name: p.nome, cpfCnpj: doc, email: p.email || undefined, mobilePhone: p.telefone?.replace(/\D/g, "") || undefined }),
  });
}

// ---------------------------------------------------------------- nota fiscal (NFS-e)
export type DadosNota = { referencia: string; prestadorCnpj: string; tomador: { documento: string; nome: string; email?: string }; valor: number; descricao: string; codigoServico: string };
export async function emitirNota(provedor: string, n: DadosNota): Promise<Resultado<{ id?: string; status?: string }>> {
  if (provedor === "focus") {
    const t = process.env.FOCUS_NFE_TOKEN?.trim();
    if (!t) return { ok: false, motivo: "nao_conectado" };
    const base = process.env.FOCUS_NFE_URL?.trim() || "https://api.focusnfe.com.br";
    return chamar(`${base}/v2/nfse?ref=${encodeURIComponent(n.referencia)}`, {
      method: "POST", headers: { Authorization: `Basic ${Buffer.from(`${t}:`).toString("base64")}`, "Content-Type": "application/json" },
      body: JSON.stringify({ data_emissao: new Date().toISOString(), prestador: { cnpj: n.prestadorCnpj },
        tomador: { [n.tomador.documento.length > 11 ? "cnpj" : "cpf"]: n.tomador.documento, razao_social: n.tomador.nome, email: n.tomador.email },
        servico: { valor_servicos: n.valor, discriminacao: n.descricao, item_lista_servico: n.codigoServico } }),
    });
  }
  // PlugNotas, NFE.io e eNotas: o formato fica pronto quando alguém pedir para trocar
  const variavel = { plugnotas: "PLUGNOTAS_TOKEN", nfeio: "NFEIO_TOKEN", enotas: "ENOTAS_TOKEN" }[provedor];
  if (!variavel || !conectado(variavel)) return { ok: false, motivo: "nao_conectado" };
  return { ok: false, motivo: "erro", erro: "Emissor ainda não ligado a este fluxo. Fale com o suporte da plataforma." };
}

// ---------------------------------------------------------------- e-mail (Resend)
export async function enviarEmail(p: { para: string | string[]; assunto: string; html: string; de?: string; anexos?: { nome: string; conteudo: string }[] }): Promise<Resultado<{ id: string }>> {
  const chave = process.env.RESEND_API_KEY?.trim();
  if (!chave) return { ok: false, motivo: "nao_conectado" };
  return chamar("https://api.resend.com/emails", {
    method: "POST", headers: { Authorization: `Bearer ${chave}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: p.de ?? process.env.EMAIL_REMETENTE ?? "Delibra <avisos@delibra.app>", to: p.para, subject: p.assunto, html: p.html,
      ...(p.anexos?.length ? { attachments: p.anexos.map((a) => ({ filename: a.nome, content: a.conteudo })) } : {}) }),
  });
}

// ---------------------------------------------------------------- WhatsApp (Cloud API da Meta)
export async function enviarWhatsapp(p: { para: string; modelo: string; idioma?: string; variaveis?: string[] }): Promise<Resultado<{ messages?: { id: string }[] }>> {
  const t = process.env.WHATSAPP_TOKEN?.trim(), numero = process.env.WHATSAPP_NUMERO_ID?.trim();
  if (!t || !numero) return { ok: false, motivo: "nao_conectado" };
  return chamar(`https://graph.facebook.com/v21.0/${numero}/messages`, {
    method: "POST", headers: { Authorization: `Bearer ${t}`, "Content-Type": "application/json" },
    body: JSON.stringify({ messaging_product: "whatsapp", to: p.para.replace(/\D/g, ""), type: "template",
      template: { name: p.modelo, language: { code: p.idioma ?? "pt_BR" }, components: p.variaveis?.length ? [{ type: "body", parameters: p.variaveis.map((v) => ({ type: "text", text: v })) }] : [] } }),
  });
}
