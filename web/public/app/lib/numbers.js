// Numbers in the Arabic interface use Arabic-Indic digits (١٢٣).

const arabic = new Intl.NumberFormat("ar-SA-u-nu-arab", { useGrouping: false });

/** 12 → "١٢". */
export function arabicNumber(n) {
  return arabic.format(n);
}

/** Reads digits typed in either Arabic-Indic (٠–٩), Persian (۰–۹) or Latin form. */
export function parseDigits(text) {
  const latin = String(text ?? "")
    .trim()
    .replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660))
    .replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x06f0));
  return /^\d+$/.test(latin) ? Number(latin) : NaN;
}
