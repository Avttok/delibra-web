"use client";

import { useState } from "react";
import { Dica } from "@/features/ui/Tour";
import { ChevronDown, Layers } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { EditorRegras, fmtRegra } from "@/features/configuracoes/Excecoes";
import { useConfiguracoes } from "@/features/configuracoes/useConfiguracoes";
import { PARAMETROS, type ValorParametro } from "@/features/configuracoes/definicoes";
import { toast } from "@/features/ui/toast";
import { traduzir } from "./tipos";

/** Regras que fazem sentido num pedido só (preço, junção em rotas, despacho, revisão). */
const DO_PEDIDO = PARAMETROS.filter((p) => (p.escopos?.includes("cliente") || p.escopos?.includes("tipo")) && !["pagamento", "faturas"].includes(p.grupo) && !p.soDev);

/**
 * A peça mais alta do lego: regras só deste pedido (vencem cliente, tipo e padrão).
 * Sem `pedidoId`, guarda no formulário; com ele, grava na hora e recalcula o orçamento.
 */
export function RegrasPedido({ valor, onMudar, pedidoId, aberto: abertoInicial = false }: {
  valor: Record<string, unknown>; onMudar?: (r: Record<string, unknown>) => void; pedidoId?: string; aberto?: boolean;
}) {
  const cfg = useConfiguracoes();
  const [aberto, setAberto] = useState(abertoInicial);
  const [busca, setBusca] = useState("");
  const [estado, setEstado] = useState<Record<string, "salvando" | "salvo" | "erro" | undefined>>({});
  const valores = valor as Record<string, ValorParametro>;
  const n = Object.keys(valores).length;

  async function definir(chave: string, v: ValorParametro | null) {
    const novo = { ...valores };
    if (v == null) delete novo[chave]; else novo[chave] = v;
    if (!pedidoId) { onMudar?.(novo); return; }
    setEstado((e) => ({ ...e, [chave]: "salvando" }));
    const { error } = await supabase().rpc("definir_regras_pedido", { p_pedido: pedidoId, p_regras: novo });
    if (error) { setEstado((e) => ({ ...e, [chave]: "erro" })); toast(traduzir(error.message), "erro"); return; }
    setEstado((e) => ({ ...e, [chave]: "salvo" }));
    setTimeout(() => setEstado((e) => ({ ...e, [chave]: undefined })), 1500);
    onMudar?.(novo);
  }

  return (
    <section className="formulario vidro regras-pedido">
      <button type="button" className="titulo-linha botao-limpo" onClick={() => setAberto(!aberto)} aria-expanded={aberto}>
        <h3 className="display" style={{ margin: 0 }}><Layers size={18} aria-hidden /> Regras deste pedido<Dica titulo="Regras deste pedido" texto="Mudam só este pedido e passam por cima das regras do cliente, do tipo e das gerais. O orçamento é refeito enquanto o pedido não saiu." /></h3>
        <span className="dica" style={{ marginLeft: "auto" }}>{n ? `${n} diferente${n === 1 ? "" : "s"}` : "padrão"}</span>
        <ChevronDown size={18} aria-hidden style={{ transform: aberto ? "rotate(180deg)" : undefined, transition: "transform .2s" }} />
      </button>
      {!aberto && n > 0 && (
        <div className="excecoes-alvos">
          {Object.entries(valores).map(([k, v]) => <span key={k} className="selo" style={{ color: "var(--ouro)" }}>{PARAMETROS.find((p) => p.chave === k)?.rotulo ?? k}: {fmtRegra(v, k)}</span>)}
        </div>
      )}
      {aberto && (
        <>
          <p className="dica" style={{ margin: 0 }}>Vale só para este pedido e vence as regras do cliente, do tipo e do sistema.{pedidoId ? " Mudar recalcula o orçamento se o pedido ainda não saiu." : ""}</p>
          <input placeholder="Buscar regra (ex.: km, juntar, urgente)" value={busca} onChange={(e) => setBusca(e.target.value)} />
          <EditorRegras params={DO_PEDIDO} valores={valores} cfg={cfg} estado={estado} onDefinir={definir} filtro={busca} />
        </>
      )}
    </section>
  );
}
