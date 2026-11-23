import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

/** Writes sw.js at build time with the exact list of built files, so the installed app works offline. */
function serviceWorker(): Plugin {
  return {
    name: "plainly-sw",
    apply: "build",
    generateBundle(_, bundle) {
      const walk = (dir: string, base = ""): string[] => readdirSync(dir).flatMap((f) => {
        const p = join(dir, f);
        return statSync(p).isDirectory() ? walk(p, `${base}/${f}`) : [`${base}/${f}`];
      });
      const files = ["/", ...Object.keys(bundle).map((f) => `/${f}`).filter((f) => !f.endsWith(".map")), ...walk("public")];
      const version = Date.now().toString(36);
      const src = readFileSync("src/sw-template.js", "utf8").replace("__VERSION__", version).replace("__FILES__", JSON.stringify(files));
      this.emitFile({ type: "asset", fileName: "sw.js", source: src });
    },
  };
}

// All Firebase entry points are pre-bundled together. If Vite discovers one later (a new import), it re-bundles
// mid-session and the page ends up with two copies of @firebase/app, so services silently never attach.
export default defineConfig({
  plugins: [react(), serviceWorker()],
  optimizeDeps: {
    include: [
      "firebase/app",
      "firebase/app-check",
      "firebase/ai",
      "firebase/remote-config",
    ],
  },
});
