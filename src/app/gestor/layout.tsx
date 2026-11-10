import { AreaGestor } from "@/features/gestor/AreaGestor";

export default function LayoutGestor({ children }: { children: React.ReactNode }) {
  return <AreaGestor>{children}</AreaGestor>;
}
