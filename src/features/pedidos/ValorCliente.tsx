"use client";

import { useEffect, useState } from "react";
import { Boxes, Check, ChevronDown, Flame, MapPinned, Package, RotateCcw, Route, Scale, Sparkles, Timer, Wallet, Waypoints } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { PARAMETROS, type ValorParametro } from "@/features/configuracoes/definicoes";
import { useConfiguracoes } from "@/features/configuracoes/useConfiguracoes";
import { usePermissoes } from "@/features/conta/permissoes";
import { moedaBr, traduzir, type Orcamento } from "./tipos";

type Regras = Record<string, ValorParametro>;
type LinhaO = { rotulo: string; valor?: number; chave?: string };

/** As peças do preço: cada uma liga e desliga (desligar = zerar só neste pedido) e tem os valores dela. */
const PECAS: { id: string; nome: string; dica: string; icone: LucideIcon; chaves: string[]; desliga?: Regras; linha: (l: LinhaO) => boolean; pct?: (rotulo: string) => boolean }[] = [
  { id: "saida", nome: "Saída", dica: "Valor fixo de cada pedido.", icone: Wallet, chaves: ["preco_base"], desliga: { preco_base: 0 }, linha: (l) => l.chave === "saida" || l.rotulo === "Saída" || l.rotulo === "Preço fixo do cliente" },
  { id: "distancia", nome: "Distância", dica: "Km × valor, pelas ruas ou em linha reta.", icone: Route, chaves: ["preco_km", "preco_distancia_modo", "orcamento_trajeto", "soma_inclui_saida", "soma_inclui_entrega_extra"],
    desliga: { preco_km: 0 }, linha: (l) => l.chave === "distancia" || (l.chave ?? "").startsWith("entrega_") || l.rotulo === "Distância" },
  { id: "pontos", nome: "Coletas e entregas a mais", dica: "Cada ponto além do primeiro.", icone: Waypoints, chaves: ["preco_coleta_extra", "preco_entrega_extra"],
    desliga: { preco_coleta_extra: 0, preco_entrega_extra: 0 }, linha: (l) => l.rotulo === "Coletas extras" || l.rotulo === "Entregas extras" },
  { id: "volumes", nome: "Volumes", dica: "Volumes além dos inclusos.", icone: Boxes, chaves: ["preco_pacotes_inclusos", "preco_pacote_extra"], desliga: { preco_pacote_extra: 0 }, linha: (l) => l.rotulo === "Volumes extras" },
  { id: "peso", nome: "Peso", dica: "Kg além do incluso (real ou cubado).", icone: Scale, chaves: ["preco_kg_incluso", "preco_kg", "cubagem_fator"], desliga: { preco_kg: 0 }, linha: (l) => l.rotulo === "Peso excedente" },
  { id: "perigoso", nome: "Produto perigoso", dica: "Acréscimo e taxa para carga perigosa.", icone: Flame, chaves: ["preco_perigoso_pct", "preco_perigoso_fixo"],
    desliga: { preco_perigoso_pct: 0, preco_perigoso_fixo: 0 }, linha: (l) => l.rotulo === "Produto perigoso", pct: (r) => r === "Produto perigoso" },
  { id: "pressa", nome: "Express e urgente", dica: "Acréscimos de quem tem pressa.", icone: Timer, chaves: ["preco_express_pct", "preco_urgente_pct"],
    desliga: { preco_express_pct: 0, preco_urgente_pct: 0 }, linha: () => false, pct: (r) => r === "Express" || r === "Urgente" },
  { id: "zonas", nome: "Zonas", dica: "Dinâmica de preço das zonas no mapa.", icone: MapPinned, chaves: ["zona_combinar", "zona_cliente_exclusiva"], linha: (l) => l.rotulo.startsWith("Zona"), pct: (r) => r.startsWith("Zona") },
  { id: "final", nome: "Mínimo e arredondamento", dica: "O total nunca fica abaixo do mínimo.", icone: Package, chaves: ["valor_minimo", "arredondamento"], linha: () => false },
];

function Campo({ chave, regras, cfg, onDefinir }: { chave: string; regras: Regras; cfg: Record<string, unknown>; onDefinir: (k: string, v: ValorParametro | null) => void }) {
  const p = PARAMETROS.find((x) => x.chave === chave);
  if (!p) return null;
  const proprio = chave in regras;
  const valor = (proprio ? regras[chave] : (cfg[chave] as ValorParametro | undefined)) ?? p.padrao;
  return (
    <label className={`pag-campo${proprio ? " proprio" : ""}`} title={p.descricao || undefined}>
      <span>{p.rotulo}{proprio && <button type="button" className="pag-limpar" onClick={(e) => { e.preventDefault(); onDefinir(chave, null); }} aria-label={`Voltar ${p.rotulo} ao padrão`}><RotateCcw size={11} aria-hidden /></button>}</span>
      {p.tipo === "booleano" ? <input type="checkbox" role="switch" checked={Boolean(valor)} onChange={(e) => onDefinir(chave, e.target.checked)} />
        : p.tipo === "escolha" || p.tipo === "opcoes" ? (
          <select value={String(valor)} onChange={(e) => onDefinir(chave, p.tipo === "opcoes" ? Number(e.target.value) : e.target.value)}>
            {(p.opcoes ?? []).map((o) => <option key={String(o.valor)} value={String(o.valor)}>{o.rotulo}</option>)}
          </select>
        ) : (
          <span className="passo-campo">
            {p.unidade === "R$" && <span className="unidade">R$</span>}
            <input inputMode="decimal" defaultValue={String(valor).replace(".", ",")} key={`${chave}-${String(valor)}`}
              onBlur={(e) => { const n = Number(e.target.value.replace(",", ".")); if (!Number.isNaN(n) && n !== Number(valor)) onDefinir(chave, n); }} />
            {p.unidade && p.unidade !== "R$" && <span className="unidade">{p.unidade}</span>}
          </span>
        )}
    </label>
  );
}

/**
 * Valor cobrado do cliente, no mesmo jeito do pagamento do motoboy: o total grande, as peças do preço
 * (liga, desliga e mexe nos valores só deste pedido, com prévia ao vivo) e o valor final com motivo.
 */
export function ValorCliente({ pedidoId, orc, regrasIniciais, bloqueado, onMudou }: {
  pedidoId: string; orc: Orcamento | null; regrasIniciais: Regras; bloqueado?: boolean; onMudou?: (regras: Regras) => void;
}) {
  const cfg = useConfiguracoes() as unknown as Record<string, unknown>;
  const perm = usePermissoes();
  const [regras, setRegras] = useState<Regras>(regrasIniciais);
  const [salvas, setSalvas] = useState<Regras>(regrasIniciais);
  const [previa, setPrevia] = useState<Orcamento | null>(null);
  const [aberto, setAberto] = useState<string | null>(null);
  const [ocupado, setOcupado] = useState(false);
  const mudou = JSON.stringify(regras) !== JSON.stringify(salvas);
  const pode = !bloqueado && perm.pode("editar_valor_pedido");

  useEffect(() => {
    if (!mudou) { setPrevia(null); return; }
    const t = setTimeout(() => { void supabase().rpc("previa_orcamento_pedido", { p_pedido: pedidoId, p_regras: regras }).then(({ data }) => setPrevia((data as Orcamento) ?? null)); }, 350);
    return () => clearTimeout(t);
  }, [JSON.stringify(regras)]); // eslint-disable-line react-hooks/exhaustive-deps

  const base = (previa ?? orc) as (Orcamento & { linhas: LinhaO[]; percentuais: { rotulo: string; pct: number }[]; total?: number }) | null;
  const definir = (k: string, v: ValorParametro | null) => setRegras((o) => { const n = { ...o }; if (v == null) delete n[k]; else n[k] = v; return n; });
  const ligada = (p: (typeof PECAS)[number]) => !p.desliga || !Object.entries(p.desliga).every(([k, v]) => regras[k] === v);
  const alternar = (p: (typeof PECAS)[number]) => setRegras((o) => {
    const n = { ...o };
    if (ligada(p)) Object.assign(n, p.desliga); else Object.keys(p.desliga ?? {}).forEach((k) => delete n[k]);
    return n;
  });
  const valorPeca = (p: (typeof PECAS)[number]) => {
    const v = (base?.linhas ?? []).filter(p.linha).reduce((s, l) => s + Number(l.valor ?? 0), 0);
    const pct = (base?.percentuais ?? []).filter((x) => p.pct?.(x.rotulo)).reduce((s, x) => s + Number(x.pct ?? 0), 0);
    return { v, pct };
  };

  async function salvar(r: Regras) {
    setOcupado(true);
    const { error } = await supabase().rpc("definir_regras_pedido", { p_pedido: pedidoId, p_regras: r });
    setOcupado(false);
    if (error) return toast(traduzir(error.message), "erro");
    setSalvas(r); setRegras(r); setPrevia(null); onMudou?.(r);
    toast(Object.keys(r).length ? "Preço deste pedido salvo." : "O pedido volta ao preço padrão.", "ok");
  }

  return (
    <div className="pag-editor valor-cliente">
      <div className="pag-cabeca">
        <span className="pag-rotulo"><Wallet size={14} aria-hidden /> Valor cobrado do cliente</span>
        <div className="pag-total">
          <strong>{moedaBr(Number(base?.total ?? 0))}</strong>
          <span className="pag-selos">
            {previa && <span className="selo">Prévia · antes {moedaBr(Number((orc as { total?: number } | null)?.total ?? 0))}</span>}
            {Object.keys(salvas).length > 0 && <span className="selo ouro"><Sparkles size={11} aria-hidden /> Só deste pedido</span>}
          </span>
        </div>
      </div>
      {pode ? (
        <>
          <div className="pag-calculos">
            {PECAS.map((p) => {
              const on = ligada(p);
              const { v, pct } = valorPeca(p);
              const Ic = p.icone;
              return (
                <div key={p.id} className={`pag-calc${on ? " ligado" : ""}`}>
                  <div className="pag-calc-topo">
                    <span className="pag-calc-icone"><Ic size={16} aria-hidden /></span>
                    <span className="pag-calc-nome"><strong>{p.nome}</strong><small>{p.dica}</small></span>
                    {on && (v > 0 || pct > 0) && <span className="pag-calc-valor">{v > 0 ? moedaBr(v) : ""}{v > 0 && pct > 0 ? " · " : ""}{pct > 0 ? `+${pct}%` : ""}</span>}
                    {p.desliga && <input type="checkbox" role="switch" aria-label={`Cobrar ${p.nome}`} checked={on} onChange={() => alternar(p)} />}
                  </div>
                  {on && (
                    <button type="button" className="pag-calc-abrir" aria-expanded={aberto === p.id} onClick={() => setAberto(aberto === p.id ? null : p.id)}>
                      Valores <ChevronDown size={14} aria-hidden style={{ transform: aberto === p.id ? "rotate(180deg)" : undefined }} />
                    </button>
                  )}
                  {on && aberto === p.id && <div className="pag-campos">{p.chaves.map((k) => <Campo key={k} chave={k} regras={regras} cfg={cfg} onDefinir={definir} />)}</div>}
                </div>
              );
            })}
          </div>
          <div className="linha-botoes">
            <button className="botao-ouro" disabled={ocupado || !mudou} onClick={() => salvar(regras)}><Check size={15} aria-hidden /> Salvar preço</button>
            {mudou && <button className="botao-texto" onClick={() => setRegras(salvas)}>Desfazer</button>}
            {Object.keys(salvas).length > 0 && <button className="botao-texto" disabled={ocupado} onClick={() => salvar({})}><RotateCcw size={14} aria-hidden /> Padrão</button>}
          </div>
          <p className="dica" style={{ margin: 0 }}>Muda só este pedido. O padrão de cada cliente fica no cadastro dele, e o geral em Ajustes → Preço.</p>
        </>
      ) : <p className="dica" style={{ margin: 0 }}>{bloqueado ? "Pedido fechado: o preço não muda mais." : "A plataforma não liberou mudar o valor do pedido."}</p>}
    </div>
  );
}
