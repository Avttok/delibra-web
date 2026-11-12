"use client";

import { useEffect, useMemo, useState } from "react";
import { HandCoins, Tags } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { EditorCalculos } from "@/features/corridas/PagamentoMotoboy";
import { EditorPecasPreco } from "@/features/pedidos/ValorCliente";
import { usePermissoes } from "@/features/conta/permissoes";
import { PARAMETROS, igualPadrao, type ValorParametro } from "./definicoes";
import { useConfiguracoes } from "./useConfiguracoes";

type Regras = Record<string, ValorParametro>;

/** Chaves que os editores visuais cobrem (somem da lista comum para não aparecer duas vezes). */
export const CHAVES_PAGAMENTO = PARAMETROS.filter((p) => ["pag_combinar", "pag_km", "pag_zonas", "pag_entrega", "pag_fixo"].includes(p.grupo)
  || ["repasse_motoboy_pct", "pag_volta", "pag_volta_valor_km", "pag_volta_pct"].includes(p.chave)).map((p) => p.chave);
export const CHAVES_PRECO = ["preco_base", "preco_km", "preco_distancia_modo", "orcamento_trajeto", "soma_inclui_saida", "soma_inclui_entrega_extra", "preco_coleta_extra",
  "preco_entrega_extra", "preco_pacotes_inclusos", "preco_pacote_extra", "preco_kg_incluso", "preco_kg", "cubagem_fator", "preco_perigoso_pct", "preco_perigoso_fixo",
  "preco_express_pct", "preco_urgente_pct", "zona_combinar", "zona_cliente_exclusiva", "valor_minimo", "arredondamento"];

/**
 * O padrão da empresa no mesmo editor das rotas e dos pedidos: pagamento do motoboy (cálculos que se juntam)
 * e preço do cliente (as peças do orçamento). Cada mudança salva sozinha como ajuste da empresa.
 */
export function AjusteVisual({ tipo }: { tipo: "pagamento" | "preco" }) {
  const cfg = useConfiguracoes() as unknown as Record<string, ValorParametro>;
  const perm = usePermissoes();
  const chaves = tipo === "pagamento" ? CHAVES_PAGAMENTO : CHAVES_PRECO;
  // o que a empresa já mudou do padrão aparece como "próprio" (em dourado, com voltar)
  const doCfg = useMemo(() => Object.fromEntries(chaves.flatMap((k) => {
    const p = PARAMETROS.find((x) => x.chave === k);
    return p && cfg[k] !== undefined && !igualPadrao(p, cfg[k]) ? [[k, cfg[k]]] : [];
  })) as Regras, [JSON.stringify(chaves.map((k) => cfg[k]))]); // eslint-disable-line react-hooks/exhaustive-deps
  const [regras, setRegras] = useState<Regras>(doCfg);
  useEffect(() => setRegras(doCfg), [doCfg]);
  const travado = chaves.every((k) => perm.nivel(k) !== "editar");

  async function mudar(novo: Regras) {
    const antes = regras;
    setRegras(novo);
    const sb = supabase();
    const mudadas = Object.keys(novo).filter((k) => JSON.stringify(novo[k]) !== JSON.stringify(antes[k]));
    const tiradas = Object.keys(antes).filter((k) => !(k in novo));
    for (const k of mudadas) {
      if (perm.nivel(k) !== "editar") continue;
      const { error } = await sb.rpc("salvar_ajuste", { p_chave: k, p_valor: novo[k] });
      if (error) { toast(error.message.includes("ajuste_bloqueado") ? "Este ajuste está travado pela plataforma." : error.message, "erro"); setRegras(antes); return; }
    }
    for (const k of tiradas) {
      if (perm.nivel(k) !== "editar") continue;
      const p = PARAMETROS.find((x) => x.chave === k);
      const { error } = await sb.rpc("salvar_ajuste", { p_chave: k, p_valor: p?.padrao ?? null });
      if (error) { toast(error.message, "erro"); setRegras(antes); return; }
    }
    if (mudadas.length || tiradas.length) toast("Salvo.", "ok", { duracao: 1500 });
  }

  const Ic = tipo === "pagamento" ? HandCoins : Tags;
  return (
    <section className={`ajuste-visual${travado ? " travado" : ""}`}>
      <h3><Ic size={17} aria-hidden /> {tipo === "pagamento" ? "Como o motoboy é pago (padrão)" : "Como o pedido é cobrado (padrão)"}</h3>
      <p className="dica" style={{ margin: 0 }}>
        {tipo === "pagamento" ? "Ligue os cálculos que entram, mude os valores de cada um e escolha como juntar. Cada rota pode mudar isso depois."
          : "Ligue as peças que entram no preço e mude os valores de cada uma. Cada cliente e cada pedido podem mudar isso depois."}
        {" "}Salva sozinho.
      </p>
      <fieldset disabled={travado} style={{ border: 0, padding: 0, margin: 0 }}>
        {tipo === "pagamento" ? <EditorCalculos regras={regras} onMudar={(r) => void mudar(r)} /> : <EditorPecasPreco regras={regras} onMudar={(r) => void mudar(r)} />}
      </fieldset>
      {travado && <p className="dica" style={{ margin: 0 }}>A plataforma deixou só para ver.</p>}
    </section>
  );
}
