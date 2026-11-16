"use client";

import { BookmarkPlus, PackageCheck, Plus, Trash2, TriangleAlert, X } from "lucide-react";
import { Icone } from "@/features/ui/icones";
import type { Campo, Categoria } from "./tipos";

/** Item no formulário. `coleta`/`entrega` = chave do ponto (vira índice ao enviar). */
export interface ItemForm {
  chave: string; categoria_id: string; descricao: string; quantidade: string; peso_kg: string;
  comprimento_cm: string; largura_cm: string; altura_cm: string; valor_declarado: string; coleta: string; entrega: string;
  /** Veio de um objeto salvo (para contar quantas vezes ele é usado). */
  objeto_id?: string;
  /** Item da coleta: quanto dele vai para cada entrega (chave do ponto → quantidade). */
  destinos?: Record<string, number>;
}

/** Objeto salvo pelo cliente: um produto que ele manda sempre. */
export interface ObjetoSalvo {
  id: string; nome: string; usos?: number;
  dados: Partial<Omit<ItemForm, "chave" | "coleta" | "entrega" | "objeto_id">>;
}
/** O que guardar de um item como objeto (sem os pontos do pedido). */
export const dadosDoObjeto = (x: ItemForm): ObjetoSalvo["dados"] => ({
  categoria_id: x.categoria_id, descricao: x.descricao, quantidade: x.quantidade, peso_kg: x.peso_kg,
  comprimento_cm: x.comprimento_cm, largura_cm: x.largura_cm, altura_cm: x.altura_cm, valor_declarado: x.valor_declarado,
});
let seq = 0;
export const novoItem = (categoria_id = ""): ItemForm => ({ chave: `it${++seq}`, categoria_id, descricao: "", quantidade: "1", peso_kg: "", comprimento_cm: "", largura_cm: "", altura_cm: "", valor_declarado: "", coleta: "", entrega: "" });
const num = (s: string) => (s.trim() === "" ? null : Number(s.replace(",", ".")));

/** O que cada categoria pede (sem categoria: tudo opcional, menos o valor). */
export function camposDe(k?: Categoria | null): Record<"descricao" | "peso" | "medidas" | "valor" | "quantidade", Campo> {
  return {
    descricao: k?.campo_descricao ?? "opcional", peso: k?.campo_peso ?? "opcional", medidas: k?.campo_medidas ?? "opcional",
    valor: k?.campo_valor ?? (k ? "oculto" : "opcional"), quantidade: k?.campo_quantidade ?? "opcional",
  };
}

/** Quantas unidades do item ainda não têm entrega. */
export const restante = (x: ItemForm) => Math.max(1, Math.round(num(x.quantidade) ?? 1)) - Object.values(x.destinos ?? {}).reduce((a, b) => a + b, 0);

/**
 * Itens da coleta divididos pelas entregas: cada parte vira uma linha (mesmo item, a quantidade daquela entrega).
 * O que sobrar sem entrega segue "para todas". Com uma entrega só, tudo vai para ela.
 */
export function dividirPorEntrega(itens: ItemForm[], chavesEntrega: string[]): ItemForm[] {
  return itens.flatMap((x) => {
    const total = Math.max(1, Math.round(num(x.quantidade) ?? 1));
    const d = Object.entries(x.destinos ?? {}).filter(([k, q]) => q > 0 && chavesEntrega.includes(k));
    if (!d.length) return [chavesEntrega.length === 1 && !x.entrega ? { ...x, entrega: chavesEntrega[0] } : x];
    const valor = num(x.valor_declarado);
    const parte = (q: number, entrega: string): ItemForm => ({ ...x, quantidade: String(q), entrega, destinos: undefined,
      valor_declarado: valor != null ? String(Math.round((valor * q / total) * 100) / 100) : x.valor_declarado });
    const out = d.map(([k, q]) => parte(Math.min(q, total), k));
    const sobra = total - d.reduce((a, [, q]) => a + q, 0);
    if (sobra > 0) out.push(parte(sobra, ""));
    return out;
  });
}

/** Itens prontos para o servidor (índices dos pontos, números). */
export function itensParaEnvio(itens: ItemForm[], chavesPontos: string[], chavesEntrega?: string[]) {
  return (chavesEntrega ? dividirPorEntrega(itens, chavesEntrega) : itens).filter((x) => x.categoria_id || x.descricao.trim()).map((x) => ({
    descricao: x.descricao.trim(), categoria_id: x.categoria_id || null, quantidade: Math.max(1, Math.round(num(x.quantidade) ?? 1)),
    peso_kg: num(x.peso_kg), comprimento_cm: num(x.comprimento_cm), largura_cm: num(x.largura_cm), altura_cm: num(x.altura_cm), valor_declarado: num(x.valor_declarado),
    coleta: x.coleta && chavesPontos.includes(x.coleta) ? chavesPontos.indexOf(x.coleta) : null,
    entrega: x.entrega && chavesPontos.includes(x.entrega) ? chavesPontos.indexOf(x.entrega) : null,
  }));
}

/** O que falta preencher (campos obrigatórios da categoria). */
export function faltandoItens(itens: ItemForm[], categorias: Categoria[]): string | null {
  for (const x of itens) {
    const k = categorias.find((c) => c.id === x.categoria_id);
    const c = camposDe(k);
    const nome = k?.nome ?? "item";
    if (c.peso === "obrigatorio" && !(Number(num(x.peso_kg)) > 0)) return `Informe o peso (${nome}).`;
    if (c.valor === "obrigatorio" && !(Number(num(x.valor_declarado)) > 0)) return `Informe o valor declarado (${nome}).`;
    if (c.descricao === "obrigatorio" && !x.descricao.trim()) return `Descreva o item (${nome}).`;
    if (c.medidas === "obrigatorio" && !(Number(num(x.comprimento_cm)) > 0 && Number(num(x.largura_cm)) > 0 && Number(num(x.altura_cm)) > 0)) return `Informe as medidas (${nome}).`;
  }
  return null;
}

/**
 * Itens do pedido: o cliente toca no tipo (botões com ícone) e só aparecem os campos que aquele tipo pede.
 * Ex.: documento não pede peso nem valor; peça automotiva pede valor declarado.
 */
export function ItensPedido({ itens, onMudar, categorias, pontos, semCategoria = true, objetos, onSalvarObjeto, onApagarObjeto, entregaFixa, coletaFixa, soGerais, compacto }: {
  itens: ItemForm[];
  onMudar: (l: ItemForm[]) => void;
  categorias: Categoria[];
  pontos: { chave: string; tipo: "coleta" | "entrega"; endereco: string }[];
  /** Mostra o botão "Outro" (item sem categoria). */
  semCategoria?: boolean;
  /** Objetos salvos (undefined = sem objetos salvos para esta conta). */
  objetos?: ObjetoSalvo[];
  onSalvarObjeto?: (item: ItemForm) => void;
  onApagarObjeto?: (o: ObjetoSalvo) => void;
  /** Itens de um ponto de entrega só (1 remessa ↔ 1 endereço): mostra só os dele, os novos já vão para ele e some o "Vai para". */
  entregaFixa?: string;
  /** Itens de uma coleta ("o que se coleta aqui"): mostra só os dela e os novos já saem dela. */
  coletaFixa?: string;
  /** Só os itens que não estão presos a uma entrega (vão para todas). */
  soGerais?: boolean;
  /** Botões menores (dentro do ponto). */
  compacto?: boolean;
}) {
  const chavesEntrega = new Set(pontos.filter((p) => p.tipo === "entrega").map((p) => p.chave));
  const visiveis = coletaFixa ? itens.filter((x) => x.coleta === coletaFixa) : entregaFixa ? itens.filter((x) => x.entrega === entregaFixa) : soGerais ? itens.filter((x) => !x.entrega || !chavesEntrega.has(x.entrega)) : itens;
  const novo = (categoria = ""): ItemForm => ({ ...novoItem(categoria), entrega: entregaFixa ?? "", coleta: coletaFixa ?? "" });
  const mudar = (k: string, d: Partial<ItemForm>) => onMudar(itens.map((x) => (x.chave === k ? { ...x, ...d } : x)));
  const coletas = pontos.filter((p) => p.tipo === "coleta"), entregas = pontos.filter((p) => p.tipo === "entrega");
  const rot = (s: string, c: Campo) => (c === "obrigatorio" ? `${s} *` : s);
  return (
    <div className={`itens-pedido${compacto ? " compacto" : ""}`}>
      {objetos && objetos.length > 0 && (
        <div className="itens-objetos" role="group" aria-label="Meus objetos">
          <span className="rotulo"><PackageCheck size={12} aria-hidden /> Meus objetos</span>
          <div className="linha-chips">
            {objetos.map((o) => {
              const k = categorias.find((c) => c.id === o.dados.categoria_id);
              return (
                <span key={o.id} className="chip modelo">
                  <button type="button" title="Colocar no pedido" onClick={() => onMudar([...itens, { ...novo(o.dados.categoria_id ?? ""), ...o.dados, objeto_id: o.id }])}>
                    <Icone nome={k?.icone ?? "box"} size={13} /> {o.nome}
                  </button>
                  {onApagarObjeto && <button type="button" className="tirar" aria-label={`Apagar o objeto ${o.nome}`} onClick={() => onApagarObjeto(o)}><X size={12} /></button>}
                </span>
              );
            })}
          </div>
        </div>
      )}
      <div className="itens-tipos" role="group" aria-label="Adicionar item">
        {categorias.map((k) => (
          <button key={k.id} type="button" className={`item-tipo ${k.perigoso ? "perigoso" : ""}`} onClick={() => onMudar([...itens, novo(k.id)])} title={k.descricao ?? k.nome}>
            <Icone nome={k.icone} size={18} /><span>{k.nome}</span><Plus size={13} aria-hidden className="mais" />
          </button>
        ))}
        {semCategoria && (
          <button type="button" className="item-tipo" onClick={() => onMudar([...itens, novo("")])}><Icone nome="box" size={18} /><span>Outro</span><Plus size={13} aria-hidden className="mais" /></button>
        )}
      </div>
      {visiveis.map((x) => {
        const k = categorias.find((c) => c.id === x.categoria_id);
        const c = camposDe(k);
        return (
          <div key={x.chave} className={`item-form ${k?.perigoso ? "perigoso" : ""}`}>
            <div className="item-cabeca">
              <span className="item-icone"><Icone nome={k?.icone ?? "box"} size={17} /></span>
              <strong>{k?.nome ?? "Outro"}</strong>
              {k?.perigoso && <span className="selo" style={{ color: "var(--vermelho)" }}><TriangleAlert size={11} aria-hidden /> {k.classe_risco ?? "Perigoso"}</span>}
              {k?.fragil && <span className="selo" style={{ color: "var(--ouro)" }}>Frágil</span>}
              <span className="espaco" />
              {c.quantidade !== "oculto" && (
                <span className="passo-qtd" aria-label="Quantidade">
                  <button type="button" onClick={() => mudar(x.chave, { quantidade: String(Math.max(1, (num(x.quantidade) ?? 1) - 1)) })} aria-label="Menos">−</button>
                  <input inputMode="numeric" value={x.quantidade} onChange={(e) => mudar(x.chave, { quantidade: e.target.value.replace(/\D/g, "") })} />
                  <button type="button" onClick={() => mudar(x.chave, { quantidade: String((num(x.quantidade) ?? 0) + 1) })} aria-label="Mais">+</button>
                </span>
              )}
              {onSalvarObjeto && <button type="button" className="icone" title="Salvar como objeto (para usar de novo)" aria-label="Salvar como objeto" onClick={() => onSalvarObjeto(x)}><BookmarkPlus size={14} /></button>}
              <button type="button" className="icone" aria-label="Remover item" onClick={() => onMudar(itens.filter((y) => y.chave !== x.chave))}><Trash2 size={14} /></button>
            </div>
            {c.descricao !== "oculto" && (
              <input placeholder={c.descricao === "obrigatorio" ? "Descreva o item *" : "Detalhe (opcional)"} value={x.descricao} onChange={(e) => mudar(x.chave, { descricao: e.target.value })} />
            )}
            {(c.peso !== "oculto" || c.medidas !== "oculto" || c.valor !== "oculto") && (
              <div className="item-numeros">
                {c.peso !== "oculto" && <label><span>{rot("Peso (kg)", c.peso)}</span><input inputMode="decimal" value={x.peso_kg} onChange={(e) => mudar(x.chave, { peso_kg: e.target.value })} /></label>}
                {c.medidas !== "oculto" && <>
                  <label><span>{rot("C (cm)", c.medidas)}</span><input inputMode="decimal" value={x.comprimento_cm} onChange={(e) => mudar(x.chave, { comprimento_cm: e.target.value })} /></label>
                  <label><span>{rot("L (cm)", c.medidas)}</span><input inputMode="decimal" value={x.largura_cm} onChange={(e) => mudar(x.chave, { largura_cm: e.target.value })} /></label>
                  <label><span>{rot("A (cm)", c.medidas)}</span><input inputMode="decimal" value={x.altura_cm} onChange={(e) => mudar(x.chave, { altura_cm: e.target.value })} /></label>
                </>}
                {c.valor !== "oculto" && <label><span>{rot("Valor (R$)", c.valor)}</span><input inputMode="decimal" value={x.valor_declarado} onChange={(e) => mudar(x.chave, { valor_declarado: e.target.value })} /></label>}
              </div>
            )}
            {!coletaFixa && (coletas.length > 1 || (entregas.length > 1 && !entregaFixa)) && (
              <div className="item-numeros">
                {coletas.length > 1 && <label><span>Sai de</span><select value={x.coleta} onChange={(e) => mudar(x.chave, { coleta: e.target.value })}>
                  <option value="">Qualquer coleta</option>{coletas.map((p) => <option key={p.chave} value={p.chave}>{pontos.indexOf(p) + 1}. {p.endereco.split(",")[0] || "Coleta"}</option>)}</select></label>}
                {entregas.length > 1 && !entregaFixa && <label><span>Vai para</span><select value={x.entrega} onChange={(e) => mudar(x.chave, { entrega: e.target.value })}>
                  <option value="">Todas as entregas</option>{entregas.map((p) => <option key={p.chave} value={p.chave}>{pontos.indexOf(p) + 1}. {p.endereco.split(",")[0] || "Entrega"}</option>)}</select></label>}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

/**
 * Na entrega: os itens das coletas viram botões. Toque para mandar para esta entrega; com mais de uma unidade,
 * use − e + para dizer quantas vão para cá. Só aparece o que foi colocado nas coletas.
 */
export function DestinosEntrega({ itens, onMudar, categorias, entrega, pontos }: {
  itens: ItemForm[]; onMudar: (l: ItemForm[]) => void; categorias: Categoria[]; entrega: string;
  pontos: { chave: string; tipo: "coleta" | "entrega"; endereco: string }[];
}) {
  const daColeta = itens.filter((x) => x.coleta && pontos.some((p) => p.chave === x.coleta && p.tipo === "coleta"));
  if (!daColeta.length) return <p className="dica" style={{ margin: 0 }}>Coloque os itens na coleta (“O que se coleta aqui”) e escolha aqui o que vem para esta entrega.</p>;
  const mudar = (x: ItemForm, q: number) => onMudar(itens.map((y) => (y.chave === x.chave ? { ...y, destinos: { ...(y.destinos ?? {}), [entrega]: Math.max(0, q) } } : y)));
  return (
    <div className="destinos-entrega" role="group" aria-label="O que vai para esta entrega">
      {daColeta.map((x) => {
        const k = categorias.find((c) => c.id === x.categoria_id);
        const total = Math.max(1, Math.round(num(x.quantidade) ?? 1));
        const aqui = x.destinos?.[entrega] ?? 0;
        const livre = restante(x);
        const nome = x.descricao.trim() || k?.nome || "Item";
        const coleta = pontos.findIndex((p) => p.chave === x.coleta) + 1;
        return (
          <span key={x.chave} className={`chip destino${aqui > 0 ? " ativo" : ""}`}>
            <button type="button" title={`Da coleta ${coleta}`} disabled={aqui === 0 && livre <= 0}
              onClick={() => mudar(x, aqui > 0 ? 0 : total === 1 ? 1 : Math.max(1, livre))}>
              <Icone nome={k?.icone ?? "box"} size={13} /> {nome}{total > 1 && <small> {aqui}/{total}</small>}
            </button>
            {total > 1 && aqui > 0 && <>
              <button type="button" className="tirar" aria-label={`Menos ${nome}`} onClick={() => mudar(x, aqui - 1)}>−</button>
              <button type="button" className="tirar" aria-label={`Mais ${nome}`} disabled={livre <= 0} onClick={() => mudar(x, aqui + 1)}>+</button>
            </>}
          </span>
        );
      })}
    </div>
  );
}
