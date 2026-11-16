"use client";

import { useState } from "react";
import { Search, Settings2, X } from "lucide-react";
import Link from "next/link";
import { supabase } from "@/lib/supabase/client";
import { useConta } from "@/features/conta/conta";
import { usePermissoes } from "@/features/conta/permissoes";
import { Parametro } from "./PainelConfiguracoes";
import { GRUPOS, PARAMETROS, igualPadrao, type DefParametro, type GrupoParametro, type ValorParametro } from "./definicoes";
import { useConfiguracoes } from "./useConfiguracoes";
import { combina } from "@/features/ui/busca";

type Estado = "salvando" | "salvo" | "erro" | undefined;

/**
 * Ajustes na hora: o botão abre, numa janela à parte, só os ajustes que mexem nesta tela, já editáveis.
 * Vale a mesma cascata das Configurações: o Dev decide o que cada gestor vê e muda; o soDev fica travado para o gestor.
 */
export function AjustesRapidos({ grupos = [], chaves = [], titulo = "Ajustes desta tela", rotulo = "Ajustes" }: {
  grupos?: GrupoParametro[]; chaves?: string[]; titulo?: string; rotulo?: string;
}) {
  const [aberto, setAberto] = useState(false);
  const conta = useConta();
  const perm = usePermissoes();
  if (!conta.dev && !perm.pode("ajustes")) return null;
  return (
    <>
      <button type="button" className="botao-vidro pequeno ajustes-rapidos-botao" onClick={() => setAberto(true)} title={titulo}>
        <Settings2 size={14} aria-hidden /> {rotulo}
      </button>
      {aberto && <JanelaAjustes grupos={grupos} chaves={chaves} titulo={titulo} onFechar={() => setAberto(false)} />}
    </>
  );
}

function JanelaAjustes({ grupos, chaves, titulo, onFechar }: { grupos: GrupoParametro[]; chaves: string[]; titulo: string; onFechar: () => void }) {
  const cfg = useConfiguracoes();
  const conta = useConta();
  const perm = usePermissoes();
  const [busca, setBusca] = useState("");
  const [estado, setEstado] = useState<Record<string, Estado>>({});
  const lista = PARAMETROS.filter((p) => (grupos.includes(p.grupo) || chaves.includes(p.chave)) && (conta.dev || (!p.escondido && perm.nivel(p.chave) !== "oculto")))
    .filter((p) => !busca.trim() || combina(busca.trim().toLowerCase(), p.rotulo, p.descricao, p.chave));
  async function salvar(p: DefParametro, v: ValorParametro) {
    setEstado((e) => ({ ...e, [p.chave]: "salvando" }));
    const r = await supabase().rpc("salvar_ajuste", { p_chave: p.chave, p_valor: v });
    setEstado((e) => ({ ...e, [p.chave]: r.error ? "erro" : "salvo" }));
    if (!r.error) setTimeout(() => setEstado((e) => ({ ...e, [p.chave]: undefined })), 1800);
  }
  const porGrupo = [...new Set(lista.map((p) => p.grupo))];
  return (
    <div className="modal-fundo" role="dialog" aria-modal="true" aria-label={titulo} onClick={(e) => { if (e.target === e.currentTarget) onFechar(); }}>
      <div className="modal modal-ajustes">
        <button type="button" className="botao-icone modal-fechar" aria-label="Fechar" onClick={onFechar}><X size={16} aria-hidden /></button>
        <h2><Settings2 size={18} aria-hidden /> {titulo}</h2>
        <p className="dica" style={{ margin: 0 }}>Muda na hora e já vale aqui. Para exceções por cliente, motoboy ou tipo, use <Link href="/gestor/configuracoes">Configurações</Link>.</p>
        <label className="config-busca"><Search size={15} aria-hidden /><input placeholder="Buscar nestes ajustes…" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
        {porGrupo.length === 0 && <p className="vazio">Nada para ajustar aqui com a sua permissão.</p>}
        {porGrupo.map((g) => (
          <section key={g} className="config-secao">
            <h3 className="rotulo">{GRUPOS[g].titulo}</h3>
            {lista.filter((p) => p.grupo === g).map((p) => (
              <Parametro key={p.chave} p={p} valor={cfg[p.chave] ?? p.padrao} estado={estado[p.chave]} mostrarGrupo={false} onSalvar={(v) => salvar(p, v)}
                bloqueado={(p.soDev && !conta.dev) || perm.nivel(p.chave) === "ver"}
                onPadrao={!igualPadrao(p, cfg[p.chave]) && !(p.soDev && !conta.dev) && perm.nivel(p.chave) === "editar" ? () => salvar(p, p.padrao) : undefined} />
            ))}
          </section>
        ))}
      </div>
    </div>
  );
}
