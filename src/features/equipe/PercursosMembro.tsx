"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { CaixaMapa } from "@/features/ui/CaixaMapa";
import { Copy, Package, Search } from "lucide-react";
import type { LngLatBoundsLike } from "maplibre-gl";
import { supabase } from "@/lib/supabase/client";
import { useMapa } from "@/lib/mapa/useMapa";
import { aplicarAjustes, buscarPercursos, criarCamadasPercurso, desenharPercursos, kmRegistro, linhaRegistro, separarRegistros, type Ajuste, type Ping } from "@/lib/mapa/percursos";
import { formatarPix } from "@/lib/pix/identificar";
import { toast } from "@/features/ui/toast";

const DIAS = ["Hoje", "Ontem", "Anteontem"];
const hora = (iso: string) => new Date(iso).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" });
const km = kmRegistro;
const diaIso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

/**
 * Percursos de um motoboy por dia, separados em registros (procurando corrida / corrida), com a chave PIX.
 * O traçado vem casado com as ruas (o servidor entende o caminho entre um ping e outro).
 */
export function PercursosMembro({ id, teste }: { id: string; teste: boolean }) {
  const caixa = useRef<HTMLDivElement>(null);
  const { mapa, pronto } = useMapa(caixa);
  const [dia, setDia] = useState(0);
  const [outroDia, setOutroDia] = useState<string>("");
  const [pings, setPings] = useState<Ping[] | null>(null);
  const [ajustes, setAjustes] = useState<Record<string, Ajuste>>({});
  const [destaque, setDestaque] = useState<number | null>(null);
  const [pix, setPix] = useState<{ tipo_chave: string; chave: string; titular: string } | null | undefined>(undefined);
  const [numeros, setNumeros] = useState<Record<string, string>>({});

  useEffect(() => {
    setPings(null); setDestaque(null); setAjustes({});
    const ini = outroDia ? new Date(`${outroDia}T00:00:00`) : new Date();
    if (!outroDia) { ini.setHours(0, 0, 0, 0); ini.setDate(ini.getDate() - dia); }
    const fim = new Date(ini); fim.setDate(fim.getDate() + 1);
    let vivo = true, tentativas = 0;
    async function carregar() {
      const r = await buscarPercursos({ de: ini, ate: fim, motoboy: id, teste });
      if (!vivo) return;
      if (r) {
        setPings(r.pings); setAjustes(r.ajustes);
        // o mapa demorou para casar algum trecho: tenta de novo (o que já foi feito fica guardado)
        if (r.parcial && tentativas++ < 4) setTimeout(() => { if (vivo) void carregar(); }, 4000);
        return;
      }
      // servidor fora: pings direto do banco (linha reta entre eles); percursos de teste e reais ficam separados
      const { data } = await supabase().from("localizacoes").select("lat,lng,status,corrida_id,registrado_em").eq("motoboy_id", id).eq("teste", teste)
        .gte("registrado_em", ini.toISOString()).lt("registrado_em", fim.toISOString()).order("registrado_em").limit(10000);
      if (vivo) setPings((data ?? []) as Ping[]);
    }
    void carregar();
    return () => { vivo = false; };
  }, [id, dia, teste, outroDia]);
  useEffect(() => { supabase().from("chaves_pix").select("tipo_chave,chave,titular").eq("usuario_id", id).eq("principal", true).maybeSingle().then(({ data }) => setPix(data ?? null)); }, [id]);

  const registros = useMemo(() => aplicarAjustes(separarRegistros(pings ?? []), id, ajustes), [pings, ajustes, id]);
  useEffect(() => {
    const ids = [...new Set(registros.map((r) => r.corridaId).filter(Boolean))] as string[];
    if (!ids.length) return;
    supabase().from("corridas").select("id,numero,teste").in("id", ids).then(({ data }) =>
      setNumeros(Object.fromEntries((data ?? []).map((c) => [c.id, `${c.teste ? "T" : "#"}${c.numero}`]))));
  }, [registros]);

  useEffect(() => {
    const m = mapa.current;
    if (!m || !pronto) return;
    criarCamadasPercurso(m, teste);
    desenharPercursos(m, registros, teste, destaque);
    const pts = (destaque != null ? (registros[destaque] ? linhaRegistro(registros[destaque]) : []) : registros.flatMap(linhaRegistro));
    if (pts.length) {
      const lng = pts.map((p) => p[1]), lat = pts.map((p) => p[0]);
      m.fitBounds([[Math.min(...lng), Math.min(...lat)], [Math.max(...lng), Math.max(...lat)]] as LngLatBoundsLike, { padding: 40, maxZoom: 16, duration: 500 });
    }
  }, [mapa, pronto, registros, destaque, teste]);

  return (
    <>
      <div className="filtro">
        {DIAS.map((d, i) => <button key={d} className={!outroDia && dia === i ? "ativo" : ""} onClick={() => { setOutroDia(""); setDia(i); }}>{d}</button>)}
        <label className={`filtro-data ${outroDia ? "ativo" : ""}`} title="Escolher outro dia">
          <input type="date" max={diaIso(new Date())} value={outroDia} onChange={(e) => setOutroDia(e.target.value)} aria-label="Outro dia" />
        </label>
      </div>
      <CaixaMapa refMapa={caixa} mapa={mapa} style={{ height: 320, borderRadius: 16, overflow: "hidden", border: "1px solid var(--borda)" }} titulo="Percursos" />
      <div className="legenda-percurso"><span>Início</span><span className={`degrade ${teste ? "teste" : ""}`} /><span>Fim</span></div>
      {pings == null ? <p className="dica">Carregando…</p> : registros.length === 0 ? <p className="vazio">Nenhum percurso neste dia.</p> : (
        <div className="registros" style={{ padding: 0 }}>
          {[...registros.entries()].reverse().map(([i, r]) => (
            <button key={i} type="button" className={`registro ${destaque === i ? "ativo" : ""}`} onClick={() => setDestaque(destaque === i ? null : i)}>
              {r.tipo === "corrida" ? <Package size={14} aria-hidden /> : <Search size={14} aria-hidden />}
              <span>{r.tipo === "corrida" ? `Corrida ${r.corridaId ? numeros[r.corridaId] ?? "" : ""}` : "Procurando corrida"}</span>
              <span className="dica">{hora(r.inicio)}–{hora(r.fim)} · {km(r).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} km</span>
            </button>
          ))}
          <p className="dica" style={{ margin: 0 }}>Total: {registros.reduce((s, r) => s + km(r), 0).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} km · {registros.filter((r) => r.tipo === "corrida").length} em corrida</p>
        </div>
      )}
      <span className="rotulo">Chave PIX principal</span>
      {pix === undefined ? <p className="dica">…</p> : pix ? (
        <button className="botao-texto" onClick={() => { navigator.clipboard?.writeText(pix.chave); toast("Chave PIX copiada.", "ok"); }}>
          <Copy size={14} aria-hidden /> {formatarPix(pix.chave, pix.tipo_chave)} · {pix.titular}
        </button>
      ) : <p className="dica" style={{ margin: 0 }}>Ainda não cadastrou a chave PIX no MotoApp.</p>}
    </>
  );
}
