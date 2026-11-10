"use client";

import { useEffect, useRef, useState } from "react";
import { MapPin } from "lucide-react";
import { geo, type Endereco } from "@/features/geo";

/** Campo de endereço com sugestões (OpenStreetMap). */
export function CampoEndereco({ valor, onTexto, onEscolher }: { valor: string; onTexto: (t: string) => void; onEscolher: (e: Endereco) => void }) {
  const [sugestoes, setSugestoes] = useState<Endereco[]>([]);
  const [aberto, setAberto] = useState(false);
  const digitado = useRef(false);

  useEffect(() => {
    if (!digitado.current) return;
    const t = setTimeout(async () => {
      const r = await geo.buscarEnderecos(valor);
      setSugestoes(r);
      setAberto(r.length > 0);
    }, 600);
    return () => clearTimeout(t);
  }, [valor]);

  return (
    <div className="campo-endereco">
      <input value={valor} placeholder="Rua, número, cidade"
        onChange={(e) => { digitado.current = true; onTexto(e.target.value); }}
        onFocus={() => setAberto(sugestoes.length > 0)}
        onBlur={() => setTimeout(() => setAberto(false), 150)} />
      {aberto && (
        <ul className="sugestoes">
          {sugestoes.map((s, i) => (
            <li key={i}>
              <button type="button" onMouseDown={() => { digitado.current = false; onEscolher(s); setAberto(false); }}>
                <MapPin size={13} aria-hidden style={{ verticalAlign: -2, marginRight: 6 }} />{s.descricao}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
