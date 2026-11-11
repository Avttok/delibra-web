"use client";

import { useEffect } from "react";
import { aplicarFonteUsuario, lerFonteUsuario } from "./fontes";

/** Aplica a fonte escolhida por esta pessoa (Menu da foto → Fonte) assim que o site abre. */
export function FonteUsuario() {
  useEffect(() => { aplicarFonteUsuario(lerFonteUsuario()); }, []);
  return null;
}
