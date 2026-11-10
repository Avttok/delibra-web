"use client";

import { Monitor, Moon, Sun } from "lucide-react";
import { useTema } from "./tema";

const ROTULO = { sistema: "Tema automático", claro: "Tema claro", escuro: "Tema noturno" } as const;

export function BotaoTema() {
  const { preferencia, alternar } = useTema();
  const Icone = preferencia === "sistema" ? Monitor : preferencia === "claro" ? Sun : Moon;
  return (
    <button type="button" className="botao-icone" onClick={alternar} title={`${ROTULO[preferencia]} (clique para trocar)`} aria-label={ROTULO[preferencia]}>
      <Icone size={18} aria-hidden />
    </button>
  );
}
