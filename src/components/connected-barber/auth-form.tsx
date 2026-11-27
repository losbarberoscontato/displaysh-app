"use client";

import { useState, type FormEvent } from "react";
import Image from "next/image";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ArrowRight, Building2, Eye, EyeOff, LockKeyhole, Mail, ShieldCheck } from "lucide-react";
import { barberAuthDestination } from "@/lib/barber-auth";
import type { BarberLoginOrganization } from "@/components/connected-barber/types";
import { getSupabaseBrowserClient } from "@/lib/supabase/browser";
import { GoogleMark } from "@/components/google-mark";
import type { ProductKey } from "@/lib/product-context";
import type { ProductIdentityConfig } from "@/lib/product-identity";

type BarberAuthMode = "signin" | "signup";

function barberAuthModeHref(mode: BarberAuthMode, destination: string): string {
  const target = new URL(destination, "https://barbeiro.local");
  const params = new URLSearchParams({
    modo: mode === "signup" ? "cadastro" : "login",
    next: target.pathname,
  });
  const slug = target.searchParams.get("barbearia");
  if (slug) params.set("barbearia", slug);
  return `/profissional/entrar?${params.toString()}`;
}

export function BarberAuthForm({ next, slug, error, mode = "signin", productKey = "los-barberos", identity, organization }: { next?: string | null; slug?: string | null; error?: string | null; mode?: BarberAuthMode; productKey?: ProductKey; identity?: ProductIdentityConfig | null; organization?: BarberLoginOrganization | null }) {
  const router = useRouter();
  const [message, setMessage] = useState(error ? "Não foi possível concluir o acesso. Faça login novamente." : "");
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [oauthLoading, setOauthLoading] = useState(false);
  const destination = barberAuthDestination({ next, slug });
  const appName = identity?.vocabulary.teamApp ?? "App do Barbeiro";
  const loginHeading = "Entre para a equipe";
  const isSignup = mode === "signup";
  const modeSwitchHref = barberAuthModeHref(isSignup ? "signin" : "signup", destination);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const supabase = getSupabaseBrowserClient();
    setLoading(true);
    if (!supabase) { setLoading(false); setMessage("Sistema indisponível: configuração do Supabase ausente."); return; }
    const data = new FormData(event.currentTarget);
    const email = String(data.get("email") ?? "").trim();
    const password = String(data.get("password") ?? "");

    if (isSignup) {
      const callback = new URL("/auth/callback", window.location.origin);
      const destinationUrl = new URL(destination, window.location.origin);
      callback.searchParams.set("next", destinationUrl.pathname);
      callback.searchParams.set("produto", productKey);
      const organizationSlug = destinationUrl.searchParams.get("barbearia");
      if (organizationSlug) callback.searchParams.set("barbearia", organizationSlug);
      const { data: signupData, error: signupError } = await supabase.auth.signUp({
        email,
        password,
        options: { emailRedirectTo: callback.toString() },
      });
      setLoading(false);
      if (signupError) {
        setMessage("Não foi possível criar a conta. Confira o e-mail e a senha e tente novamente.");
        return;
      }
      if (signupData.session) {
        router.replace(destination);
        router.refresh();
        return;
      }
      setMessage("Confira seu e-mail para confirmar o cadastro. O acesso ao app depende da liberação da equipe.");
      return;
    }

    const { error: authError } = await supabase.auth.signInWithPassword({
      email,
      password,
    });
    if (authError) { setLoading(false); setMessage("E-mail ou senha inválidos. Confirme o e-mail da conta e tente novamente."); return; }
    router.replace(destination);
    router.refresh();
  }

  async function signInWithGoogle() {
    const supabase = getSupabaseBrowserClient();
    if (!supabase) { setMessage("Sistema indisponível: configuração do Supabase ausente."); return; }
    setOauthLoading(true);
    const callback = new URL("/auth/callback", window.location.origin);
    callback.searchParams.set("next", new URL(destination, window.location.origin).pathname);
    callback.searchParams.set("provider", "google");
    callback.searchParams.set("produto", productKey);
    const slugValue = new URL(destination, window.location.origin).searchParams.get("barbearia");
    if (slugValue) callback.searchParams.set("barbearia", slugValue);
    const { error: authError } = await supabase.auth.signInWithOAuth({ provider: "google", options: { redirectTo: callback.toString() } });
    if (authError) { setOauthLoading(false); setMessage("Não foi possível iniciar o Google. Tente novamente."); }
  }

  return (
    <div className="login-card">
      <div className="login-card__heading">
        <h1>{loginHeading}</h1>
        {organization && <div className="login-organization">
          <span className="login-organization__logo">
            {organization.logoUrl
              ? <Image src={organization.logoUrl} alt="" width={48} height={48} sizes="48px" unoptimized />
              : <Building2 size={22} aria-hidden="true" />}
          </span>
          <strong>{organization.name}</strong>
        </div>}
      </div>

      <button className="google-button" type="button" onClick={() => void signInWithGoogle()} disabled={oauthLoading}>
        <GoogleMark />
        {oauthLoading ? "Abrindo Google..." : "Continuar com Google"}
      </button>

      {message && <p className="login-notice" role="status">{message}</p>}

      <form onSubmit={submit} aria-label={isSignup ? `Criar conta no ${appName}` : `Entrar no ${appName}`}>
        <label htmlFor="barber-auth-email">
          E-mail
          <span className="input-shell">
            <Mail size={19} />
            <input id="barber-auth-email" name="email" type="email" autoComplete="email" required />
          </span>
        </label>
        <label htmlFor="barber-auth-password">
          Senha
          <span className="input-shell">
            <LockKeyhole size={19} />
            <input id="barber-auth-password" name="password" type={showPassword ? "text" : "password"} autoComplete={isSignup ? "new-password" : "current-password"} required minLength={isSignup ? 8 : 4} />
            <button type="button" onClick={() => setShowPassword((current) => !current)} aria-label={showPassword ? "Ocultar senha" : "Mostrar senha"}>
              {showPassword ? <EyeOff size={19} /> : <Eye size={19} />}
            </button>
          </span>
        </label>
        <button className="button button--dark button--block login-submit" type="submit" disabled={loading}>
          {loading ? isSignup ? "Criando conta..." : "Aguarde..." : isSignup ? "Criar conta" : "Entrar"}
          <ArrowRight size={18} />
        </button>
      </form>

      <Link className="login-mode-switch" href={modeSwitchHref}>
        {isSignup ? "Já tenho conta. Entrar" : "Ainda não tenho conta. Criar conta"}
      </Link>

      <p className="login-security">
        <ShieldCheck size={16} /> Seus dados protegidos e separados por estabelecimento.
      </p>
    </div>
  );
}
