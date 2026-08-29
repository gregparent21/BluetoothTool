"use client";

import { signInWithGoogle } from "@/lib/useSession";

/// The Google mark, inline. An <img> from Google's CDN would be one more thing
/// that can fail to load on a phone with bad party wifi.
function GoogleMark() {
  return (
    <svg width="17" height="17" viewBox="0 0 48 48" aria-hidden="true">
      <path fill="#4285F4" d="M45.1 24.5c0-1.6-.1-3.2-.4-4.7H24v8.9h11.8a10 10 0 0 1-4.4 6.6v5.5h7.1c4.2-3.8 6.6-9.5 6.6-16.3z" />
      <path fill="#34A853" d="M24 46c6 0 11-2 14.5-5.2l-7.1-5.5a13 13 0 0 1-19.4-6.8H4.7v5.7A22 22 0 0 0 24 46z" />
      <path fill="#FBBC05" d="M12 28.5a13 13 0 0 1 0-8.4v-5.7H4.7a22 22 0 0 0 0 19.8l7.3-5.7z" />
      <path fill="#EA4335" d="M24 10.7c3.3 0 6.2 1.1 8.5 3.3l6.3-6.3A22 22 0 0 0 4.7 14.4l7.3 5.7A13 13 0 0 1 24 10.7z" />
    </svg>
  );
}

export function GoogleButton({ next, label = "Continue with Google" }: { next?: string; label?: string }) {
  return (
    <button className="google" onClick={() => signInWithGoogle(next)}>
      <GoogleMark />
      {label}
    </button>
  );
}

/// The signed-out landing. Doubles as the explainer, because the one thing a
/// newcomer has to understand before signing up is that this needs a computer
/// sitting in the house with the speakers paired to it.
export function SignInPanel({ next, heading, blurb }: { next?: string; heading?: string; blurb?: string }) {
  return (
    <main>
      <div className="hero">
        <div className="hero-glyph">🔊</div>
        <h1>Multi-Speaker</h1>
        <p className="sub">
          {blurb ??
            "One song, every Bluetooth speaker in the house — and a link your friends can open to change it."}
        </p>
        <GoogleButton next={next} label={heading ?? "Continue with Google"} />
      </div>

      <div className="how">
        <h2>How it works</h2>
        <ol className="steps">
          <li>
            <b>One computer runs the house.</b> Pick a Mac that lives where the
            speakers are and stays plugged in. Every speaker pairs to that one
            machine — it is the thing actually playing the music.
          </li>
          <li>
            <b>Install the app on it.</b> It builds a single audio output that
            fans out to all your speakers at once, with a volume slider for each.
          </li>
          <li>
            <b>Share your house link.</b> Anyone you send it to can sign in and
            control the speakers from their phone, from anywhere in the house.
          </li>
        </ol>
        <p className="fine">
          Your phone never streams the audio. It sends instructions to the
          computer, which has to be awake with the app running.
        </p>
      </div>
    </main>
  );
}
