"use client";

import { useRef, useState } from "react";
import { ImagePlus, SlidersHorizontal, Trash2 } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { MarcaDelibra } from "@/features/marca/Logo";
import { EditorIcone } from "./EditorIcone";
import { carregarImagem, carregarUrl } from "./editorIcone";

/**
 * Ícone da empresa: substitui o Delibra no app do motoboy, no site e no atalho do celular.
 * `onSalvar` grava a URL (o gestor usa salvar_minha_organizacao; o Dev, definir_marca_organizacao).
 */
export function IconeEmpresa({ orgId, nome, logo, cor, escala, original, brilhoCor, brilho, fonte, onSalvar }: {
  orgId: string; nome: string; logo: string | null; cor?: string | null; escala?: number | null;
  /** Imagem original guardada (para reajustar sem enviar outra), brilho e fonte do nome. */
  original?: string | null; brilhoCor?: string | null; brilho?: number | null; fonte?: string | null;
  onSalvar: (logo: string | null, extras?: Record<string, unknown>) => Promise<string | null>;
}) {
  const entrada = useRef<HTMLInputElement>(null);
  const [enviando, setEnviando] = useState(false);
  const [atual, setAtual] = useState(logo);
  const [editando, setEditando] = useState<HTMLImageElement | null>(null);
  const [arquivoNovo, setArquivoNovo] = useState<File | null>(null);

  async function escolher(f: File | undefined) {
    if (!f) return;
    if (!f.type.startsWith("image/")) return toast("Escolha uma imagem (PNG, JPG ou WEBP).", "erro");
    try { setEditando(await carregarImagem(f)); setArquivoNovo(f); } catch { toast("Não deu para abrir esta imagem.", "erro"); }
    if (entrada.current) entrada.current.value = "";
  }

  /** Reajustar sem enviar outra: abre a original guardada (ou a logo atual). */
  async function ajustar() {
    const url = original ?? atual;
    if (!url) return;
    try { setArquivoNovo(null); setEditando(await carregarUrl(url)); } catch { toast("Não deu para abrir a imagem atual.", "erro"); }
  }

  async function enviar(png: Blob, esc: number, corBrilho: string | null, forca: number) {
    setEditando(null);
    setEnviando(true);
    try {
      const agora = Date.now();
      const caminho = `${orgId}/icone-${agora}.png`;
      const sb = supabase();
      const { error } = await sb.storage.from("marcas").upload(caminho, png, { contentType: "image/png", upsert: false });
      if (error) throw new Error(error.message);
      const url = sb.storage.from("marcas").getPublicUrl(caminho).data.publicUrl;
      let urlOriginal: string | undefined;
      if (arquivoNovo) {
        const c2 = `${orgId}/original-${agora}.${arquivoNovo.type.split("/")[1] || "png"}`;
        const up = await sb.storage.from("marcas").upload(c2, arquivoNovo, { contentType: arquivoNovo.type, upsert: false });
        if (!up.error) urlOriginal = sb.storage.from("marcas").getPublicUrl(c2).data.publicUrl;
      }
      const erro = await onSalvar(url, { logo_escala: esc, brilho_cor: corBrilho ?? "", brilho: forca, ...(urlOriginal ? { logo_original_url: urlOriginal } : {}) });
      if (erro) throw new Error(erro);
      setAtual(url);
      toast("Ícone salvo. O app e o site já passam a usar ele.", "ok", { titulo: "Ícone da empresa" });
    } catch (e) {
      toast(`Não deu para salvar o ícone: ${(e as Error).message}`, "erro");
    }
    setEnviando(false);
  }

  async function remover() {
    setEnviando(true);
    const erro = await onSalvar(null, { logo_original_url: "" });
    if (erro) toast(erro, "erro"); else { setAtual(null); toast("Voltou para o ícone do Delibra.", "info"); }
    setEnviando(false);
  }

  const icone = atual
    // eslint-disable-next-line @next/next/no-img-element
    ? <span className="icone-marca" style={{ ["--brilho" as string]: brilhoCor ?? cor ?? "#d4af37", ["--forca" as string]: `${Math.round((brilho ?? 0.55) * 100)}%` }}><img src={atual} alt="" /></span>
    : <span className="icone-padrao"><MarcaDelibra tamanho={40} /></span>;

  return (
    <div className="icone-empresa">
      <div className="icone-empresa-previas" aria-label="Como o ícone aparece">
        <figure className="previa-celular">
          <div className="previa-tela" style={{ background: cor ? `linear-gradient(160deg, ${cor}, #0b0b0d 70%)` : undefined }}>
            {[0, 1, 2].map((i) => <span key={i} className="previa-app vazio" />)}
            <span className="previa-app">{icone}<small>{atual ? nome : "Delibra"}</small></span>
            {[0, 1, 2, 3].map((i) => <span key={`b${i}`} className="previa-app vazio" />)}
          </div>
          <figcaption>Tela do celular</figcaption>
        </figure>
        <figure className="previa-topo">
          <div className="previa-barra">{icone}<strong>{atual ? nome : "delibra"}</strong></div>
          <figcaption>Topo do app e do site</figcaption>
        </figure>
      </div>
      <div className="linha-botoes">
        <button type="button" className="botao" disabled={enviando} onClick={() => entrada.current?.click()}>
          <ImagePlus size={16} aria-hidden /> {enviando ? "Enviando…" : atual ? "Trocar ícone" : "Enviar ícone"}
        </button>
        {atual && <button type="button" className="botao-texto" disabled={enviando} onClick={() => void ajustar()}><SlidersHorizontal size={15} aria-hidden /> Ajustar</button>}
        {atual && <button type="button" className="botao-icone perigo" disabled={enviando} onClick={remover} aria-label="Voltar ao ícone do Delibra" title="Voltar ao ícone do Delibra"><Trash2 size={16} /></button>}
      </div>
      <p className="dica" style={{ margin: 0 }}>PNG com fundo transparente fica melhor; se a imagem tiver fundo, o editor tira. Dá para ajustar zoom, posição e margem antes de salvar. No celular, o motoboy coloca o atalho com este ícone em Ajustes → Ícone na tela inicial.</p>
      {editando && <EditorIcone img={editando} cor={cor} nome={nome} escalaInicial={escala} brilhoCorInicial={brilhoCor} brilhoInicial={brilho} fonte={fonte}
        onCancelar={() => setEditando(null)} onPronto={(b, e, bc, f) => void enviar(b, e, bc, f)} />}
      <input ref={entrada} type="file" accept="image/png,image/jpeg,image/webp" hidden onChange={(e) => escolher(e.target.files?.[0])} />
    </div>
  );
}
