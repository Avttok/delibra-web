"use client";

import { useRef, useState } from "react";
import { ImagePlus, Trash2 } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { MarcaDelibra } from "@/features/marca/Logo";

/** Recorta o centro da imagem num quadrado de 512 px (PNG), o formato dos ícones de celular. */
async function quadrado(arquivo: File, lado = 512): Promise<Blob> {
  const url = URL.createObjectURL(arquivo);
  try {
    const img = await new Promise<HTMLImageElement>((ok, erro) => { const i = new Image(); i.onload = () => ok(i); i.onerror = erro; i.src = url; });
    const m = Math.min(img.naturalWidth, img.naturalHeight);
    const c = document.createElement("canvas"); c.width = lado; c.height = lado;
    const g = c.getContext("2d")!;
    g.imageSmoothingQuality = "high";
    g.drawImage(img, (img.naturalWidth - m) / 2, (img.naturalHeight - m) / 2, m, m, 0, 0, lado, lado);
    return await new Promise<Blob>((ok, erro) => c.toBlob((b) => (b ? ok(b) : erro(new Error("imagem"))), "image/png"));
  } finally { URL.revokeObjectURL(url); }
}

/**
 * Ícone da empresa: substitui o Delibra no app do motoboy, no site e no atalho do celular.
 * `onSalvar` grava a URL (o gestor usa salvar_minha_organizacao; o Dev, definir_marca_organizacao).
 */
export function IconeEmpresa({ orgId, nome, logo, cor, onSalvar }: {
  orgId: string; nome: string; logo: string | null; cor?: string | null;
  onSalvar: (logo: string | null) => Promise<string | null>;
}) {
  const entrada = useRef<HTMLInputElement>(null);
  const [enviando, setEnviando] = useState(false);
  const [atual, setAtual] = useState(logo);

  async function escolher(f: File | undefined) {
    if (!f) return;
    if (!f.type.startsWith("image/")) return toast("Escolha uma imagem (PNG, JPG ou WEBP).", "erro");
    setEnviando(true);
    try {
      const png = await quadrado(f);
      const caminho = `${orgId}/icone-${Date.now()}.png`;
      const sb = supabase();
      const { error } = await sb.storage.from("marcas").upload(caminho, png, { contentType: "image/png", upsert: true });
      if (error) throw new Error(error.message);
      const url = sb.storage.from("marcas").getPublicUrl(caminho).data.publicUrl;
      const erro = await onSalvar(url);
      if (erro) throw new Error(erro);
      setAtual(url);
      toast("Ícone salvo. O app e o site já passam a usar ele.", "ok", { titulo: "Ícone da empresa" });
    } catch (e) {
      toast(`Não deu para salvar o ícone: ${(e as Error).message}`, "erro");
    }
    setEnviando(false);
    if (entrada.current) entrada.current.value = "";
  }

  async function remover() {
    setEnviando(true);
    const erro = await onSalvar(null);
    if (erro) toast(erro, "erro"); else { setAtual(null); toast("Voltou para o ícone do Delibra.", "info"); }
    setEnviando(false);
  }

  const icone = atual
    // eslint-disable-next-line @next/next/no-img-element
    ? <img src={atual} alt="" />
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
        {atual && <button type="button" className="botao-icone perigo" disabled={enviando} onClick={remover} aria-label="Voltar ao ícone do Delibra" title="Voltar ao ícone do Delibra"><Trash2 size={16} /></button>}
      </div>
      <p className="dica" style={{ margin: 0 }}>Use uma imagem quadrada, de preferência 512 × 512. Se não for quadrada, o centro é recortado. No celular, o motoboy coloca o atalho com este ícone em Ajustes → Ícone na tela inicial.</p>
      <input ref={entrada} type="file" accept="image/png,image/jpeg,image/webp" hidden onChange={(e) => escolher(e.target.files?.[0])} />
    </div>
  );
}
