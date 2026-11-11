"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { ArrowDownToLine, ArrowUpFromLine, Building2, Combine, Hand, Lock, Package2, Pin, RotateCcw, Ruler, Send, Settings2, Store, Users } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { useConfiguracoes } from "@/features/configuracoes/useConfiguracoes";
import { PARAMETROS } from "@/features/configuracoes/definicoes";
import { CampoNumero } from "@/features/ui/CampoNumero";
import { toast } from "@/features/ui/toast";
import { traduzir } from "./tipos";

const BLOCOS: { chave: string; icone: LucideIcon; titulo: string; texto: (v: number) => string }[] = [
  { chave: "rota_raio_coleta_km", icone: ArrowUpFromLine, titulo: "Coletas", texto: (v) => v <= 0 ? "só a mesma coleta" : `a até ${v.toLocaleString("pt-BR")} km entre si` },
  { chave: "rota_raio_entrega_km", icone: ArrowDownToLine, titulo: "Entregas", texto: (v) => v <= 0 ? "só no mesmo endereço" : `a até ${v.toLocaleString("pt-BR")} km uma da outra` },
  { chave: "rota_max_entregas", icone: Package2, titulo: "Máximo", texto: (v) => `${v} entrega${v === 1 ? "" : "s"} por rota` },
  { chave: "rota_max_coletas", icone: Store, titulo: "Coletas por rota", texto: (v) => `até ${v}` },
  { chave: "rota_max_km", icone: Ruler, titulo: "Tamanho", texto: (v) => v <= 0 ? "sem limite de km" : `até ${v.toLocaleString("pt-BR")} km da coleta` },
];

/**
 * Revisão do pedido: como ele se junta com outros pedidos numa rota. Mostra o que vale (e de onde vem:
 * padrão, cliente ou só este pedido); clicar num bloco muda só para este pedido. A prévia logo abaixo se refaz.
 */
export function PainelJuntar({ pedidoId, empresaId, regras, onMudar }: {
  pedidoId: string; empresaId: string | null; regras: Record<string, unknown>; onMudar: (r: Record<string, unknown>) => void;
}) {
  const cfg = useConfiguracoes() as Record<string, unknown>;
  const [doCliente, setDoCliente] = useState<Record<string, unknown>>({});
  const [aberto, setAberto] = useState<string | null>(null);
  useEffect(() => {
    if (!empresaId) { setDoCliente({}); return; }
    void supabase().rpc("politicas_do_alvo", { p_escopo: "cliente", p_alvo: empresaId }).then(({ data }) => setDoCliente((data as Record<string, unknown>) ?? {}));
  }, [empresaId]);
  const def = (k: string) => PARAMETROS.find((p) => p.chave === k);
  const origem = (k: string) => (k in regras ? "pedido" : k in doCliente ? "cliente" : "padrao");
  const valor = (k: string) => (k in regras ? regras[k] : k in doCliente ? doCliente[k] : cfg[k] ?? def(k)?.padrao);
  const num = (k: string) => Number(valor(k) ?? 0);
  const bool = (k: string) => valor(k) === true || valor(k) === "true";

  async function salvar(k: string, v: unknown) {
    const novo = { ...regras };
    if (v == null) delete novo[k]; else novo[k] = v;
    const { error } = await supabase().rpc("definir_regras_pedido", { p_pedido: pedidoId, p_regras: novo });
    if (error) return toast(traduzir(error.message), "erro");
    onMudar(novo);
  }
  const Selo = ({ k }: { k: string }) => {
    const o = origem(k);
    return o === "pedido" ? <span className="selo" style={{ color: "var(--ouro)" }}><Pin size={11} aria-hidden /> só este pedido</span>
      : o === "cliente" ? <span className="selo" style={{ color: "#60a5fa" }}><Building2 size={11} aria-hidden /> do cliente</span>
        : <span className="selo">padrão</span>;
  };
  const junta = bool("roteirizar_agrupar");

  return (
    <section className="formulario vidro painel-juntar">
      <div className="titulo-linha">
        <h3 className="display" style={{ margin: 0 }}><Combine size={18} aria-hidden /> Juntar com outros pedidos</h3>
        <Selo k="roteirizar_agrupar" />
      </div>
      <p className="dica" style={{ margin: 0 }}>O que vale para este pedido. Clique para mudar só aqui; a prévia das rotas se refaz.</p>
      <div className="juntar-escolha" role="radiogroup" aria-label="Juntar com outros pedidos">
        <button type="button" role="radio" aria-checked={junta} className={junta ? "ativo" : ""} onClick={() => salvar("roteirizar_agrupar", true)}>
          <Combine size={16} aria-hidden /> <span><strong>Junta com outros</strong><small>Divide a rota com pedidos perto e no mesmo horário</small></span>
        </button>
        <button type="button" role="radio" aria-checked={!junta} className={!junta ? "ativo" : ""} onClick={() => salvar("roteirizar_agrupar", false)}>
          <Package2 size={16} aria-hidden /> <span><strong>Rota só dele</strong><small>Cada entrega vira uma rota própria</small></span>
        </button>
      </div>
      {junta && (
        <div className="juntar-blocos">
          {BLOCOS.map((b) => {
            const o = origem(b.chave); const ativo = aberto === b.chave; const d = def(b.chave);
            return (
              <div key={b.chave} className={`juntar-bloco origem-${o}${ativo ? " ativo" : ""}`}>
                <button type="button" className="botao-limpo juntar-cabeca" onClick={() => setAberto(ativo ? null : b.chave)} aria-expanded={ativo}>
                  <span className="juntar-icone"><b.icone size={17} aria-hidden /></span>
                  <span className="juntar-texto"><small>{b.titulo}</small><strong>{b.texto(num(b.chave))}</strong></span>
                  <Selo k={b.chave} />
                </button>
                {ativo && (
                  <div className="juntar-editar">
                    <CampoNumero valor={num(b.chave)} min={d?.min ?? 0} max={d?.max ?? 100} passo={d?.passo ?? 1} unidade={d?.unidade}
                      onSalvar={(v) => { void salvar(b.chave, v); setAberto(null); }} />
                    {o === "pedido" && <button type="button" className="botao-texto" onClick={() => { void salvar(b.chave, null); setAberto(null); }}>
                      <RotateCcw size={14} aria-hidden /> {b.chave in doCliente ? "Voltar ao do cliente" : "Voltar ao padrão"}</button>}
                  </div>
                )}
              </div>
            );
          })}
          <div className="linha-botoes">
            <button type="button" className={`chip${bool("rota_exclusiva_cliente") ? " ativo" : ""}`} onClick={() => salvar("rota_exclusiva_cliente", !bool("rota_exclusiva_cliente"))}>
              {bool("rota_exclusiva_cliente") ? <><Lock size={13} aria-hidden /> Só pedidos deste cliente</> : <><Users size={13} aria-hidden /> Mistura clientes</>}
            </button>
            <button type="button" className={`chip${bool("rota_revisao_gestor") ? " ativo" : ""}`} onClick={() => salvar("rota_revisao_gestor", !bool("rota_revisao_gestor"))}>
              {bool("rota_revisao_gestor") ? <><Hand size={13} aria-hidden /> Espera eu soltar</> : <><Send size={13} aria-hidden /> Sai sozinha</>}
            </button>
          </div>
        </div>
      )}
      <div className="linha-botoes">
        {empresaId && <Link className="botao-texto" href={`/gestor/empresas?e=${empresaId}`}><Building2 size={14} aria-hidden /> Sempre para este cliente</Link>}
        <Link className="botao-texto" href="/gestor/configuracoes?area=operacao"><Settings2 size={14} aria-hidden /> Mudar o padrão</Link>
      </div>
    </section>
  );
}
