"use client";

import { useEffect, useRef, useState } from "react";
import { Eraser, Move, RotateCcw, X, ZoomIn } from "lucide-react";
import { AJUSTE_PADRAO, desenharIcone, temTransparencia, type AjusteIcone } from "./editorIcone";

/**
 * Janela para deixar o ícone bonito antes de salvar: zoom, posição (arrastando), margem e
 * "tirar o fundo" (o branco/cor das bordas vira transparente). Mostra como fica no escuro,
 * com o brilho da cor da empresa, e no claro.
 */
export function EditorIcone({ img, cor, onCancelar, onPronto }: {
  img: HTMLImageElement; cor: string | null | undefined; onCancelar: () => void; onPronto: (png: Blob) => void;
}) {
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
  const brilho = cor ?? "#d4af37";

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
    canvas.current?.toBlob((b) => { if (b) onPronto(b); }, "image/png");
  }

  return (
    <div className="modal-fundo" role="dialog" aria-modal aria-label="Ajustar o ícone">
      <div className="modal vidro editor-icone">
        <button type="button" className="botao-icone modal-fechar" onClick={onCancelar} aria-label="Cancelar"><X size={18} /></button>
        <h2 className="display">Ajustar o ícone</h2>
        <div className="editor-icone-previas">
          <div ref={caixa} className="editor-icone-palco escuro" style={{ ["--brilho" as string]: brilho }}
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
