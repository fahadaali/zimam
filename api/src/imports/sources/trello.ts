import { zonedDateTime } from "../dates";
import { fitName, fitTask, type ImportBundle, ImportError, type ImportedProject, type ImportedSection, type ImportedTask, LIMITS, orderTasks, Warnings } from "../model";
import { nativeKey, type ParseContext, type TokenSource } from "../source";
import { instantOf, type Provider, providerGet } from "./provider-http";

export const TRELLO_API = "https://api.trello.com/1";

interface TrelloList {
  id: string;
  name?: string;
  pos?: number;
  closed?: boolean;
}

interface TrelloCard {
  id: string;
  name?: string;
  desc?: string;
  closed?: boolean;
  /** An instant, "2026-10-20T06:00:00.000Z". */
  due?: string | null;
  dueComplete?: boolean;
  start?: string | null;
  idList?: string;
  pos?: number;
  labels?: { name?: string; color?: string | null }[];
}

interface TrelloChecklist {
  id: string;
  idCard: string;
  name?: string;
  pos?: number;
  checkItems?: { id: string; name?: string; state?: string; pos?: number }[];
}

export interface TrelloBoard {
  id: string;
  name?: string;
  closed?: boolean;
  lists: TrelloList[];
  cards: TrelloCard[];
  checklists: TrelloChecklist[];
}

export interface TrelloData {
  boards: TrelloBoard[];
}

/**
 * What the OAuth callback puts in the queue message for Trello: Trello authorizes requests with
 * the app's API key and the user's token together, so both travel, as "<key>:<token>".
 */
export const trelloCredential = (apiKey: string, token: string) => `${apiKey}:${token}`;

export function parseTrelloCredential(value: string): { apiKey: string; token: string } | null {
  const at = value.indexOf(":");
  if (at <= 0 || at === value.length - 1) return null;
  return { apiKey: value.slice(0, at), token: value.slice(at + 1) };
}

const byPos = <T extends { pos?: number }>(a: T, b: T) => (a.pos ?? 0) - (b.pos ?? 0);

/**
 * Trello boards: each open board a kanban project, its open lists its sections (columns), its
 * open cards tasks. A card's due instant becomes the due day and time in the user's zone, its
 * start the start day; «complete» (dueComplete) marks it done; named labels become tags;
 * checklist items become subtasks, done when ticked. Archived boards, lists and cards are not
 * read; cards on an archived list are skipped.
 */
export function mapTrello(data: TrelloData, ctx: ParseContext): ImportBundle {
  const warnings = new Warnings();
  const projects: ImportedProject[] = [];
  const sections: ImportedSection[] = [];
  const tasks: ImportedTask[] = [];
  const zone = ctx.timeZone;

  data.boards.forEach((board, boardIndex) => {
    if (board.closed) {
      warnings.add("archivedSkipped");
      return;
    }
    const projectKey = nativeKey("board", board.id);
    projects.push({
      key: projectKey,
      name: fitName(board.name ?? "", LIMITS.projectName) || "Trello",
      kind: "project",
      parentKey: null,
      view: "kanban",
      sortOrder: boardIndex,
      archived: false,
    });
    const openLists = new Set<string>();
    [...board.lists].sort(byPos).forEach((list, index) => {
      if (list.closed) return;
      openLists.add(list.id);
      sections.push({ key: nativeKey("list", list.id), projectKey, name: fitName(list.name ?? "", LIMITS.sectionName) || "—", sortOrder: index });
    });
    const checklists = new Map<string, TrelloChecklist[]>();
    for (const c of [...board.checklists].sort(byPos)) checklists.set(c.idCard, [...(checklists.get(c.idCard) ?? []), c]);

    [...board.cards].sort(byPos).forEach((card, index) => {
      if (card.closed || !card.idList || !openLists.has(card.idList)) {
        warnings.add("archivedSkipped");
        return;
      }
      const title = card.name?.trim();
      if (!title) {
        warnings.add("untitledSkipped");
        return;
      }
      const key = nativeKey("card", card.id);
      const due = instantOf(card.due);
      const start = instantOf(card.start);
      const local = due === null ? null : zonedDateTime(due, zone);
      const done = card.dueComplete === true;
      tasks.push({
        key,
        projectKey,
        sectionKey: nativeKey("list", card.idList),
        parentKey: null,
        title,
        notes: card.desc?.trim() || null,
        priority: 0,
        tags: (card.labels ?? []).map((l) => l.name?.trim() ?? "").filter(Boolean),
        dueDate: local?.date ?? null,
        dueTime: local?.time ?? null,
        startDate: start === null ? null : zonedDateTime(start, zone).date,
        recurrence: null,
        done,
        completedAt: null,
        sortOrder: index,
        reminders: [],
      });
      let order = 0;
      for (const checklist of checklists.get(card.id) ?? []) {
        for (const item of [...(checklist.checkItems ?? [])].sort(byPos)) {
          const itemTitle = item.name?.trim();
          if (!itemTitle) continue;
          tasks.push({
            key: nativeKey("checkitem", item.id),
            projectKey,
            sectionKey: nativeKey("list", card.idList),
            parentKey: key,
            title: itemTitle,
            notes: null,
            priority: 0,
            tags: [],
            dueDate: null,
            dueTime: null,
            recurrence: null,
            done: item.state === "complete",
            completedAt: null,
            sortOrder: order++,
            reminders: [],
          });
        }
      }
    });
  });
  return { projects, sections, tasks: orderTasks(tasks).map(fitTask), warnings: warnings.list() };
}

const NOT_A_CREDENTIAL = new ImportError("token_rejected", "انتهى طلب الربط بـ Trello قبل أن يكتمل. ابدأ الاستيراد مرة أخرى.");

export const trello: TokenSource = {
  id: "trello",
  label: "Trello",
  refSource: "trello",
  input: "oauth",
  async load(credential, ctx) {
    const parsed = parseTrelloCredential(credential);
    if (!parsed) throw NOT_A_CREDENTIAL;
    // In a header rather than the query string, so the token is in no URL.
    const provider: Provider = {
      label: "Trello",
      fetch: ctx.fetch,
      headers: { Authorization: `OAuth oauth_consumer_key="${parsed.apiKey}", oauth_token="${parsed.token}"` },
    };
    const boards = await providerGet<{ id: string; name?: string; closed?: boolean }[]>(provider, `${TRELLO_API}/members/me/boards?filter=open&fields=id,name,closed`);
    const out: TrelloBoard[] = [];
    for (const b of boards ?? []) {
      const id = encodeURIComponent(b.id);
      const [lists, cards, checklists] = await Promise.all([
        providerGet<TrelloList[]>(provider, `${TRELLO_API}/boards/${id}/lists?filter=open&fields=id,name,pos,closed`),
        providerGet<TrelloCard[]>(provider, `${TRELLO_API}/boards/${id}/cards/open?fields=id,name,desc,closed,due,dueComplete,start,idList,pos,labels`),
        providerGet<TrelloChecklist[]>(provider, `${TRELLO_API}/boards/${id}/checklists?fields=id,idCard,name,pos&checkItems=all&checkItem_fields=name,state,pos`),
      ]);
      out.push({ id: b.id, name: b.name, closed: b.closed, lists: lists ?? [], cards: cards ?? [], checklists: checklists ?? [] });
    }
    return mapTrello({ boards: out }, ctx);
  },
};
