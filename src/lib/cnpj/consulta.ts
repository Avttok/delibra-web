/**
 * Consulta de CNPJ (mesma estratégia do sdrfey): ReceitaWS primeiro, BrasilAPI se falhar.
 * Respostas normalizadas num formato único.
 */
export interface DadosCnpj {
  cnpj: string;
  razaoSocial: string | null;
  nomeFantasia: string | null;
  situacao: string | null; // ATIVA, BAIXADA, INAPTA, SUSPENSA, NULA
  telefones: string[];
  emails: string[];
  atividade: string | null;
  abertura: string | null;
  endereco: { logradouro: string | null; numero: string | null; complemento: string | null; bairro: string | null; cidade: string | null; uf: string | null; cep: string | null };
  fonte: "receitaws" | "brasilapi";
  bruto: unknown;
}

const UA = "Mozilla/5.0 (compatible; Delibra/1.0; +https://delibra.vercel.app)";
const digitos = (s: unknown) => String(s ?? "").replace(/\D/g, "");
const txt = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : null);

function telefones(raw: unknown): string[] {
  return String(raw ?? "")
    .split(/[\/;,]| ou /i)
    .map(digitos)
    .map((d) => (d.length >= 12 ? d.replace(/^55/, "") : d))
    .filter((d) => d.length === 10 || d.length === 11);
}

async function buscar(url: string): Promise<{ dados: unknown | null; motivo?: string }> {
  let motivo = "sem resposta";
  for (let tentativa = 0; tentativa < 3; tentativa++) {
    if (tentativa) await new Promise((r) => setTimeout(r, 800 * tentativa));
    try {
      const r = await fetch(url, { signal: AbortSignal.timeout(12_000), headers: { accept: "application/json", "user-agent": UA }, cache: "no-store" });
      if (r.ok) return { dados: await r.json() };
      motivo = `HTTP ${r.status}`;
      if (r.status === 400 || r.status === 404) break;
    } catch (e) {
      motivo = e instanceof Error && e.name === "TimeoutError" ? "tempo esgotado" : "falha de conexão";
    }
  }
  return { dados: null, motivo };
}

/* eslint-disable @typescript-eslint/no-explicit-any */
function lerReceitaWs(j: any, cnpj: string): DadosCnpj | null {
  if (!j || typeof j !== "object" || j.status === "ERROR" || !j.cnpj) return null;
  return {
    cnpj,
    razaoSocial: txt(j.nome),
    nomeFantasia: txt(j.fantasia),
    situacao: txt(j.situacao)?.toUpperCase() ?? null,
    telefones: telefones(j.telefone),
    emails: txt(j.email) ? [txt(j.email)!.toLowerCase()] : [],
    atividade: txt(j.atividade_principal?.[0]?.text),
    abertura: txt(j.abertura),
    endereco: {
      logradouro: txt(j.logradouro), numero: txt(j.numero), complemento: txt(j.complemento), bairro: txt(j.bairro),
      cidade: txt(j.municipio), uf: txt(j.uf)?.toUpperCase() ?? null, cep: digitos(j.cep) || null,
    },
    fonte: "receitaws",
    bruto: j,
  };
}

function lerBrasilApi(j: any, cnpj: string): DadosCnpj | null {
  if (!j || typeof j !== "object" || !j.cnpj) return null;
  return {
    cnpj,
    razaoSocial: txt(j.razao_social),
    nomeFantasia: txt(j.nome_fantasia),
    situacao: txt(j.descricao_situacao_cadastral)?.toUpperCase() ?? null,
    telefones: [...telefones(j.ddd_telefone_1), ...telefones(j.ddd_telefone_2)],
    emails: txt(j.email) ? [txt(j.email)!.toLowerCase()] : [],
    atividade: txt(j.cnae_fiscal_descricao),
    abertura: txt(j.data_inicio_atividade),
    endereco: {
      logradouro: [txt(j.descricao_tipo_de_logradouro), txt(j.logradouro)].filter(Boolean).join(" ") || null,
      numero: txt(j.numero), complemento: txt(j.complemento), bairro: txt(j.bairro),
      cidade: txt(j.municipio), uf: txt(j.uf)?.toUpperCase() ?? null, cep: digitos(j.cep) || null,
    },
    fonte: "brasilapi",
    bruto: j,
  };
}
/* eslint-enable @typescript-eslint/no-explicit-any */

export async function consultarCnpj(cnpjBruto: string): Promise<{ dados: DadosCnpj | null; motivo?: string }> {
  const cnpj = digitos(cnpjBruto);
  if (cnpj.length !== 14) return { dados: null, motivo: "CNPJ deve ter 14 dígitos" };
  const rw = await buscar(`https://receitaws.com.br/v1/cnpj/${cnpj}`);
  const a = lerReceitaWs(rw.dados, cnpj);
  if (a) return { dados: a };
  const ba = await buscar(`https://brasilapi.com.br/api/cnpj/v1/${cnpj}`);
  const b = lerBrasilApi(ba.dados, cnpj);
  if (b) return { dados: b };
  return { dados: null, motivo: `ReceitaWS: ${rw.motivo ?? "sem dados"} · BrasilAPI: ${ba.motivo ?? "sem dados"}` };
}

/** "Rua X, 123, Bairro, Cidade - UF" para geocodificar e exibir. */
export function enderecoEmTexto(e: DadosCnpj["endereco"]): string {
  const rua = [e.logradouro, e.numero].filter(Boolean).join(", ");
  const local = [e.bairro, e.cidade && e.uf ? `${e.cidade} - ${e.uf}` : e.cidade].filter(Boolean).join(", ");
  return [rua, local].filter(Boolean).join(", ");
}
