// Task attachments: the rules POST /v1/tasks/:id/attachments applies, and their Arabic text
// (api/DEVELOPMENT.md, «المرفقات»). Pure functions, tested in test/attachments.test.mjs.
import { formatSize } from "./imports.js";
import { arabicNumber } from "./numbers.js";

export const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024;

/** The extensions the server accepts (ATTACHMENT_TYPES in api/src/attachments.ts). */
export const ATTACHMENT_EXTENSIONS = [
  ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif",
  ".pdf",
  ".txt", ".md", ".csv", ".rtf",
  ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
];

/** For `<input type="file" accept>`. */
export const acceptAttribute = () => ATTACHMENT_EXTENSIONS.join(",");

const extensionOf = (name) => /\.[^.\s/\\]{1,10}$/.exec(name ?? "")?.[0].toLowerCase() ?? "";

/** Checks a chosen file before uploading it, the way the server would. Null when it is fine. */
export function checkAttachment(file, maxBytes = MAX_ATTACHMENT_BYTES) {
  if (!file) return { code: "no_file", message: "اختر ملفاً أولاً." };
  const ext = extensionOf(file.name);
  if (ext && !ATTACHMENT_EXTENSIONS.includes(ext)) return { code: "invalid_file_type", message: MESSAGES.invalid_file_type() };
  if (file.size === 0) return { code: "empty_file", message: MESSAGES.empty_file() };
  if (file.size > maxBytes) return { code: "file_too_large", message: MESSAGES.file_too_large({ maxBytes }) };
  return null;
}

/** What kind of file, in a word, from its stored type (or its name). */
export function kindOf(contentType = "", fileName = "") {
  const type = contentType.split(";")[0].trim().toLowerCase();
  const ext = extensionOf(fileName);
  if (type.startsWith("image/")) return "صورة";
  if (type === "application/pdf" || ext === ".pdf") return "PDF";
  if ([".xls", ".xlsx", ".csv"].includes(ext) || type.includes("spreadsheet") || type === "application/vnd.ms-excel") return "جدول";
  if ([".ppt", ".pptx"].includes(ext) || type.includes("presentation") || type === "application/vnd.ms-powerpoint") return "عرض تقديمي";
  if ([".doc", ".docx", ".rtf"].includes(ext) || type.includes("word")) return "مستند";
  if (type.startsWith("text/")) return "نص";
  return "ملف";
}

/** «PDF، ١٫٢ ميغابايت». */
export function attachmentMeta(attachment) {
  return `${kindOf(attachment.contentType, attachment.fileName)}، ${formatSize(attachment.size)}`;
}

/** «مرفق واحد»، «مرفقان»، «٣ مرفقات»، «١١ مرفقاً»، «١٠٠ مرفق» (a task holds up to 100). */
export function attachmentCount(n) {
  if (n === 0) return "لا مرفقات";
  if (n === 1) return "مرفق واحد";
  if (n === 2) return "مرفقان";
  const rest = n % 100;
  if (rest >= 3 && rest <= 10) return `${arabicNumber(n)} مرفقات`;
  if (rest >= 11) return `${arabicNumber(n)} مرفقاً`;
  return `${arabicNumber(n)} مرفق`;
}

const MESSAGES = {
  invalid_file_type: () => "هذا النوع غير مدعوم. أرفق صورة أو PDF أو نصاً أو مستند Office.",
  empty_file: () => "الملف فارغ.",
  file_too_large: ({ maxBytes = MAX_ATTACHMENT_BYTES } = {}) => `الملف أكبر من الحد المسموح (${formatSize(maxBytes)}).`,
  storage_quota_exceeded: () => "امتلأت مساحة مرفقاتك. احذف مرفقات لا تحتاجها ثم حاول مرة أخرى.",
  too_many_attachments: () => "بلغت المهمة الحد الأعلى من المرفقات.",
  forbidden: () => "لا تملك صلاحية هذا الإجراء على مرفقات المهمة.",
  not_found: () => "لم نجد المرفق، وربما حُذف.",
  network: () => "تعذّر الاتصال بالخادم. تحقق من اتصالك ثم حاول مرة أخرى.",
};

/** Arabic text for an error from the attachment routes. */
export function attachmentErrorText(error, { maxBytes } = {}) {
  const message = MESSAGES[error?.code];
  return message ? message({ maxBytes }) : "تعذّر إكمال الطلب. حاول بعد قليل.";
}
