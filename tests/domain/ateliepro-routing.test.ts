import { describe, expect, it } from "vitest";
import { ATELIE_PRO_IDENTITY_FALLBACK } from "@/lib/product-identity";
import { parseProductKey } from "@/lib/product-context";
import { productBillingPath, productLoginPath } from "@/lib/product-routes";
import { getProductVocabulary } from "@/lib/product-vocabulary";
import { resolveSystemAuthDestination, systemLoginHref } from "@/lib/system-auth";

describe("AteliePro product integration", () => {
  it("keeps product, login, signup, and billing routes scoped", () => {
    expect(parseProductKey("ateliepro")).toBe("ateliepro");
    expect(parseProductKey("atelie-pro")).toBeNull();
    expect(productLoginPath("ateliepro")).toBe("/ateliepro/entrar");
    expect(productBillingPath("ateliepro")).toBe("/ateliepro/regularizacao");
    expect(systemLoginHref("signup", "/onboarding", "ateliepro")).toBe(
      "/ateliepro/entrar?modo=cadastro&next=%2Fonboarding",
    );
    expect(resolveSystemAuthDestination("/ateliepro/regularizacao")).toBe(
      "/ateliepro/regularizacao",
    );
  });

  it("uses sewing atelier terms and the supplied brand palette", () => {
    const vocabulary = getProductVocabulary("ateliepro", ATELIE_PRO_IDENTITY_FALLBACK.vocabulary);

    expect(vocabulary.organization).toBe("ateliê");
    expect(vocabulary.professional).toBe("costureira");
    expect(vocabulary.teamApp).toBe("App da Costureira");
    expect(vocabulary.services).toBe("serviços de costura");
    expect(ATELIE_PRO_IDENTITY_FALLBACK.colors.primary).toBe("#4A3024");
  });
});
