"use client";

import { useState } from "react";
import { Check, ChevronDown, Inbox, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { useRecarregarAoMudar } from "@/features/corridas/dados";
import { toast } from "@/features/ui/toast";
import { MapaCorridas } from "@/features/corridas/MapaCorridas";
import { traduzir } from "@/features/pedidos/tipos";
import { useEtapa } from "@/features/ui/useEtapa";

interface Cadastro {
  id: string; email: string; nome: string; responsavel: string | null; tipo: "pj" | "pf"; documento: string | null; telefone: string | null;
  endereco: string | null; lat?: number | null; lng?: number | null; observacoes: string | null; status: "pendente" | "aprovado" | "recusado"; criado_em: string;
}
const doc = (d: string | null, t: string) => !d ? "sem documento" : t === "pf"
  ? d.replace(/^(\d{3})(\d{3})(\d{3})(\d{2})$/, "$1.$2.$3-$4") : d.replace(/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/, "$1.$2.$3/$4-$5");

/** Empresas que se cadastraram pelo site do cliente e esperam a aprovação do gestor. */
export function CadastrosPendentes({ onAprovado }: { onAprovado: (empresaId: string | null) => void }) {
  const [lista, setLista] = useState<Cadastro[]>([]);
  const [aberto, setAberto] = useEtapa<string | null>("cad-aberto", null);
  const [express, setExpress] = useState(false);
  const [cobranca, setCobranca] = useState<"" | "pre_pago" | "credito">("");
  const [motivo, setMotivo] = useState("");
  useRecarregarAoMudar(["cadastros_cliente"], async () => {
    const { data } = await supabase().from("cadastros_cliente").select("*").eq("status", "pendente").order("criado_em");
    setLista((data ?? []) as Cadastro[]);
  }, "cadastros");
  if (!lista.length) return null;

  async function revisar(c: Cadastro, aprovar: boolean) {
    if (!aprovar && !confirm(`Recusar o cadastro de ${c.nome}?`)) return;
    const { data, error } = await supabase().rpc("revisar_cadastro", { p_id: c.id, p_aprovar: aprovar, p_motivo: motivo || null,
      p_opcoes: aprovar ? { pode_express: express, ...(cobranca ? { cobranca } : {}) } : {} });
    if (error) return toast(traduzir(error.message), "erro");
    setLista((l) => l.filter((x) => x.id !== c.id));
    setAberto(null); setMotivo("");
    toast(aprovar ? `${c.nome} aprovado: já pode pedir.` : "Cadastro recusado.", "ok");
    if (aprovar) onAprovado((data as { empresa_id?: string } | null)?.empresa_id ?? null);
  }

  return (
    <section className="bloco alerta-bloco cadastros">
      <span className="rotulo"><Inbox size={12} aria-hidden /> Cadastros esperando você · {lista.length}</span>
      {lista.map((c) => (
        <div key={c.id} className="cadastro">
          <button type="button" className="botao-limpo" onClick={() => { setAberto(aberto === c.id ? null : c.id); setExpress(false); setCobranca(""); }}>
            <span style={{ flex: 1, minWidth: 0 }}><strong>{c.nome}</strong><br /><small className="dica">{doc(c.documento, c.tipo)} · {new Date(c.criado_em).toLocaleDateString("pt-BR")}</small></span>
            <ChevronDown size={16} aria-hidden style={{ transform: aberto === c.id ? "rotate(180deg)" : undefined }} />
          </button>
          {aberto === c.id && (
            <div className="cadastro-corpo">
              <p className="dica" style={{ margin: 0 }}>{[c.responsavel, c.email, c.telefone].filter(Boolean).join(" · ")}</p>
              {c.endereco && <p className="dica" style={{ margin: 0 }}>{c.endereco}</p>}
              {c.lat != null && c.lng != null && (
                <div className="mini-mapa"><MapaCorridas paradas={[{ chave: c.id, lat: c.lat, lng: c.lng, tipo: "coleta", rotulo: "1" }]} enquadrar={c.id} /></div>
              )}
              {c.observacoes && <p className="dica" style={{ margin: 0 }}>“{c.observacoes}”</p>}
              <label className="opcao"><span>Já pode pedir Express</span><input type="checkbox" role="switch" checked={express} onChange={(e) => setExpress(e.target.checked)} /></label>
              <label className="campo"><span>Cobrança</span>
                <select value={cobranca} onChange={(e) => setCobranca(e.target.value as typeof cobranca)}>
                  <option value="">Padrão do cadastro (Configurações → Site do cliente)</option>
                  <option value="pre_pago">Paga antes (PIX/cartão)</option><option value="credito">Crédito (fatura)</option>
                </select></label>
              <input placeholder="Motivo (se recusar, o cliente vê)" value={motivo} onChange={(e) => setMotivo(e.target.value)} />
              <div className="linha-botoes">
                <button className="botao-ouro" onClick={() => revisar(c, true)}><Check size={15} aria-hidden /> Aprovar</button>
                <button className="botao-perigo" onClick={() => revisar(c, false)}><X size={15} aria-hidden /> Recusar</button>
              </div>
            </div>
          )}
        </div>
      ))}
    </section>
  );
}
