"use client";

import { Fragment, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase/client";

/** Campo próprio criado em Ajustes → Modalidades → Campos próprios. */
export type CampoProprio = {
  id: string; entidade: "pedido" | "ponto" | "cliente" | "motoboy"; ponto_tipo: "coleta" | "entrega" | null; tipos_pedido: string[];
  chave: string; rotulo: string; dica: string | null; tipo: string; opcoes: string[]; obrigatorio: boolean; quem_preenche: string;
  visivel_cliente: boolean; visivel_motoboy: boolean; ordem: number; ativo: boolean;
};
export type Extras = Record<string, string | number | boolean>;

let cache: Promise<CampoProprio[]> | null = null;
/** Todos os campos ativos da empresa (os da plataforma também). Carrega uma vez por página. */
export function useCamposProprios(entidade: CampoProprio["entidade"], opcoes: { tipoPedido?: string | null; quem?: "cliente" | "gestor" | "motoboy" } = {}) {
  const [todos, setTodos] = useState<CampoProprio[]>([]);
  useEffect(() => {
    cache ??= (async () => (await supabase().rpc("campos_da_empresa")).data as CampoProprio[] ?? [])();
    let ativo = true;
    void cache.then((l) => { if (ativo) setTodos(l ?? []); });
    return () => { ativo = false; };
  }, []);
  return todos.filter((c) => c.entidade === entidade
    && (!opcoes.tipoPedido || !c.tipos_pedido?.length || c.tipos_pedido.includes(opcoes.tipoPedido))
    && (!opcoes.quem || c.quem_preenche === "qualquer" || c.quem_preenche === opcoes.quem)
    && (opcoes.quem !== "cliente" || c.visivel_cliente));
}
export function esquecerCampos() { cache = null; }

/** Falta preencher algum obrigatório? Devolve o nome do primeiro. */
export function faltaCampo(campos: CampoProprio[], v: Extras): string | null {
  const c = campos.find((k) => k.obrigatorio && k.tipo !== "foto" && (v[k.chave] == null || String(v[k.chave]).trim() === ""));
  return c ? c.rotulo : null;
}

/** Formulário dos campos próprios. */
export function CamposExtras({ campos, valores, onMudar }: { campos: CampoProprio[]; valores: Extras; onMudar: (v: Extras) => void }) {
  if (!campos.length) return null;
  const muda = (k: string, x: string | number | boolean) => onMudar({ ...valores, [k]: x });
  return (
    <div className="campos-extras">
      {campos.filter((c) => c.tipo !== "foto").map((c) => {
        const rot = `${c.rotulo}${c.obrigatorio ? " *" : ""}`;
        const v = valores[c.chave];
        if (c.tipo === "sim_nao") return (
          <label key={c.chave} className="opcao"><span>{rot}{c.dica && <small className="dica"> {c.dica}</small>}</span>
            <input type="checkbox" role="switch" checked={v === true} onChange={(e) => muda(c.chave, e.target.checked)} /></label>
        );
        if (c.tipo === "escolha") return (
          <label key={c.chave} className="campo"><span>{rot}</span>
            <select value={String(v ?? "")} onChange={(e) => muda(c.chave, e.target.value)}>
              <option value="">Escolha…</option>{c.opcoes.map((o) => <option key={o} value={o}>{o}</option>)}
            </select>{c.dica && <small className="dica">{c.dica}</small>}</label>
        );
        const tipo = c.tipo === "data" ? "date" : c.tipo === "telefone" ? "tel" : "text";
        const modo = c.tipo === "numero" || c.tipo === "dinheiro" ? "decimal" : c.tipo === "telefone" ? "tel" : undefined;
        return (
          <label key={c.chave} className="campo"><span>{rot}{c.tipo === "dinheiro" ? " (R$)" : ""}</span>
            <input type={tipo} inputMode={modo} value={String(v ?? "")} onChange={(e) => muda(c.chave, e.target.value)} />
            {c.dica && <small className="dica">{c.dica}</small>}</label>
        );
      })}
    </div>
  );
}

/** Mostra os valores preenchidos (pedido, cliente, motoboy ou respostas da parada). */
export function ExtrasVistos({ campos, valores, titulo }: { campos: CampoProprio[]; valores: Extras | null | undefined; titulo?: string }) {
  const v = valores ?? {};
  const linhas = Object.entries(v).filter(([, x]) => x !== "" && x != null);
  if (!linhas.length) return null;
  const nome = (k: string) => campos.find((c) => c.chave === k)?.rotulo ?? k.replace(/_/g, " ");
  const tipo = (k: string) => campos.find((c) => c.chave === k)?.tipo;
  const mostrar = (k: string, x: unknown) => typeof x === "boolean" ? (x ? "Sim" : "Não")
    : tipo(k) === "dinheiro" ? Number(x).toLocaleString("pt-BR", { style: "currency", currency: "BRL" })
    : tipo(k) === "foto" ? "Foto enviada" : String(x);
  return (
    <div>
      {titulo && <span className="rotulo">{titulo}</span>}
      <dl className="extras-lista">{linhas.map(([k, x]) => <Fragment key={k}><dt>{nome(k)}</dt><dd>{mostrar(k, x)}</dd></Fragment>)}</dl>
    </div>
  );
}

/** Bloco dos campos próprios num cadastro (cliente ou motoboy), com o próprio botão de salvar. */
export function ExtrasDoCadastro({ entidade, alvo, tabela }: { entidade: "cliente" | "motoboy"; alvo: string; tabela: "empresas" | "motoboys" }) {
  const campos = useCamposProprios(entidade);
  const [v, setV] = useState<Extras>({});
  const [salvo, setSalvo] = useState<string>("{}");
  const [enviando, setEnviando] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  useEffect(() => {
    void supabase().from(tabela).select("extras").eq("id", alvo).maybeSingle().then(({ data }) => {
      const x = ((data as { extras?: Extras } | null)?.extras ?? {}) as Extras;
      setV(x); setSalvo(JSON.stringify(x));
    });
  }, [alvo, tabela]);
  if (!campos.length) return null;
  async function salvar() {
    setEnviando(true); setMsg(null);
    const { data, error } = await supabase().rpc("salvar_extras", { p_entidade: entidade, p_alvo: alvo, p_valores: v });
    setEnviando(false);
    if (error) { const m = /campo_(obrigatorio|invalido):(.+)/.exec(error.message); setMsg(m ? (m[1] === "obrigatorio" ? `Preencha: ${m[2]}.` : `Valor inválido em: ${m[2]}.`) : "Não deu agora. Tente de novo."); return; }
    setV(data as Extras); setSalvo(JSON.stringify(data)); setMsg("Salvo.");
  }
  return (
    <section className="secao">
      <div className="secao-titulo"><h3>Campos próprios</h3></div>
      <CamposExtras campos={campos} valores={v} onMudar={setV} />
      <div className="linha-botoes">
        <button type="button" className="botao-vidro" disabled={enviando || JSON.stringify(v) === salvo} onClick={salvar}>{enviando ? "Salvando…" : "Salvar campos"}</button>
        {msg && <span className="dica">{msg}</span>}
      </div>
    </section>
  );
}
