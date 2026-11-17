"use client";

import { useCallback, useEffect, useState } from "react";
import { ArrowDownWideNarrow, ChevronLeft, ChevronRight, Database, Eye, EyeOff, Plus, Search, Trash2 } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { useConta } from "@/features/conta/conta";
import { erroDev, RegrasDev } from "./Fantasma";
import { DevOculto } from "./Plataforma";

/** Explorador de dados: qualquer tabela do sistema, com busca e ordem. Só leitura. */
export function ExploradorDev() {
  const [tabelas, setTabelas] = useState<{ tabela: string; linhas: number; colunas: string[] }[]>([]);
  const [tabela, setTabela] = useState("");
  const [busca, setBusca] = useState("");
  const [ordem, setOrdem] = useState<string | null>(null);
  const [pagina, setPagina] = useState(0);
  const [res, setRes] = useState<{ total: number; linhas: Record<string, unknown>[] } | null>(null);
  const [aberta, setAberta] = useState<Record<string, unknown> | null>(null);
  const [filtroT, setFiltroT] = useState("");
  useEffect(() => { void supabase().rpc("dev_tabelas").then(({ data, error }) => { if (error) toast(erroDev(error.message), "erro"); setTabelas((data ?? []) as typeof tabelas); }); }, []);
  const ler = useCallback(async () => {
    if (!tabela) return;
    const { data, error } = await supabase().rpc("dev_explorar", { p_tabela: tabela, p_busca: busca.trim() || null, p_limite: 50, p_pagina: pagina, p_ordem: ordem });
    if (error) return toast(erroDev(error.message), "erro");
    setRes(data as typeof res);
  }, [tabela, busca, pagina, ordem]);
  useEffect(() => { const t = setTimeout(() => void ler(), 300); return () => clearTimeout(t); }, [ler]);
  const cols = tabelas.find((t) => t.tabela === tabela)?.colunas ?? [];
  const visiveis = cols.slice(0, 8);
  const curto = (v: unknown) => { const s = v === null || v === undefined ? "—" : typeof v === "object" ? JSON.stringify(v) : String(v); return s.length > 60 ? s.slice(0, 57) + "…" : s; };
  return (
    <div className="explorador">
      <aside className="explorador-tabelas">
        <label className="busca-mini"><Search size={14} aria-hidden /><input placeholder="Tabela" value={filtroT} onChange={(e) => setFiltroT(e.target.value)} /></label>
        {tabelas.filter((t) => t.tabela.includes(filtroT.toLowerCase())).map((t) => (
          <button key={t.tabela} className={t.tabela === tabela ? "ativo" : ""} onClick={() => { setTabela(t.tabela); setPagina(0); setOrdem(null); setBusca(""); setRes(null); }}>
            <Database size={13} aria-hidden /> {t.tabela} <span className="dica">{t.linhas.toLocaleString("pt-BR")}</span>
          </button>
        ))}
      </aside>
      <section className="explorador-dados">
        {!tabela ? <p className="vazio">Escolha uma tabela. Nada aqui muda dados: é só para olhar.</p> : (<>
          <div className="modulos-barra">
            <label className="busca-mini"><Search size={14} aria-hidden /><input placeholder="Buscar em qualquer coluna" value={busca} onChange={(e) => { setBusca(e.target.value); setPagina(0); }} /></label>
            <span className="dica">{res ? `${res.total.toLocaleString("pt-BR")} linha(s)` : "…"}</span>
            <span className="espaco" />
            <button className="botao-icone" aria-label="Página anterior" disabled={pagina === 0} onClick={() => setPagina(pagina - 1)}><ChevronLeft size={15} aria-hidden /></button>
            <span className="dica">pág. {pagina + 1}</span>
            <button className="botao-icone" aria-label="Próxima página" disabled={!res || (pagina + 1) * 50 >= res.total} onClick={() => setPagina(pagina + 1)}><ChevronRight size={15} aria-hidden /></button>
          </div>
          <div className="matriz-rolagem">
            <table className="dev-tabela">
              <thead><tr>{visiveis.map((c) => <th key={c}><button className="botao-texto" onClick={() => setOrdem(ordem === c ? `-${c}` : c)}>{c}{ordem?.replace("-", "") === c && <ArrowDownWideNarrow size={12} aria-hidden style={{ transform: ordem.startsWith("-") ? "none" : "scaleY(-1)" }} />}</button></th>)}</tr></thead>
              <tbody>{(res?.linhas ?? []).map((l, i) => <tr key={i} onClick={() => setAberta(l)} className="clicavel">{visiveis.map((c) => <td key={c}>{curto(l[c])}</td>)}</tr>)}</tbody>
            </table>
          </div>
          {aberta && <pre className="explorador-linha">{JSON.stringify(aberta, null, 2)}</pre>}
        </>)}
      </section>
    </div>
  );
}

interface Registro { id: number; dev: string | null; area: string; acao: string; alvo: string | null; detalhe: unknown; em: string }
const AREAS_REG: Record<string, string> = { regras_dev: "Regras", modulos: "Módulos", modulos_empresa: "Módulos por empresa", politicas: "Ajustes e exceções", configuracoes: "Ajustes do sistema", organizacoes: "Empresas", cargos: "Cargos", perfis: "Contas", avisos: "Avisos", emergencia: "Emergência" };
const ACAO: Record<string, string> = { insert: "criou", update: "mudou", delete: "apagou" };

/** Registro do Dev: tudo que o Dev fez, com o antes e o depois. Ninguém mais vê. */
export function RegistroDev() {
  const [l, setL] = useState<Registro[]>([]);
  const [area, setArea] = useState("");
  const [aberto, setAberto] = useState<number | null>(null);
  const [fim, setFim] = useState(false);
  const ler = useCallback(async (antes?: number) => {
    const { data, error } = await supabase().rpc("dev_registro", { p_limite: 100, p_antes: antes ?? null, p_area: area || null });
    if (error) return toast(erroDev(error.message), "erro");
    const novos = (data ?? []) as Registro[];
    setFim(novos.length < 100);
    setL((x) => (antes ? [...x, ...novos] : novos));
  }, [area]);
  useEffect(() => { void ler(); }, [ler]);
  return (
    <div className="registro-dev">
      <div className="modulos-barra">
        <select value={area} onChange={(e) => setArea(e.target.value)} aria-label="Área"><option value="">Tudo</option>{Object.entries(AREAS_REG).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
        <span className="dica">Só você vê este registro.</span>
      </div>
      {!l.length ? <p className="vazio">Nada registrado ainda.</p> : (
        <ul className="comando-lista">{l.map((r) => (
          <li key={r.id}>
            <button type="button" className="registro-linha" onClick={() => setAberto(aberto === r.id ? null : r.id)}>
              <span className="chip">{AREAS_REG[r.area] ?? r.area}</span> <strong>{r.dev ?? "Dev"}</strong> {ACAO[r.acao] ?? r.acao} {r.alvo && <code>{r.alvo}</code>}
              <span className="dica">{new Date(r.em).toLocaleString("pt-BR")}</span>
            </button>
            {aberto === r.id && <pre className="explorador-linha">{JSON.stringify(r.detalhe, null, 2)}</pre>}
          </li>
        ))}</ul>
      )}
      {!fim && l.length > 0 && <button className="botao-texto" onClick={() => void ler(l[l.length - 1].id)}>Carregar mais</button>}
    </div>
  );
}

interface Novidade { id: string; versao: string; area: string; plataforma: string; titulo: string; texto: string | null; publicado: boolean; criado_em: string }
const AREAS_NOV = [["todos", "Todos"], ["motoboy", "Motoboy"], ["gestor", "Gestor"], ["supervisor", "Supervisor"], ["cliente", "Cliente"], ["dev", "Dev"]] as const;

/** Novidades por área: cada pessoa vê só o que mudou para os cargos dela. O Dev vê tudo; a área Dev só o Dev vê. */
export function NovidadesDev() {
  const [l, setL] = useState<Novidade[]>([]);
  const [n, setN] = useState({ versao: "", area: "todos", plataforma: "todas", titulo: "", texto: "" });
  const ler = useCallback(async () => {
    const { data, error } = await supabase().from("novidades").select("*").order("criado_em", { ascending: false }).limit(300);
    if (error) return toast(erroDev(error.message), "erro");
    setL(data as Novidade[]);
  }, []);
  useEffect(() => { void ler(); }, [ler]);
  async function criar() {
    const { error } = await supabase().from("novidades").insert({ ...n, texto: n.texto || null });
    if (error) return toast(erroDev(error.message), "erro");
    toast("Novidade publicada.", "ok"); setN({ ...n, titulo: "", texto: "" }); void ler();
  }
  async function alternar(x: Novidade) { await supabase().from("novidades").update({ publicado: !x.publicado }).eq("id", x.id); void ler(); }
  async function apagar(x: Novidade) { if (!window.confirm(`Apagar “${x.titulo}”?`)) return; await supabase().from("novidades").delete().eq("id", x.id); void ler(); }
  return (
    <div className="novidades-dev">
      <section className="explicar-dev vidro-sutil">
        <span className="rotulo"><Plus size={14} aria-hidden /> Nova novidade</span>
        <div className="regra-linha">
          <label className="campo"><span>Versão</span><input placeholder="Ex.: Lote 51" value={n.versao} onChange={(e) => setN({ ...n, versao: e.target.value })} /></label>
          <label className="campo"><span>Para quem</span><select value={n.area} onChange={(e) => setN({ ...n, area: e.target.value })}>{AREAS_NOV.map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
          <label className="campo"><span>Onde</span><select value={n.plataforma} onChange={(e) => setN({ ...n, plataforma: e.target.value })}><option value="todas">Site e app</option><option value="site">Só site</option><option value="app">Só app</option></select></label>
        </div>
        <label className="campo"><span>Título</span><input value={n.titulo} onChange={(e) => setN({ ...n, titulo: e.target.value })} /></label>
        <label className="campo"><span>Texto</span><textarea rows={2} value={n.texto} onChange={(e) => setN({ ...n, texto: e.target.value })} /></label>
        <button className="botao-ouro" disabled={!n.versao.trim() || !n.titulo.trim()} onClick={() => void criar()}>Publicar</button>
        <p className="dica">As notas do app (NOTAS_DA_VERSAO.md) seguem as mesmas áreas: cada título “## Motoboy”, “## Gestor”, “## Supervisor”, “## Cliente”, “## Dev” ou “## Todos”.</p>
      </section>
      {[...new Set(l.map((x) => x.versao))].map((v) => (
        <section key={v} className="novidades-versao">
          <span className="rotulo">{v}</span>
          {l.filter((x) => x.versao === v).map((x) => (
            <div key={x.id} className={`novidade${x.publicado ? "" : " parada"}`}>
              <div><span className="chip">{AREAS_NOV.find(([k]) => k === x.area)?.[1]}</span> {x.plataforma !== "todas" && <span className="chip">{x.plataforma}</span>} <strong>{x.titulo}</strong>
                {x.texto && <p className="dica">{x.texto}</p>}</div>
              <span className="espaco" />
              <button className="botao-icone" title={x.publicado ? "Esconder" : "Publicar"} aria-label={x.publicado ? "Esconder" : "Publicar"} onClick={() => void alternar(x)}>{x.publicado ? <Eye size={15} aria-hidden /> : <EyeOff size={15} aria-hidden />}</button>
              <button className="botao-icone" title="Apagar" aria-label="Apagar" onClick={() => void apagar(x)}><Trash2 size={15} aria-hidden /></button>
            </div>
          ))}
        </section>
      ))}
    </div>
  );
}

/** Minha conta Dev: invisível ou não, as regras que valem só para você e o tema. */
export function MinhaContaDev({ oculto, onMudou }: { oculto: boolean; onMudou: () => void }) {
  const conta = useConta();
  return (
    <div className="minha-conta-dev">
      <DevOculto oculto={oculto} onMudou={onMudou} />
      <section>
        <span className="rotulo">Regras só para você</span>
        <p className="dica">Por padrão nada te afeta: você vê tudo, ignora o que estiver escondido e tem todas as permissões. Crie uma regra aqui para, por exemplo, ver o sistema como um gestor veria.</p>
        <RegrasDev soMinhas />
      </section>
      <section>
        <span className="rotulo">Cor do painel</span>
        <div className="segmentado" style={{ gridTemplateColumns: "1fr 1fr" }}>
          <button className={conta.corTema === "vermelho" ? "ativo" : ""} onClick={() => void conta.definirCor("vermelho")}>Vermelho do Dev</button>
          <button className={conta.corTema === "ouro" ? "ativo" : ""} onClick={() => void conta.definirCor("ouro")}>Dourado (como a equipe)</button>
        </div>
        <p className="dica">Aqui no Delibra Dev é sempre vermelho. A verificação em duas etapas é opcional: ligue no menu da sua foto, se quiser.</p>
      </section>
    </div>
  );
}
