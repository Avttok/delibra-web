"use client";

import { useEffect, useRef, useState } from "react";
import { Eraser, Move, RotateCcw, X, ZoomIn } from "lucide-react";
import { cssFonte } from "@/features/marca/fontes";
import { AJUSTE_PADRAO, desenharIcone, temTransparencia, type AjusteIcone } from "./editorIcone";

/**
 * Janela para deixar o ícone bonito antes de salvar: zoom, posição (arrastando), margem e
 * "tirar o fundo" (o branco/cor das bordas vira transparente). Mostra como fica no escuro,
 * com o brilho da cor da empresa, e no claro.
 */
export function EditorIcone({ img, cor, nome, escalaInicial, brilhoCorInicial, brilhoInicial, fonte, onCancelar, onPronto }: {
  img: HTMLImageElement; cor: string | null | undefined; nome: string; escalaInicial?: number | null;
  brilhoCorInicial?: string | null; brilhoInicial?: number | null; fonte?: string | null;
  onCancelar: () => void; onPronto: (png: Blob, escala: number, brilhoCor: string | null, brilho: number) => void;
}) {
  const [escala, setEscala] = useState(Number(escalaInicial) || 1.9);
  const [brilhoCor, setBrilhoCor] = useState<string | null>(brilhoCorInicial ?? null);
  const [forca, setForca] = useState(brilhoInicial ?? 0.55);
  const [a, setA] = useState<AjusteIcone>(() => ({ ...AJUSTE_PADRAO, tirarFundo: !temTransparencia(img) }));
  const [url, setUrl] = useState<string | null>(null);
  const arrasto = useRef<{ x: number; y: number; dx: number; dy: number } | null>(null);
  const caixa = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    const t = setTimeout(() => {
      const c = desenharIcone(img, a, 512);
      canvas.current = c;
      setUrl(c.toDataURL("image/png"));
    }, 60);
    return () => clearTimeout(t);
  }, [img, a]);

  const set = (d: Partial<AjusteIcone>) => setA((x) => ({ ...x, ...d }));
  const brilho = brilhoCor ?? cor ?? "#d4af37";

  function inicio(e: React.PointerEvent) {
    (e.target as Element).setPointerCapture(e.pointerId);
    arrasto.current = { x: e.clientX, y: e.clientY, dx: a.dx, dy: a.dy };
  }
  function move(e: React.PointerEvent) {
    const r = arrasto.current; const el = caixa.current;
    if (!r || !el) return;
    const lado = el.getBoundingClientRect().width;
    set({ dx: Math.max(-0.5, Math.min(0.5, r.dx + (e.clientX - r.x) / lado)), dy: Math.max(-0.5, Math.min(0.5, r.dy + (e.clientY - r.y) / lado)) });
  }

  function salvar() {
    canvas.current?.toBlob((b) => { if (b) onPronto(b, escala, brilhoCor, forca); }, "image/png");
  }

  return (
    <div className="modal-fundo" role="dialog" aria-modal aria-label="Ajustar o ícone">
      <div className="modal vidro editor-icone">
        <button type="button" className="botao-icone modal-fechar" onClick={onCancelar} aria-label="Cancelar"><X size={18} /></button>
        <h2 className="display">Ajustar o ícone</h2>
        <div className="editor-icone-previas">
          <div ref={caixa} className="editor-icone-palco escuro" style={{ ["--brilho" as string]: brilho, ["--forca" as string]: `${Math.round(forca * 100)}%` }}
            onPointerDown={inicio} onPointerMove={move} onPointerUp={() => (arrasto.current = null)} title="Arraste para mover">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            {url && <img src={url} alt="" draggable={false} />}
            <span className="editor-icone-dica"><Move size={12} aria-hidden /> arraste</span>
          </div>
          <div className="editor-icone-mini">
            <div className="editor-icone-palco claro">{/* eslint-disable-next-line @next/next/no-img-element */}{url && <img src={url} alt="" />}</div>
            <div className="editor-icone-palco xadrez">{/* eslint-disable-next-line @next/next/no-img-element */}{url && <img src={url} alt="" />}</div>
            <small>No claro e o que ficou transparente</small>
          </div>
        </div>

        <div className="editor-icone-topo" aria-label="Prévia do topo do app">
          <span className="logo-empresa-brilho" style={{ ["--brilho" as string]: brilho, ["--forca" as string]: `${Math.round(forca * 100)}%`, width: Math.round(30 * escala / 1.4), height: Math.round(30 * escala / 1.4) }}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            {url && <img src={url} alt="" className="logo-empresa-icone" style={{ width: "100%", height: "100%" }} />}
          </span>
          <strong style={{ fontFamily: fonte ? cssFonte(fonte) : undefined }}>{nome}</strong>
          <span className="editor-icone-topo-botoes"><i /><i /></span>
        </div>
        <label className="editor-icone-controle"><span>Tamanho no topo</span>
          <input type="range" min={0.8} max={2.6} step={0.05} value={escala} onChange={(e) => setEscala(Number(e.target.value))} /></label>
        <div className="editor-icone-controle"><span>Cor do brilho</span>
          <span className="editor-icone-cores">
            <button type="button" className={`cor-bolinha${brilhoCor == null ? " ativa" : ""}`} style={{ background: cor ?? "#d4af37" }} onClick={() => setBrilhoCor(null)} title="Cor da empresa">A</button>
            {["#d4af37", "#ffffff", "#ef4444", "#f472b6", "#a78bfa", "#3b82f6", "#22d3ee", "#34d399", "#fb923c", "#facc15"].map((h) => (
              <button key={h} type="button" className={`cor-bolinha${brilhoCor === h ? " ativa" : ""}`} style={{ background: h }} onClick={() => setBrilhoCor(h)} aria-label={`Brilho ${h}`} />
            ))}
            <input type="color" value={brilhoCor ?? cor ?? "#d4af37"} onChange={(e) => setBrilhoCor(e.target.value)} aria-label="Outra cor" />
          </span>
        </div>
        <label className="editor-icone-controle"><span>Força do brilho</span>
          <input type="range" min={0} max={1} step={0.01} value={forca} onChange={(e) => setForca(Number(e.target.value))} /></label>
        <label className="editor-icone-controle"><span><ZoomIn size={14} aria-hidden /> Zoom</span>
          <input type="range" min={0.4} max={2.5} step={0.01} value={a.zoom} onChange={(e) => set({ zoom: Number(e.target.value) })} /></label>
        <label className="editor-icone-controle"><span>Margem</span>
          <input type="range" min={0} max={0.25} step={0.005} value={a.margem} onChange={(e) => set({ margem: Number(e.target.value) })} /></label>
        <label className="opcao"><span><Eraser size={14} aria-hidden /> <strong>Tirar o fundo</strong><br /><span className="dica">A cor das bordas (branco, por exemplo) vira transparente.</span></span>
          <input type="checkbox" role="switch" checked={a.tirarFundo} onChange={(e) => set({ tirarFundo: e.target.checked })} /></label>
        {a.tirarFundo && (
          <label className="editor-icone-controle"><span>Quanto tirar</span>
            <input type="range" min={8} max={140} step={1} value={a.tolerancia} onChange={(e) => set({ tolerancia: Number(e.target.value) })} /></label>
        )}
        <div className="linha-botoes linha-botoes-iguais">
          <button type="button" className="botao-texto" onClick={() => setA({ ...AJUSTE_PADRAO, tirarFundo: !temTransparencia(img) })}><RotateCcw size={15} aria-hidden /> Voltar</button>
          <button type="button" className="botao" onClick={salvar} disabled={!url}>Salvar</button>
        </div>
      </div>
    </div>
  );
}
