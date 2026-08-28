/** @type {import('next').NextConfig} */
const nextConfig = {
  // Album art comes straight from Spotify's CDN.
  images: { remotePatterns: [{ protocol: "https", hostname: "i.scdn.co" }] },
};
export default nextConfig;
