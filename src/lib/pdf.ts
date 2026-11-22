import * as pdfjs from "pdfjs-dist";
import workerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";

pdfjs.GlobalWorkerOptions.workerSrc = workerUrl;

/** The text of a PDF, one line per printed line (items grouped by their vertical position). Runs in the browser. */
export async function pdfLines(data: ArrayBuffer): Promise<string[]> {
  const doc = await pdfjs.getDocument({ data }).promise;
  const lines: string[] = [];
  for (let p = 1; p <= Math.min(doc.numPages, 8); p++) {
    const page = await doc.getPage(p);
    const content = await page.getTextContent();
    const rows = new Map<number, { x: number; s: string }[]>();
    for (const it of content.items as { str: string; transform: number[] }[]) {
      if (!it.str.trim()) continue;
      const y = Math.round(it.transform[5] / 2) * 2; // items on one printed line share (almost) the same y
      const row = rows.get(y) ?? [];
      row.push({ x: it.transform[4], s: it.str.trim() });
      rows.set(y, row);
    }
    [...rows.entries()]
      .sort((a, b) => b[0] - a[0])
      .forEach(([, row]) => lines.push(row.sort((a, b) => a.x - b.x).map((r) => r.s).join(" ")));
  }
  return lines;
}

/** First page of a PDF as a JPEG, for showing the report next to the results. */
export async function pdfPreview(data: ArrayBuffer, width = 900): Promise<string> {
  const doc = await pdfjs.getDocument({ data: data.slice(0) }).promise;
  const page = await doc.getPage(1);
  const vp = page.getViewport({ scale: 1 });
  const scale = width / vp.width;
  const v = page.getViewport({ scale });
  const c = document.createElement("canvas");
  c.width = Math.round(v.width);
  c.height = Math.round(v.height);
  await page.render({ canvas: c, canvasContext: c.getContext("2d")!, viewport: v }).promise;
  return c.toDataURL("image/jpeg", 0.8);
}
