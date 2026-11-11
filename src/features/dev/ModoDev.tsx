"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Building2, Check, ChevronDown, CodeXml, Globe, SquareDashed } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

type Empresa = { id: string; nome: string; nome_app: string | null; logo: string | null; cor: string | null; status: string; motoboys: number };
type Estado = { modo: "tudo" | "vazio" | "empresa"; foco: string | null; empresas: Empresa[] };

/**
 * Modo Dev (só para o Dev): troca, por cima de tudo, a empresa que o site e o app mostram.
 * "Tudo" vê a plataforma inteira; "Em branco" mostra como fica uma conta sem empresa.
 */
export function ModoDev() {
  const [estado, setEstado] = useState<Estado | null>(null);
  const [aberto, setAberto] = useState(false);
  const [trocando, setTrocando] = useState(false);
  const caixa = useRef<HTMLDivElement>(null);

  const carregar = useCallback(async () => {
    const { data } = await supabase().rpc("dev_empresas_foco");
    if (data) setEstado(data as Estado);
  }, []);
  useEffect(() => { void carregar(); }, [carregar]);
  useEffect(() => {
    if (!aberto) return;
    const fora = (e: MouseEvent) => { if (!caixa.current?.contains(e.target as Node)) setAberto(false); };
    document.addEventListener("mousedown", fora);
    return () => document.removeEventListener("mousedown", fora);
  }, [aberto]);

  async function escolher(modo: Estado["modo"], org?: string) {
    setTrocando(true);
    const { error } = await supabase().rpc("dev_definir_modo", { p_modo: modo, p_org: org ?? null });
    if (error) { setTrocando(false); return toast(error.message, "erro"); }
    window.location.reload();
  }

  if (!estado) return null;
  const atual = estado.modo === "empresa" ? estado.empresas.find((e) => e.id === estado.foco) : null;
  const rotulo = estado.modo === "vazio" ? "Em branco" : atual ? (atual.nome_app || atual.nome) : "Tudo";

  return (
    <div className="modo-dev" ref={caixa}>
      <button type="button" className={`modo-dev-botao modo-${estado.modo}`} onClick={() => setAberto((a) => !a)} aria-expanded={aberto} disabled={trocando}
        title="Modo Dev: escolha o que o site e o app mostram">
        <CodeXml size={15} aria-hidden /><span>{trocando ? "Trocando…" : rotulo}</span><ChevronDown size={14} aria-hidden />
      </button>
      {aberto && (
        <div className="modo-dev-caixa vidro" role="menu">
          <p className="modo-dev-titulo">Ver como</p>
          <button type="button" role="menuitem" className="modo-dev-item" onClick={() => escolher("tudo")}>
            <span className="modo-dev-icone"><Globe size={16} /></span><span><strong>Tudo</strong><small>A plataforma inteira, sem filtro</small></span>
            {estado.modo === "tudo" && <Check size={16} className="modo-dev-ok" />}
          </button>
          <button type="button" role="menuitem" className="modo-dev-item" onClick={() => escolher("vazio")}>
            <span className="modo-dev-icone"><SquareDashed size={16} /></span><span><strong>Em branco</strong><small>Como uma conta sem empresa</small></span>
            {estado.modo === "vazio" && <Check size={16} className="modo-dev-ok" />}
          </button>
          <p className="modo-dev-titulo">Empresas</p>
          <div className="modo-dev-lista">
            {estado.empresas.length === 0 && <p className="dica" style={{ margin: "4px 8px" }}>Nenhuma empresa ainda. Crie em Dev → Empresas.</p>}
            {estado.empresas.map((e) => (
              <button key={e.id} type="button" role="menuitem" className="modo-dev-item" onClick={() => escolher("empresa", e.id)}>
                <span className="modo-dev-icone" style={{ background: e.cor ?? undefined, backgroundImage: e.logo ? `url("${e.logo}")` : undefined }}>
                  {!e.logo && <Building2 size={16} />}
                </span>
                <span><strong>{e.nome_app || e.nome}</strong><small>{e.nome_app ? `${e.nome} · ` : ""}{e.motoboys} motoboy{e.motoboys === 1 ? "" : "s"}{e.status !== "ativa" ? ` · ${e.status}` : ""}</small></span>
                {estado.modo === "empresa" && estado.foco === e.id && <Check size={16} className="modo-dev-ok" />}
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
