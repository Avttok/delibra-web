"use client";

import { useCallback, useEffect, useState } from "react";
import { BadgeCheck, CalendarClock, Landmark, Palette, Receipt } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { CabecaPagina } from "@/features/ui/CabecaPagina";
import { definirMarcaEmpresa } from "@/features/marca/marcaEmpresa";
import { IconeEmpresa } from "./IconeEmpresa";
import { toast } from "@/features/ui/toast";

type Org = { id: string; nome: string; nome_app: string | null; slug: string | null; logo_url: string | null; cor: string | null; documento: string | null };
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
  const [salvando, setSalvando] = useState(false);

  const carregar = useCallback(async () => {
    const sb = supabase();
    const [{ data: o }, { data: p }] = await Promise.all([sb.rpc("minha_organizacao"), sb.rpc("meu_plano")]);
    const og = (o as Org | null) ?? null;
    setOrg(og); setPlano((p as Plano | null) ?? null);
    if (og) { setNome(og.nome); setCor(og.cor ?? "#d4af37"); setNomeApp(og.nome_app ?? ""); }
  }, []);
  useEffect(() => { void carregar(); }, [carregar]);

  async function salvar(campos: Record<string, unknown>) {
    const { error } = await supabase().rpc("salvar_minha_organizacao", { p: campos });
    if (error) return error.message.includes("apenas_gestor") ? "Só o dono da empresa (ou o Dev) muda isto." : error.message;
    const novo = { ...org!, ...(campos as Partial<Org>) };
    setOrg(novo);
    definirMarcaEmpresa({ nome: novo.nome, nomeApp: novo.nome_app, logo: novo.logo_url, cor: novo.cor });
    return null;
  }

  async function salvarNomeCor() {
    setSalvando(true);
    const app = nomeApp.trim();
    if (app && (app.length < 2 || app.length > 30)) { setSalvando(false); return toast("O nome do app precisa ter de 2 a 30 letras.", "erro"); }
    const erro = await salvar({ nome, cor, nome_app: app || "" });
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
        <section className="bloco">
          <h3 className="titulo-bloco"><Palette size={16} aria-hidden /> Ícone e nome</h3>
          <IconeEmpresa orgId={org.id} nome={org.nome_app || org.nome} logo={org.logo_url} cor={org.cor} onSalvar={(logo) => salvar({ logo_url: logo ?? "" })} />
          <div className="grade-2" style={{ marginTop: 12 }}>
            <label className="campo"><span>Nome do app</span><input value={nomeApp} maxLength={30} placeholder="Delibra" onChange={(e) => setNomeApp(e.target.value)} /></label>
            <label className="campo"><span>Nome da empresa</span><input value={nome} maxLength={60} onChange={(e) => setNome(e.target.value)} /></label>
            <label className="campo curto"><span>Cor da marca</span><input type="color" value={cor} onChange={(e) => setCor(e.target.value)} /></label>
          </div>
          <p className="dica" style={{ margin: "0 0 8px" }}>O nome do app aparece no lugar de “Delibra” no topo do app do motoboy e do site, no atalho do celular e nas telas de entrar. Em branco = Delibra.</p>
          <div className="linha-botoes">
            <button type="button" className="botao" disabled={salvando || (nome.trim() === org.nome && cor === (org.cor ?? "#d4af37") && nomeApp.trim() === (org.nome_app ?? ""))} onClick={salvarNomeCor}>
              {salvando ? "Salvando…" : "Salvar nomes e cor"}
            </button>
          </div>
          {org.slug && <p className="dica" style={{ margin: 0 }}>Link para seus clientes criarem conta já com sua marca: <code>{typeof window !== "undefined" ? window.location.origin : ""}/entrar?criar=1&empresa={org.slug}</code></p>}
        </section>
      </aside>

      <main className="conteudo">
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
