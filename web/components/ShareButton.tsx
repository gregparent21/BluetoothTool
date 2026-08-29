"use client";

import { useState } from "react";
import { inviteURL } from "@/lib/supabase";

/// Hands the invite link to a friend. Prefers the OS share sheet, which on a
/// phone is one tap into Messages; falls back to the clipboard everywhere else.
export function ShareButton({ code, houseName }: { code: string; houseName: string }) {
  const [copied, setCopied] = useState(false);

  async function share() {
    const url = inviteURL(code);
    const text = `Control the speakers at ${houseName}`;
    if (navigator.share) {
      try {
        await navigator.share({ title: "Multi-Speaker", text, url });
        return;
      } catch {
        // The user dismissed the sheet, or the browser refused it. Either way
        // copying is a reasonable second answer.
      }
    }
    try {
      await navigator.clipboard.writeText(url);
      setCopied(true);
      setTimeout(() => setCopied(false), 1800);
    } catch {
      window.prompt("Copy this link", url);
    }
  }

  return (
    <button className="share" onClick={share}>
      {copied ? "Copied" : "Invite"}
    </button>
  );
}
