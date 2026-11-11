"use client";

import { useCallback, useEffect, useState } from "react";
import { BadgeCheck, CalendarClock, Check, Eye, Landmark, Palette, Receipt, Type } from "lucide-react";
import { Logo } from "@/features/marca/Logo";
import { RecebimentosEmpresa } from "@/features/pagamentos/Recebimentos";
import { supabase } from "@/lib/supabase/client";
import { CabecaPagina } from "@/features/ui/CabecaPagina";
import { definirMarcaEmpresa } from "@/features/marca/marcaEmpresa";
import { IconeEmpresa } from "./IconeEmpresa";
import { FONTES, cssFonte } from "@/features/marca/fontes";
import { toast } from "@/features/ui/toast";

type Org = { id: string; nome: string; nome_app: string | null; nome_topo: string | null; logo_escala: number | null; logo_original_url: string | null; logo_brilho_cor: string | null; logo_brilho: number | null; fonte_nome: string | null; slug: string | null; logo_url: string | null; cor: string | null; documento: string | null };
type Plano = {
  empresa: string; status: string; modelo: "percentual" | "licenca" | "isento"; pct: number; mensalidade: number;
  vencimento_dia: number; proximo_vencimento: string; de: string; ate: string; faturamento: number; rotas: number; devido: number;
  historico: { modelo: string; valor: number; pct: number; inicio: string; fim: string | null; status: string }[];
  meses: { mes: string; faturamento: number; rotas: number; devido: number }[];
};

const moeda = (v: number) => Number(v ?? 0).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
const data = (d: string) => new Date(`${d}T12:00:00`).toLocaleDateString("pt-BR");
const mes = (d: string) => new Date(`${d}T12:00:00`).toLocaleDateString("pt-BR", { month: "long", year: "numeric" });
const MODELO: Record<string, string> = { percentual: "Percentual do faturamento", licenca: "Licença mensal", isento: "Isento" };
const STATUS: Record<string, string> = { ativa: "Ativa", teste: "Em teste", suspensa: "Suspensa", cancelada: "Cancelada" };

/** Minha empresa: ícone e cor da marca (usados no app e no site) e o plano com a plataforma. */
export function PainelEmpresa() {
  const [org, setOrg] = useState<Org | null | undefined>(undefined);
  const [plano, setPlano] = useState<Plano | null>(null);
  const [nome, setNome] = useState("");
  const [cor, setCor] = useState("#d4af37");
  const [nomeApp, setNomeApp] = useState("");
  const [nomeTopo, setNomeTopo] = useState("");
  const [fonte, setFonte] = useState("ARCHIVO");
  const [salvando, setSalvando] = useState(false);

  const carregar = useCallback(async () => {
    const sb = supabase();
    const [{ data: o }, { data: p }] = await Promise.all([sb.rpc("minha_organizacao"), sb.rpc("meu_plano")]);
    const og = (o as Org | null) ?? null;
    setOrg(og); setPlano((p as Plano | null) ?? null);
    if (og) { setNome(og.nome); setCor(og.cor ?? "#d4af37"); setNomeApp(og.nome_app ?? ""); setNomeTopo(og.nome_topo ?? ""); setFonte(og.fonte_nome ?? "ARCHIVO"); }
  }, []);
  useEffect(() => { void carregar(); }, [carregar]);

  async function salvar(campos: Record<string, unknown>) {
    const { error } = await supabase().rpc("salvar_minha_organizacao", { p: campos });
    if (error) return error.message.includes("apenas_gestor") ? "Só o dono da empresa (ou o Dev) muda isto." : error.message;
    const novo = { ...org!, ...(campos as Partial<Org>) };
    setOrg(novo);
    definirMarcaEmpresa({ nome: novo.nome, nomeApp: novo.nome_app, nomeTopo: novo.nome_topo, logo: novo.logo_url, cor: novo.cor, escala: novo.logo_escala, brilhoCor: novo.logo_brilho_cor, brilho: novo.logo_brilho, fonte: novo.fonte_nome });
    // relê do banco: as chaves salvas têm nomes diferentes das colunas (brilho_cor → logo_brilho_cor…)
    void carregar().then(() => void supabase().rpc("minha_organizacao").then(({ data }) => {
      const o = data as Org | null;
      if (o) definirMarcaEmpresa({ nome: o.nome, nomeApp: o.nome_app, nomeTopo: o.nome_topo, logo: o.logo_url, cor: o.cor, escala: o.logo_escala, brilhoCor: o.logo_brilho_cor, brilho: o.logo_brilho, fonte: o.fonte_nome });
    }));
    return null;
  }

  async function salvarNomeCor() {
    setSalvando(true);
    const app = nomeApp.trim();
    if (app && (app.length < 2 || app.length > 30)) { setSalvando(false); return toast("O nome do app precisa ter de 2 a 30 letras.", "erro"); }
    if (nomeTopo.trim().length > 30) { setSalvando(false); return toast("O texto do topo pode ter até 30 letras.", "erro"); }
    const erro = await salvar({ nome, cor, nome_app: app || "", nome_topo: nomeTopo.trim(), fonte: fonte === "ARCHIVO" ? "" : fonte });
    if (erro) toast(erro, "erro"); else toast("Salvo. O app e o site já mostram o nome novo.", "ok");
    setSalvando(false);
  }

  if (org === undefined) return <main className="conteudo"><p className="dica">Carregando…</p></main>;
  if (!org) return (
    <main className="conteudo"><div className="bloco"><p className="vazio">Esta conta não está em nenhuma empresa. O Dev escolhe uma em Dev → Empresas (Entrar como).</p></div></main>
  );

  return (
    <>
      <aside className="lateral lateral-larga entrar">
        <CabecaPagina icone={Landmark} titulo="Minha empresa" subtitulo="Marca no app e no site · seu plano" />
        {/* como fica: o topo do app/site e o nome por extenso, ao vivo com o que você está mudando */}
        <section className="bloco empresa-previa">
          <span className="rotulo"><Eye size={12} aria-hidden /> Como fica</span>
          <div className="empresa-previa-topo"><Logo previa={{ nome, nomeApp: nomeApp.trim() || null, nomeTopo: nomeTopo.trim() || null, logo: org.logo_url, cor,
            escala: org.logo_escala, brilhoCor: org.logo_brilho_cor, brilho: org.logo_brilho, fonte: fonte === "ARCHIVO" ? null : fonte }} /></div>
          <div className="empresa-previa-linhas">
            <span><small>No topo, ao lado da logo</small><strong style={{ fontFamily: cssFonte(fonte) }}>{nomeTopo.trim() || nomeApp.trim() || nome || "Delibra"}</strong></span>
            <span><small>Onde a logo não aparece (atalho, avisos, títulos)</small><strong>{nomeApp.trim() || nome || "Delibra"}</strong></span>
          </div>
        </section>

        <section className="bloco">
          <h3 className="titulo-bloco"><Palette size={16} aria-hidden /> Ícone</h3>
          <IconeEmpresa orgId={org.id} nome={nomeTopo.trim() || org.nome_app || org.nome} logo={org.logo_url} cor={org.cor} escala={org.logo_escala}
            original={org.logo_original_url} brilhoCor={org.logo_brilho_cor} brilho={org.logo_brilho} fonte={org.fonte_nome}
            onSalvar={(logo, extras) => salvar({ logo_url: logo ?? "", ...(extras ?? {}) })} />
        </section>

        <section className="bloco">
          <h3 className="titulo-bloco"><Type size={16} aria-hidden /> Nomes, cor e fonte</h3>
          <label className="campo"><span>Nome do app</span><input value={nomeApp} maxLength={30} placeholder="Ex.: PW Express" onChange={(e) => setNomeApp(e.target.value)} />
            <small className="dica">Onde a logo não aparece: atalho no celular, avisos, telas de entrar. Em branco = Delibra.</small></label>
          <label className="campo"><span>Texto ao lado da logo (topo)</span><input value={nomeTopo} maxLength={30} placeholder={nomeApp.trim() || "Ex.: Express"} onChange={(e) => setNomeTopo(e.target.value)} />
            <small className="dica">Se a logo já tem parte do nome (ex.: “PW”), escreva só o resto (“Express”). Em branco = o nome do app.</small></label>
          <div className="grade-2">
            <label className="campo"><span>Nome da empresa</span><input value={nome} maxLength={60} onChange={(e) => setNome(e.target.value)} /></label>
            <label className="campo curto"><span>Cor da marca</span><span className="linha-cor"><input type="color" value={cor} onChange={(e) => setCor(e.target.value)} /><code>{cor}</code></span></label>
          </div>
          <div className="campo"><span>Fonte do texto do topo</span>
            <div className="fontes-previa" role="radiogroup" aria-label="Fonte do texto do topo">
              {FONTES.map((f) => (
                <button key={f.chave} type="button" role="radio" aria-checked={fonte === f.chave} className={`fonte-opcao${fonte === f.chave ? " ativo" : ""}`} onClick={() => setFonte(f.chave)}>
                  <strong style={{ fontFamily: f.css }}>{nomeTopo.trim() || nomeApp.trim() || nome || "Delibra"}</strong>
                  <small>{f.rotulo}</small>
                </button>
              ))}
            </div>
          </div>
          <div className="linha-botoes">
            <button type="button" className="botao-ouro" disabled={salvando || (nome.trim() === org.nome && cor === (org.cor ?? "#d4af37") && nomeApp.trim() === (org.nome_app ?? "") && nomeTopo.trim() === (org.nome_topo ?? "") && fonte === (org.fonte_nome ?? "ARCHIVO"))} onClick={salvarNomeCor}>
              <Check size={15} aria-hidden /> {salvando ? "Salvando…" : "Salvar"}
            </button>
          </div>
          {org.slug && <p className="dica" style={{ margin: 0 }}>Link para seus clientes criarem conta já com sua marca: <code>{typeof window !== "undefined" ? window.location.origin : ""}/entrar?criar=1&empresa={org.slug}</code></p>}
        </section>
      </aside>

      <main className="conteudo">
        <RecebimentosEmpresa />
        {plano ? (
          <div className="plano">
            <section className="bloco plano-topo">
              <span className="rotulo"><BadgeCheck size={13} aria-hidden /> Seu plano</span>
              <strong className="figura texto-grad" style={{ fontSize: 28 }}>{MODELO[plano.modelo] ?? plano.modelo}</strong>
              <p className="dica" style={{ margin: 0 }}>
                {plano.modelo === "percentual" && <>{Number(plano.pct).toLocaleString("pt-BR")}% sobre o valor das rotas concluídas no mês.</>}
                {plano.modelo === "licenca" && <>{moeda(plano.mensalidade)} por mês, com vencimento todo dia {plano.vencimento_dia}.</>}
                {plano.modelo === "isento" && <>Sua empresa não paga nada pela plataforma.</>}
              </p>
              <span className={`selo selo-${plano.status}`}>{STATUS[plano.status] ?? plano.status}</span>
            </section>

            <div className="grade-3">
              <div className="bloco"><span className="rotulo"><Receipt size={12} aria-hidden /> Este mês</span><strong className="figura">{moeda(plano.faturamento)}</strong><span className="dica">{plano.rotas} rota{plano.rotas === 1 ? "" : "s"} concluída{plano.rotas === 1 ? "" : "s"}</span></div>
              <div className="bloco"><span className="rotulo"><Landmark size={12} aria-hidden /> A pagar à plataforma</span><strong className="figura texto-grad">{moeda(plano.devido)}</strong><span className="dica">{plano.modelo === "percentual" ? "até agora, cresce com as rotas" : plano.modelo === "licenca" ? "mensalidade" : "isento"}</span></div>
              <div className="bloco"><span className="rotulo"><CalendarClock size={12} aria-hidden /> Próximo vencimento</span><strong className="figura">{plano.modelo === "isento" ? "—" : data(plano.proximo_vencimento)}</strong><span className="dica">todo dia {plano.vencimento_dia}</span></div>
            </div>

            {plano.meses.length > 0 && (
              <section className="bloco">
                <h3 className="titulo-bloco">Últimos meses</h3>
                <div className="dev-rolagem"><table className="tabela"><thead><tr><th>Mês</th><th>Rotas</th><th>Faturamento</th><th>Plataforma</th></tr></thead>
                  <tbody>{plano.meses.map((m) => <tr key={m.mes}><td style={{ textTransform: "capitalize" }}>{mes(m.mes)}</td><td>{m.rotas}</td><td>{moeda(m.faturamento)}</td><td>{moeda(m.devido)}</td></tr>)}</tbody>
                </table></div>
              </section>
            )}

            {plano.historico.length > 0 && (
              <section className="bloco">
                <h3 className="titulo-bloco">Histórico do plano</h3>
                <ul className="lista-plano">
                  {plano.historico.map((h, i) => (
                    <li key={i}><strong>{MODELO[h.modelo] ?? h.modelo}</strong>
                      <span>{h.modelo === "percentual" ? `${Number(h.pct).toLocaleString("pt-BR")}%` : h.modelo === "licenca" ? `${moeda(h.valor)}/mês` : "sem cobrança"}</span>
                      <small>{data(h.inicio)}{h.fim ? ` até ${data(h.fim)}` : " · em vigor"}</small></li>
                  ))}
                </ul>
              </section>
            )}
            <p className="dica">Dúvidas sobre o plano? Fale com o suporte da plataforma pelo chat.</p>
          </div>
        ) : <div className="bloco"><p className="vazio">Só o dono da empresa vê o plano.</p></div>}
      </main>
    </>
  );
}
