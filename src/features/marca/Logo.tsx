/**
 * Logo da Delibra: o D com as ondas de radar + o nome.
 * Desenhada em SVG com as cores do tema (var(--ouro) e var(--texto)), então segue
 * sozinha o dourado, o vermelho do Dev, o violeta do modo teste e as cores escolhidas.
 */
export function MarcaDelibra({ tamanho = 28 }: { tamanho?: number }) {
  return (
    <svg width={tamanho} height={tamanho} viewBox="0 0 48 48" aria-hidden className="marca-delibra">
      <path d="M10 6h13a18 18 0 0 1 0 36H10z" fill="none" stroke="var(--ouro)" strokeWidth="5" strokeLinejoin="round" />
      <path d="M18 23a8 8 0 0 1 8 8" fill="none" stroke="var(--ouro)" strokeWidth="3.2" strokeLinecap="round" />
      <path d="M18 16a15 15 0 0 1 15 15" fill="none" stroke="var(--ouro)" strokeWidth="3.2" strokeLinecap="round" opacity="0.55" />
      <circle cx="18" cy="31" r="3.4" fill="#5fd3a0" />
    </svg>
  );
}

export function Logo({ grande = false }: { grande?: boolean }) {
  const t = grande ? 64 : 30;
  return (
    <span className={`logo-delibra${grande ? " grande" : ""}`} role="img" aria-label="Delibra">
      <MarcaDelibra tamanho={t} />
      <span className="logo-delibra-nome" style={{ fontSize: grande ? 44 : 22 }}>delibra</span>
    </span>
  );
}
