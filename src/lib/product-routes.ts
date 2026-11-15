export type ProductKey = "los-barberos" | "le-gras" | "pro-stetic" | "music-pro" | "ateliepro";

export function parseProductKey(value: unknown): ProductKey | null {
  return value === "los-barberos" || value === "le-gras" || value === "pro-stetic" || value === "music-pro" || value === "ateliepro" ? value : null;
}

export function productBillingPath(productKey: ProductKey): string {
  if (productKey === "le-gras") return "/le-gras/regularizacao";
  if (productKey === "music-pro") return "/music-pro/regularizacao";
  if (productKey === "pro-stetic") return "/pro-stetic/regularizacao";
  if (productKey === "ateliepro") return "/ateliepro/regularizacao";
  return "/regularizacao";
}

export function productLoginPath(productKey: ProductKey): string {
  if (productKey === "le-gras") return "/le-gras/entrar";
  if (productKey === "music-pro") return "/music-pro/entrar";
  if (productKey === "pro-stetic") return "/pro-stetic/entrar";
  if (productKey === "ateliepro") return "/ateliepro/entrar";
  return "/los-barberos/entrar";
}
