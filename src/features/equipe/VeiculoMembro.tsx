"use client";

import { useEffect, useState } from "react";
import { Bike, Car, IdCard, Save, Truck } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

interface Veiculo { tipo: string; modelo: string; placa: string; cor: string; ano: string; cnh_numero: string; cnh_categoria: string; cnh_validade: string }
const VAZIO: Veiculo = { tipo: "moto", modelo: "", placa: "", cor: "", ano: "", cnh_numero: "", cnh_categoria: "", cnh_validade: "" };
const TIPOS: [string, string, typeof Bike][] = [["moto", "Moto", Bike], ["carro", "Carro", Car], ["bicicleta", "Bicicleta", Bike], ["van", "Van", Truck], ["outro", "Outro", Truck]];
const ERROS: Record<string, string> = {
  placa_invalida: "Placa inválida (ex.: ABC1D23 ou ABC1234).", cnh_invalida: "Número da CNH inválido (9 a 11 dígitos).",
  cnh_categoria_invalida: "Categoria da CNH inválida (A, B, AB…).", so_o_gestor_edita: "Só o gestor edita o veículo.",
};
const placaFmt = (p: string) => p.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 7).replace(/^([A-Z]{3})(\d)/, "$1-$2");

/** Veículo e CNH do motoboy (o app mostra no perfil; a placa pode ser exigida para pegar rota). */
export function VeiculoMembro({ id }: { id: string }) {
  const [v, setV] = useState<Veiculo>(VAZIO);
  const [salvando, setSalvando] = useState(false);
  useEffect(() => {
    supabase().from("motoboys").select("veiculo_tipo,veiculo_modelo,veiculo_placa,veiculo_cor,veiculo_ano,cnh_numero,cnh_categoria,cnh_validade").eq("id", id).maybeSingle()
      .then(({ data: d }) => {
        if (!d) return setV(VAZIO);
        setV({ tipo: d.veiculo_tipo ?? "moto", modelo: d.veiculo_modelo ?? "", placa: d.veiculo_placa ? placaFmt(d.veiculo_placa) : "", cor: d.veiculo_cor ?? "",
          ano: d.veiculo_ano ? String(d.veiculo_ano) : "", cnh_numero: d.cnh_numero ?? "", cnh_categoria: d.cnh_categoria ?? "", cnh_validade: d.cnh_validade ?? "" });
      });
  }, [id]);
  const set = (d: Partial<Veiculo>) => setV((x) => ({ ...x, ...d }));
  const vencida = v.cnh_validade && new Date(v.cnh_validade) < new Date();
  const vence30 = v.cnh_validade && !vencida && new Date(v.cnh_validade).getTime() - Date.now() < 30 * 86400_000;

  async function salvar() {
    setSalvando(true);
    const { error } = await supabase().rpc("salvar_veiculo", { p_motoboy: id, d: { ...v, ano: v.ano || null, cnh_validade: v.cnh_validade || null } });
    setSalvando(false);
    if (error) return toast(Object.entries(ERROS).find(([k]) => error.message.includes(k))?.[1] ?? error.message, "erro");
    toast("Veículo salvo.", "ok");
  }

  return (
    <div className="veiculo">
      <div className="segmentado segmentado-rolavel">
        {TIPOS.map(([k, r, I]) => <button key={k} type="button" className={v.tipo === k ? "ativo" : ""} onClick={() => set({ tipo: k })}><I size={14} aria-hidden /> {r}</button>)}
      </div>
      <div className="placa-preview" aria-hidden><span>BRASIL</span><strong>{v.placa || "ABC-1D23"}</strong></div>
      <div className="grade-campos">
        <label className="campo"><span>Placa</span><input value={v.placa} placeholder="ABC1D23" onChange={(e) => set({ placa: placaFmt(e.target.value) })} /></label>
        <label className="campo"><span>Modelo</span><input value={v.modelo} placeholder="Ex.: Honda CG 160" onChange={(e) => set({ modelo: e.target.value })} /></label>
        <label className="campo"><span>Cor</span><input value={v.cor} placeholder="Ex.: Preta" onChange={(e) => set({ cor: e.target.value })} /></label>
        <label className="campo"><span>Ano</span><input inputMode="numeric" value={v.ano} onChange={(e) => set({ ano: e.target.value.replace(/\D/g, "").slice(0, 4) })} /></label>
      </div>
      <span className="rotulo"><IdCard size={12} aria-hidden /> CNH</span>
      <div className="grade-campos">
        <label className="campo"><span>Número</span><input inputMode="numeric" value={v.cnh_numero} onChange={(e) => set({ cnh_numero: e.target.value.replace(/\D/g, "").slice(0, 11) })} /></label>
        <label className="campo"><span>Categoria</span>
          <select value={v.cnh_categoria} onChange={(e) => set({ cnh_categoria: e.target.value })}>
            <option value="">—</option>{["A", "B", "AB", "ACC", "C", "D", "E", "AC", "AD", "AE"].map((c) => <option key={c}>{c}</option>)}
          </select></label>
        <label className="campo"><span>Validade</span><input type="date" value={v.cnh_validade} onChange={(e) => set({ cnh_validade: e.target.value })} /></label>
      </div>
      {vencida && <p className="erro" style={{ margin: 0 }}>CNH vencida.</p>}
      {vence30 && <p className="dica" style={{ margin: 0, color: "var(--ouro)" }}>A CNH vence em menos de 30 dias.</p>}
      <div className="linha-botoes"><button className="botao-ouro" disabled={salvando} onClick={salvar}><Save size={16} aria-hidden /> {salvando ? "Salvando…" : "Salvar veículo"}</button></div>
    </div>
  );
}
