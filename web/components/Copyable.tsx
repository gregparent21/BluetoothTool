"use client";

import { useState } from "react";

/// A block of text with a copy button. The setup code is far too long to retype
/// and gets pasted into a native app, so copying has to work even where the
/// async clipboard API is unavailable (http origins, older iOS).
export function Copyable({
  label,
  value,
  big = false,
}: {
  label: string;
  value: string;
  big?: boolean;
}) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      setTimeout(() => setCopied(false), 1800);
    } catch {
      window.prompt(label, value);
    }
  }

  return (
    <div className="copyable">
      <div className="copyable-head">
        <span>{label}</span>
        <button className="link-btn" onClick={copy}>
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
      <pre className={big ? "big" : undefined}>{value}</pre>
    </div>
  );
}
