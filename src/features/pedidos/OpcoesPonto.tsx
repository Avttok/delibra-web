"use client";

import { Camera, Clock, KeyRound, PenLine, UserRound } from "lucide-react";

/** Confirmações e horário de um ponto (coleta ou entrega). null = segue o padrão da rota. */
export interface OpcoesDoPonto {
  exige_foto?: boolean | null; exige_nome?: boolean | null; exige_assinatura?: boolean | null; exige_codigo?: boolean | null;
  janela_de?: string; janela_ate?: string;
}
export type Confirmacao = "foto" | "nome" | "assinatura" | "codigo";
const CONF: { k: Confirmacao; rotulo: string; dica: string; icone: typeof Camera }[] = [
  { k: "foto", rotulo: "Foto", dica: "O motoboy fotografa o volume no local.", icone: Camera },
  { k: "nome", rotulo: "Nome", dica: "O motoboy anota o nome de quem entregou ou recebeu.", icone: UserRound },
  { k: "assinatura", rotulo: "Assinatura", dica: "Quem recebe assina na tela do celular do motoboy.", icone: PenLine },
  { k: "codigo", rotulo: "Código", dica: "Um código de 4 dígitos: você passa para quem vai entregar ou receber.", icone: KeyRound },
];

/**
 * Confirmações que este ponto exige e o horário em que ele atende.
 * `liberadas` = o que o gestor deixou pedir; `padrao` = o que a rota já pede nas entregas (aparece fixo).
 */
export function OpcoesPonto({ tipo, valor, onMudar, liberadas, padrao, comJanela }: {
  tipo: "coleta" | "entrega";
  valor: OpcoesDoPonto;
  onMudar: (d: OpcoesDoPonto) => void;
  liberadas: Partial<Record<Confirmacao, boolean>>;
  padrao?: Partial<Record<Confirmacao, boolean>>;
  comJanela: boolean;
}) {
  const visiveis = CONF.filter((c) => liberadas[c.k] || (tipo === "entrega" && padrao?.[c.k]));
  if (!visiveis.length && !comJanela) return null;
  return (
    <div className="confirmacoes">
      {visiveis.length > 0 && <>
        <span className="rotulo">{tipo === "coleta" ? "Na coleta, o motoboy confirma com" : "Na entrega, o motoboy confirma com"}</span>
        <div className="linha-chips">
          {visiveis.map(({ k, rotulo, dica, icone: I }) => {
            const fixo = tipo === "entrega" && Boolean(padrao?.[k]);
            const campo = `exige_${k}` as const;
            const ligado = fixo || valor[campo] === true;
            return (
              <button key={k} type="button" className={`chip-opcao ${ligado ? "ativo" : ""} ${fixo ? "fixo" : ""}`} aria-pressed={ligado}
                title={fixo ? `${dica} A Delibra já pede isso em toda entrega.` : dica} disabled={fixo || !liberadas[k]}
                onClick={() => onMudar({ [campo]: ligado ? null : true })}>
                <I size={13} aria-hidden /> {rotulo}
              </button>
            );
          })}
        </div>
      </>}
      {comJanela && (
        <label className="janela-ponto">
          <Clock size={13} aria-hidden /> Atende das
          <input type="time" value={valor.janela_de ?? ""} onChange={(e) => onMudar({ janela_de: e.target.value })} aria-label="Atende a partir de" />
          às
          <input type="time" value={valor.janela_ate ?? ""} onChange={(e) => onMudar({ janela_ate: e.target.value })} aria-label="Atende até" />
          {(valor.janela_de || valor.janela_ate) && <button type="button" className="link" onClick={() => onMudar({ janela_de: "", janela_ate: "" })}>limpar</button>}
        </label>
      )}
    </div>
  );
}

/** Selos do que um ponto pede (para o detalhe do pedido e da rota). */
export function SelosPonto({ p }: { p: OpcoesDoPonto & { codigo?: string | null } }) {
  const lista = CONF.filter((c) => p[`exige_${c.k}` as const]);
  if (!lista.length && !p.janela_de && !p.janela_ate) return null;
  return (
    <div className="selos-ponto">
      {lista.map(({ k, rotulo, icone: I }) => <span key={k} className="selo"><I size={11} aria-hidden /> {rotulo}{k === "codigo" && p.codigo ? ` ${p.codigo}` : ""}</span>)}
      {(p.janela_de || p.janela_ate) && <span className="selo"><Clock size={11} aria-hidden /> {p.janela_de?.slice(0, 5) || "…"}–{p.janela_ate?.slice(0, 5) || "…"}</span>}
    </div>
  );
}
