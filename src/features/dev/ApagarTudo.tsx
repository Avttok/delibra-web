"use client";

import { useCallback, useEffect, useState } from "react";
import { Bomb, ChevronLeft, Eraser, Search, Trash2 } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

interface Categoria { chave: string; nome: string; descricao: string; total: number }
interface Item { id: string; titulo: string; sub?: string; quando?: string }

const quando = (iso?: string) => (iso ? new Date(iso).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" }) : "");

/**
 * Apagar qualquer coisa do sistema: um registro, vários marcados, uma categoria inteira, tudo da operação
 * ou tudo mesmo (inclui clientes e configurações). Sempre com a senha do Dev.
 */
export function ApagarTudo() {
  const [cats, setCats] = useState<Categoria[] | null>(null);
  const [cat, setCat] = useState<Categoria | null>(null);
  const [itens, setItens] = useState<Item[] | null>(null);
  const [marcados, setMarcados] = useState<Set<string>>(new Set());
  const [busca, setBusca] = useState("");
  const [pedir, setPedir] = useState<{ categoria: string; ids: string[] | null; texto: string } | null>(null);
  const [senha, setSenha] = useState("");
  const [apagando, setApagando] = useState(false);

  const contar = useCallback(async () => {
    const { data, error } = await supabase().rpc("dev_contagem");
    if (error) return toast(error.message.includes("dev_contagem") ? "Rode a migração 20261110000016_chat_dev_gps.sql." : error.message, "erro");
    setCats(data as Categoria[]);
  }, []);
  useEffect(() => { void contar(); }, [contar]);

  const listar = useCallback(async (c: Categoria, b: string) => {
    setItens(null);
    const { data, error } = await supabase().rpc("dev_listar", { p_categoria: c.chave, p_busca: b || null, p_limite: 300 });
    if (error) return toast(error.message, "erro");
    setItens(data as Item[]);
  }, []);
  useEffect(() => {
    if (!cat) return;
    const t = setTimeout(() => void listar(cat, busca), 250);
    return () => clearTimeout(t);
  }, [cat, busca, listar]);

  async function confirmar() {
    if (!pedir) return;
    setApagando(true);
    const { data, error } = await supabase().rpc("dev_apagar", { p_senha: senha, p_categoria: pedir.categoria, p_ids: pedir.ids });
    setApagando(false);
    if (error) return toast(error.message, "erro");
    const r = data as { apagados?: number; erro?: string; restantes?: number };
    if (r.erro) return toast(r.erro === "senha_incorreta" ? `Senha incorreta (${r.restantes} tentativa(s)).` : "Muitas tentativas. Espere 15 minutos.", "erro");
    toast(`${(r.apagados ?? 0).toLocaleString("pt-BR")} registro(s) apagado(s).`, "ok", { titulo: "Apagado" });
    setPedir(null); setSenha(""); setMarcados(new Set());
    void contar();
    if (cat) void listar(cat, busca);
  }

  const total = (cats ?? []).reduce((s, c) => s + Number(c.total), 0);
  return (
    <section className="apagar-tudo">
      {!cat ? (
        <>
          <ZerarPedidos />
          <p className="dica" style={{ margin: 0 }}>Escolha uma categoria para ver e apagar registro por registro, ou apague a categoria inteira. Nada disso dá para desfazer.</p>
          <div className="apagar-grade">
            {(cats ?? []).map((c) => (
              <div key={c.chave} className="apagar-cat">
                <button type="button" className="apagar-cat-abrir" onClick={() => { setCat(c); setBusca(""); setMarcados(new Set()); }}>
                  <strong>{c.nome}</strong><span className="dica">{c.descricao}</span>
                  <b>{Number(c.total).toLocaleString("pt-BR")}</b>
                </button>
                <button type="button" className="botao-texto perigo" disabled={!Number(c.total)} onClick={() => setPedir({ categoria: c.chave, ids: null, texto: `todos os ${Number(c.total).toLocaleString("pt-BR")} registro(s) de ${c.nome}` })}>
                  <Eraser size={14} aria-hidden /> Apagar tudo
                </button>
              </div>
            ))}
          </div>
          <div className="apagar-final">
            <button type="button" className="botao-perigo" onClick={() => setPedir({ categoria: "tudo", ids: null, texto: "toda a operação: pedidos, rotas, ofertas, percursos, faturas, folha, chat e registros (clientes e configurações ficam)" })}>
              <Trash2 size={15} aria-hidden /> Apagar a operação inteira
            </button>
            <button type="button" className="botao-perigo forte" onClick={() => setPedir({ categoria: "tudo_mesmo", ids: null, texto: `TUDO (${total.toLocaleString("pt-BR")} registros): operação, clientes, exceções, zonas, horários, modelos, PIX e as configurações voltam ao padrão` })}>
              <Bomb size={15} aria-hidden /> Apagar TUDO
            </button>
          </div>
          <p className="dica" style={{ margin: 0 }}>As contas de acesso (motoboys, gestores, clientes) você apaga em Equipe e em Clientes.</p>
        </>
      ) : (
        <>
          <div className="linha-botoes">
            <button type="button" className="botao-texto" onClick={() => { setCat(null); setItens(null); }}><ChevronLeft size={15} aria-hidden /> Categorias</button>
            <strong style={{ flex: 1 }}>{cat.nome}</strong>
            <label className="config-busca" style={{ flex: 1, minWidth: 180 }}><Search size={15} aria-hidden /><input placeholder="Buscar…" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
          </div>
          <div className="linha-botoes">
            <button type="button" className="botao-texto" onClick={() => setMarcados(new Set((itens ?? []).map((i) => i.id)))}>Marcar todos da lista</button>
            {marcados.size > 0 && <button type="button" className="botao-texto" onClick={() => setMarcados(new Set())}>Desmarcar</button>}
            <span style={{ flex: 1 }} />
            <button type="button" className="botao-perigo" disabled={!marcados.size} onClick={() => setPedir({ categoria: cat.chave, ids: [...marcados], texto: `${marcados.size} registro(s) de ${cat.nome}` })}>
              <Trash2 size={14} aria-hidden /> Apagar {marcados.size || ""} marcado(s)
            </button>
          </div>
          {itens == null ? <p className="dica">Carregando…</p> : itens.length === 0 ? <p className="vazio">Nada aqui.</p> : (
            <div className="apagar-lista">
              {itens.map((i) => (
                <label key={i.id} className={`apagar-item ${marcados.has(i.id) ? "marcado" : ""}`}>
                  <input type="checkbox" checked={marcados.has(i.id)} onChange={(e) => setMarcados((m) => { const n = new Set(m); if (e.target.checked) n.add(i.id); else n.delete(i.id); return n; })} />
                  <span><strong>{i.titulo}</strong>{i.sub && <span className="dica"> · {i.sub}</span>}</span>
                  <span className="dica">{quando(i.quando)}</span>
                  <button type="button" className="icone" aria-label="Apagar este" onClick={(e) => { e.preventDefault(); setPedir({ categoria: cat.chave, ids: [i.id], texto: i.titulo }); }}><Trash2 size={14} /></button>
                </label>
              ))}
            </div>
          )}
        </>
      )}

      {pedir && (
        <div className="modal-fundo" role="dialog" aria-modal="true" onClick={() => !apagando && setPedir(null)}>
          <div className="modal vidro" onClick={(e) => e.stopPropagation()}>
            <h3 className="display" style={{ margin: 0 }}>Apagar de vez?</h3>
            <p>Vai apagar <strong>{pedir.texto}</strong>. Não dá para desfazer.</p>
            <input type="password" autoFocus placeholder="Sua senha" value={senha} onChange={(e) => setSenha(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter" && senha) void confirmar(); }} />
            <div className="linha-botoes">
              <button type="button" className="botao-texto" disabled={apagando} onClick={() => setPedir(null)}>Cancelar</button>
              <button type="button" className="botao-perigo" disabled={apagando || !senha} onClick={confirmar}>{apagando ? "Apagando…" : "Apagar"}</button>
            </div>
          </div>
        </div>
      )}
    </section>
  );
}

/** Zera os pedidos (teste, reais ou ambos): a numeração volta ao 1. */
function ZerarPedidos() {
  const [alvo, setAlvo] = useState<"teste" | "reais" | "ambos">("teste");
  const [conf, setConf] = useState("");
  const [rodando, setRodando] = useState(false);
  const rot = { teste: "Só teste", reais: "Só reais", ambos: "Ambos" } as const;
  async function zerar() {
    if (conf !== "ZERAR") return toast("Digite ZERAR para confirmar.", "aviso");
    setRodando(true);
    const { data, error } = await supabase().rpc("resetar_pedidos", { p_alvo: alvo, p_confirmar: "ZERAR" });
    setRodando(false);
    if (error) return toast(error.message.includes("resetar_pedidos") ? "Rode a migração 20261110000005_reset_pedidos.sql." : error.message, "erro");
    const r = data as { pedidos: number; rotas: number; faturas: number };
    setConf("");
    toast(`${r.pedidos} pedidos, ${r.rotas} rotas e ${r.faturas} faturas apagados. O próximo pedido é o nº 1.`, "ok", { titulo: "Pedidos zerados" });
  }
  return (
    <section className="bloco zerar-pedidos">
      <span className="rotulo">Zerar pedidos</span>
      <p className="dica">Apaga os pedidos escolhidos, as rotas deles e as faturas que ficarem vazias. A numeração volta ao 1. As rotas apagadas ficam copiadas no registro de exclusões. Não dá para desfazer.</p>
      <div className="abas-mini">
        {(Object.keys(rot) as (keyof typeof rot)[]).map((k) => <button key={k} className={alvo === k ? "ativo" : ""} onClick={() => setAlvo(k)}>{rot[k]}</button>)}
      </div>
      <div className="linha-botoes">
        <input placeholder="Digite ZERAR para confirmar" value={conf} onChange={(e) => setConf(e.target.value.toUpperCase())} />
        <button className="botao-perigo" disabled={rodando || conf !== "ZERAR"} onClick={zerar}>{rodando ? "Zerando…" : `Zerar ${rot[alvo].toLowerCase()}`}</button>
      </div>
    </section>
  );
}
