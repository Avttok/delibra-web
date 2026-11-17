import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  // /gestor sozinho abre o início do painel
  async redirects() {
    return [
      { source: "/gestor", destination: "/gestor/inicio", permanent: false },
      // Delibra Dev: entrada própria
      { source: "/dev", destination: "/gestor/dev/comando", permanent: false },
      { source: "/gestor/dev", destination: "/gestor/dev/comando", permanent: false },
    ];
  },
};

export default nextConfig;
