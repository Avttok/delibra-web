"use client";

import { useEffect, useRef, useState } from "react";
import { Check, Copy, CreditCard, Loader2, QrCode, RefreshCw, X } from "lucide-react";
import { toast } from "@/features/ui/toast";
import { comSessao } from "./Recebimentos";

type Pix = { id: string; qr_code: string; qr_base64: string; expira_em: string; valor: number };
const moeda = (v: number) => Number(v ?? 0).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });

/**
 * Pagar um pedido (pré-pago) ou uma fatura: PIX com QR e copia-e-cola (confere sozinho a cada
 * poucos segundos) ou cartão na página segura do Mercado Pago.
 */
export function Pagar({ alvo, id, valor, onPago, onFechar }: { alvo: "pedido" | "fatura"; id: string; valor: number; onPago: () => void; onFechar: () => void }) {
  const [metodo, setMetodo] = useState<"pix" | "cartao">("pix");
  const [pix, setPix] = useState<Pix | null>(null);
  const [ocupado, setOcupado] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [agora, setAgora] = useState(() => Date.now());
  const pago = useRef(false);

  async function gerar(m: "pix" | "cartao") {
    setOcupado(true); setErro(null);
    const r = await comSessao("/api/pagamentos/criar", { alvo, id, metodo: m });
    setOcupado(false);
    if (r.erro) return setErro(String(r.erro));
    if (m === "cartao" && r.link) { window.location.href = String(r.link); return; }
    setPix(r as unknown as Pix);
  }
  useEffect(() => { void gerar("pix"); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // confere sozinho enquanto o QR está na tela
  useEffect(() => {
    if (!pix) return;
    const t = setInterval(async () => {
      setAgora(Date.now());
      if (pago.current) return;
      const r = await comSessao("/api/pagamentos/verificar", { id: pix.id });
      if (r.status === "aprovado") { pago.current = true; toast("Pagamento confirmado. Seu pedido já segue.", "ok", { titulo: "Pago" }); onPago(); }
    }, 5000);
    return () => clearInterval(t);
  }, [pix?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  const restante = pix ? Math.max(0, Math.round((new Date(pix.expira_em).getTime() - agora) / 1000)) : 0;
  const mmss = `${Math.floor(restante / 60)}:${String(restante % 60).padStart(2, "0")}`;

  return (
    <div className="pagar-fundo" role="dialog" aria-modal="true" aria-label="Pagar">
      <div className="pagar vidro">
        <div className="pagar-cabeca">
          <div><span className="rotulo">Pagar {alvo === "pedido" ? "pedido" : "fatura"}</span><strong className="figura texto-grad">{moeda(valor)}</strong></div>
          <button type="button" className="botao-icone" onClick={onFechar} aria-label="Fechar"><X size={18} /></button>
        </div>
        <div className="segmentado" style={{ gridTemplateColumns: "1fr 1fr" }} role="radiogroup">
          <button type="button" role="radio" aria-checked={metodo === "pix"} className={metodo === "pix" ? "ativo" : ""} onClick={() => { setMetodo("pix"); if (!pix) void gerar("pix"); }}><QrCode size={15} aria-hidden /> PIX</button>
          <button type="button" role="radio" aria-checked={metodo === "cartao"} className={metodo === "cartao" ? "ativo" : ""} onClick={() => setMetodo("cartao")}><CreditCard size={15} aria-hidden /> Cartão</button>
        </div>
        {erro && <p className="erro" style={{ margin: 0 }}>{erro}</p>}
        {metodo === "pix" && (
          ocupado && !pix ? <p className="dica"><Loader2 size={14} className="girando" aria-hidden /> Gerando o PIX…</p> : pix && (
            restante > 0 ? (
              <div className="pagar-pix">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={`data:image/png;base64,${pix.qr_base64}`} alt="QR code do PIX" width={220} height={220} />
                <p className="dica" style={{ margin: 0 }}>Abra o app do seu banco, escolha PIX e leia o QR, ou copie o código.</p>
                <div className="pagar-copia">
                  <code>{pix.qr_code}</code>
                  <button type="button" className="botao-ouro" onClick={() => { void navigator.clipboard?.writeText(pix.qr_code); toast("Código PIX copiado.", "ok"); }}><Copy size={15} aria-hidden /> Copiar</button>
                </div>
                <p className="dica" style={{ margin: 0 }}><Loader2 size={12} className="girando" aria-hidden /> Esperando o pagamento · vale por {mmss}</p>
              </div>
            ) : (
              <div className="pagar-pix">
                <p className="dica">Este PIX expirou.</p>
                <button type="button" className="botao-ouro" onClick={() => { setPix(null); void gerar("pix"); }}><RefreshCw size={15} aria-hidden /> Gerar outro</button>
              </div>
            )
          )
        )}
        {metodo === "cartao" && (
          <div className="pagar-pix">
            <p className="dica" style={{ margin: 0 }}>Você vai para a página segura do Mercado Pago para pagar com cartão de crédito ou débito (em até 12×). Depois volta para cá.</p>
            <button type="button" className="botao-ouro" disabled={ocupado} onClick={() => void gerar("cartao")}>{ocupado ? <Loader2 size={15} className="girando" aria-hidden /> : <CreditCard size={15} aria-hidden />} Pagar com cartão</button>
          </div>
        )}
        <p className="dica" style={{ margin: 0 }}><Check size={12} aria-hidden /> Assim que o pagamento é aprovado, o pedido segue sozinho.</p>
      </div>
    </div>
  );
}
