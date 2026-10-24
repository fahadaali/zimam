// Numbers in the Arabic interface use Arabic-Indic digits (١٢٣).

const arabic = new Intl.NumberFormat("ar-SA-u-nu-arab", { useGrouping: false });

/** 12 → "١٢". */
export function arabicNumber(n) {
  return arabic.format(n);
}
