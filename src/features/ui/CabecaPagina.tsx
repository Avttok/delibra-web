import type { LucideIcon } from "lucide-react";
import type { ReactNode } from "react";

/** Cabeçalho padrão: ícone em azulejo dourado, título largo, subtítulo e ações. */
export function CabecaPagina({ icone: Icone, titulo, subtitulo, children }: {
  icone: LucideIcon;
  titulo: string;
  subtitulo?: string;
  children?: ReactNode;
}) {
  return (
    <header className="cabeca">
      <span className="cabeca-icone grad-suave"><Icone size={22} aria-hidden /></span>
      <div className="cabeca-texto">
        <h1 className="display">{titulo}</h1>
        {subtitulo && <p>{subtitulo}</p>}
      </div>
      {children}
    </header>
  );
}
