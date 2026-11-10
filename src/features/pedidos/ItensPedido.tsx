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

/** Itens prontos para o servidor (índices dos pontos, números). */
export function itensParaEnvio(itens: ItemForm[], chavesPontos: string[]) {
  return itens.filter((x) => x.categoria_id || x.descricao.trim()).map((x) => ({
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
export function ItensPedido({ itens, onMudar, categorias, pontos, semCategoria = true, objetos, onSalvarObjeto, onApagarObjeto, entregaFixa, soGerais, compacto }: {
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
  /** Só os itens que não estão presos a uma entrega (vão para todas). */
  soGerais?: boolean;
  /** Botões menores (dentro do ponto). */
  compacto?: boolean;
}) {
  const chavesEntrega = new Set(pontos.filter((p) => p.tipo === "entrega").map((p) => p.chave));
  const visiveis = entregaFixa ? itens.filter((x) => x.entrega === entregaFixa) : soGerais ? itens.filter((x) => !x.entrega || !chavesEntrega.has(x.entrega)) : itens;
  const novo = (categoria = ""): ItemForm => ({ ...novoItem(categoria), entrega: entregaFixa ?? "" });
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
            {(coletas.length > 1 || (entregas.length > 1 && !entregaFixa)) && (
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
